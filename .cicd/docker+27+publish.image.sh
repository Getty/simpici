#!/bin/sh
set -eu
test "${CICD_PUBLISH_IMAGE:-false}" = true || exit 78
if [ -z "${CICD_REGISTRY_USER:-}" ] || [ -z "${CICD_REGISTRY_PASSWORD:-}" ]; then
  echo "SimpiCI: no registry credentials; skipping publish" >&2
  exit 78
fi
image="$(printf '%s' "$CICD_IMAGE_REPOSITORY" | tr '[:upper:]' '[:lower:]')"
printf '%s' "$CICD_REGISTRY_PASSWORD" \
  | docker login "$CICD_REGISTRY" --username "$CICD_REGISTRY_USER" --password-stdin
docker push "$image:$CICD_COMMIT"
if [ "$CICD_REF" = refs/heads/main ]; then
  docker tag "$image:$CICD_COMMIT" "$image:latest"
  docker push "$image:latest"
fi
