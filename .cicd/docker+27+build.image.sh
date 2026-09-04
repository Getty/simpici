#!/bin/sh
set -eu
image="$(printf '%s' "$CICD_IMAGE_REPOSITORY" | tr '[:upper:]' '[:lower:]')"
test -n "$image"
if docker info 2>&1 | grep -qi podman; then
  DOCKER_BUILDKIT=0 docker build --file Containerfile --tag "$image:$CICD_COMMIT" .
else
  docker build --file Containerfile --tag "$image:$CICD_COMMIT" .
fi
