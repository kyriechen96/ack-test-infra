#!/usr/bin/env bash

set -eo pipefail

USAGE="
Usage:
  $(basename "$0")

Publishes the controller image and helm chart for an ACK service controller as part of prowjob
when a service controller repository is tagged with a semver format '^v\d+\.\d+\.\d+$'
See: https://github.com/aws-controllers-k8s/test-infra/prow/jobs/jobs.yaml for prowjob configuration.

Environment variables:
  REPO_NAME:                Name of the service controller repository. Ex: apigatewayv2-controller
                            This variable is injected into the pod by Prow.
  PULL_BASE_REF:            The value of tag on service controller repository that triggered the
                            postsubmit prowjob. The value will either be in the format '^v\d+\.\d+\.\d+$'
                            or 'stable'.
                            This variable is injected into the pod by Prow.
  DOCKER_REPOSITORY:        Name for the Docker repository to push to
                            Default: $DEFAULT_DOCKER_REPOSITORY
  AWS_SERVICE_DOCKER_IMG:   Controller container image tag
                            Default: public.ecr.aws/aws-controllers-k8s/<AWS_SERVICE>-controller:<VERSION>
                            VERSION is calculated from $PULL_BASE_REF
  QUIET:                    Build controller container image quietly (<true|false>)
                            Default: false
  HELM_REGISTRY:            Name for the helm registry to push to
                            Default: public.ecr.aws/aws-controllers-k8s
"

# find out the service name and semver tag from the prow environment variables.
AWS_SERVICE=$(echo "$REPO_NAME" | rev | cut -d"-" -f2- | rev | tr '[:upper:]' '[:lower:]')
VERSION=$PULL_BASE_REF
GOARCH=${GOARCH:-"$(go env GOARCH)"}

# Important Directory references based on prowjob configuration.
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
SCRIPTS_DIR=$DIR
CD_DIR=$DIR/..
TEST_INFRA_DIR=$CD_DIR/..
WORKSPACE_DIR=$TEST_INFRA_DIR/..
SERVICE_CONTROLLER_DIR="$WORKSPACE_DIR/$AWS_SERVICE-controller"
CODE_GEN_DIR="$WORKSPACE_DIR/code-generator"

# Check all the dependencies are present in container.
source "$TEST_INFRA_DIR"/scripts/lib/common.sh
source "$TEST_INFRA_DIR"/scripts/lib/login.sh
source "$TEST_INFRA_DIR"/scripts/public-ecr.sh
check_is_installed git
check_is_installed jq
check_is_installed yq

if [[ $PULL_BASE_REF = stable ]]; then
  pushd "$WORKSPACE_DIR"/"$AWS_SERVICE"-controller 1>/dev/null
  echo "Triggering for the stable branch"
  _semver_tag=$(git describe --tags --abbrev=0 2>/dev/null)
  if [[ $? -ne 0 ]]; then
    echo "Unable to find semver tag on the 'stable' branch"
    exit 2
  fi
  echo "Semver tag on stable branch is $_semver_tag"

  if ! (echo "$_semver_tag" | grep -Eq "^v[0-9]+\.[0-9]+\.[0-9]+$"); then
    echo "semver tag on stable branch should have format ^v[0-9]+\.[0-9]+\.[0-9]+$"
    exit 2
  fi

  _major_version=$(echo "$_semver_tag" | cut -d"." -f1)
  if [[ -z "$_major_version" ]]; then
    echo "Unable to determine major version from latest semver tag on 'stable' branch"
    exit 2
  fi

  VERSION="$_major_version-stable"
  popd 1>/dev/null
else
  echo "release-controller.sh] Validating that controller image repository & tag in release artifacts is consistent with semver tag"
  pushd "$WORKSPACE_DIR"/"$AWS_SERVICE"-controller/helm 1>/dev/null
    # helm directory will be existing due to release-test presubmit job
    _repository=$(yq eval ".image.repository" values.yaml)
    _image_tag=$(yq eval ".image.tag" values.yaml)
    if [[ $_repository != public.ecr.aws/aws-controllers-k8s/$AWS_SERVICE-controller ]]; then
      echo "release-controller.sh] [ERROR] 'image.repository' value in release artifacts should be public.ecr.aws/aws-controllers-k8s/$AWS_SERVICE-controller. Current value: $_repository"
      exit 1
    fi
    if [[ $_image_tag != $VERSION ]]; then
      echo "release-controller.sh] [ERROR] 'image.tag' value in release artifacts should be $VERSION. Current value: $_image_tag"
      exit 1
    fi
    echo "release-controller.sh] Validation successful"
  popd 1>/dev/null
fi

echo "VERSION is $VERSION"

ASSUME_EXIT_VALUE=0
ECR_PUBLISH_ARN=$(aws ssm get-parameter --name /ack/prow/cd/public_ecr/publish_role --query Parameter.Value --output text 2>/dev/null) || ASSUME_EXIT_VALUE=$?
if [ "$ASSUME_EXIT_VALUE" -ne 0 ]; then
  echo "release-controller.sh] [SETUP] Could not find the iam role to publish images to public ecr repository"
  exit 1
fi
export ECR_PUBLISH_ARN
echo "release-controller.sh] [SETUP] exported ECR_PUBLISH_ARN"

ASSUME_COMMAND=$(aws sts assume-role --role-arn $ECR_PUBLISH_ARN --role-session-name 'publish-images' --duration-seconds 3600 | jq -r '.Credentials | "export AWS_ACCESS_KEY_ID=\(.AccessKeyId)\nexport AWS_SECRET_ACCESS_KEY=\(.SecretAccessKey)\nexport AWS_SESSION_TOKEN=\(.SessionToken)\n"')
eval $ASSUME_COMMAND
echo "release-controller.sh] [SETUP] Assumed ECR_PUBLISH_ARN"

# Setup the destination repository for buildah and helm
perform_buildah_and_helm_login

# Do not rebuild controller image for stable releases
if ! (echo "$VERSION" | grep -Eq "stable$"); then
  # Determine parameters for docker-build command
  pushd "$WORKSPACE_DIR"/"$AWS_SERVICE"-controller 1>/dev/null

  SERVICE_CONTROLLER_GIT_COMMIT=$(git rev-parse HEAD)
  QUIET=${QUIET:-"false"}
  BUILD_DATE=$(date +%Y-%m-%dT%H:%M)
  CONTROLLER_IMAGE_DOCKERFILE_PATH=$CODE_GEN_DIR/Dockerfile

  DEFAULT_DOCKER_REPOSITORY="public.ecr.aws/aws-controllers-k8s/$AWS_SERVICE-controller"
  DOCKER_REPOSITORY=${DOCKER_REPOSITORY:-"$DEFAULT_DOCKER_REPOSITORY"}

  ensure_repository "$AWS_SERVICE"

  AWS_SERVICE_DOCKER_IMG=${AWS_SERVICE_DOCKER_IMG:-"$DOCKER_REPOSITORY:$VERSION"}
  DOCKER_BUILD_CONTEXT="$WORKSPACE_DIR"

  popd 1>/dev/null

  cd "$WORKSPACE_DIR"

  if [[ $QUIET = "false" ]]; then
      echo "building '$AWS_SERVICE' controller docker image with tag: ${AWS_SERVICE_DOCKER_IMG}"
      echo " git commit: $SERVICE_CONTROLLER_GIT_COMMIT"
  fi

  pushd "$CODE_GEN_DIR" 1>/dev/null
    # Get the golang version from the code-generator
    GOLANG_VERSION=${GOLANG_VERSION:-"$(go list -f \{\{.GoVersion\}\} -m)"}
  popd 1>/dev/null

  # build controller image
  if ! buildah bud \
    --quiet="$QUIET" \
    -t "$AWS_SERVICE_DOCKER_IMG" \
    -f "$CONTROLLER_IMAGE_DOCKERFILE_PATH" \
    --build-arg service_alias="$AWS_SERVICE" \
    --build-arg service_controller_git_version="$VERSION" \
    --build-arg service_controller_git_commit="$SERVICE_CONTROLLER_GIT_COMMIT" \
    --build-arg build_date="$BUILD_DATE" \
    --build-arg golang_version="$GOLANG_VERSION" \
    --build-arg go_arch="$GOARCH" \
    "$DOCKER_BUILD_CONTEXT"; then
    exit 2
  fi

  echo "Pushing '$AWS_SERVICE' controller image with tag: ${AWS_SERVICE_DOCKER_IMG}"

  if ! buildah push "${AWS_SERVICE_DOCKER_IMG}"; then
    exit 2
  fi
fi

cd "$WORKSPACE_DIR"

DEFAULT_HELM_REGISTRY="public.ecr.aws/aws-controllers-k8s"
HELM_REPO="$AWS_SERVICE-chart"

HELM_REGISTRY=${HELM_REGISTRY:-$DEFAULT_HELM_REGISTRY}

export HELM_EXPERIMENTAL_OCI=1

if [[ -d "$SERVICE_CONTROLLER_DIR/helm" ]]; then
    echo -n "Generating Helm chart package for $AWS_SERVICE@$VERSION ... "
    helm package "$SERVICE_CONTROLLER_DIR"/helm/
    echo "ok."
    # Path to tarballed package (eg. `s3-chart-v0.0.1.tgz`)
    CHART_PACKAGE="$HELM_REPO-$VERSION.tgz"

    helm push "$CHART_PACKAGE" "oci://$HELM_REGISTRY"
else
    echo "Error building Helm packages:" 1>&2
    echo "$SERVICE_CONTROLLER_SOURCE_PATH/helm is not a directory." 1>&2
    echo "${USAGE}"
    exit 1
fi
