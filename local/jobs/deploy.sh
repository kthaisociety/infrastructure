#!/usr/bin/env bash
# deployments' deploy.yml, locally: one run is one deploy.
#  1. Its "Validate the request" step, as is: project and environment exist, the tag's digest from GHCR,
#     and for production, the GitHub Release and the commit it was built from.
#  2. Instead of committing the line to main: the local release overlay.
#  3. Apply, and report.
#   deploy.sh <project> <environment> <tag>
source "$(dirname "$0")/lib.sh"

[ $# -eq 3 ] || { echo "usage: deploy.sh <project> <environment> <tag>" >&2; exit 2; }
export PROJECT=$1 ENVIRONMENT=$2 TAG=$3 REQUEST_ID=manual GH_TOKEN=unused

checkout deployments
use_local_releases

log "deployments · deploy.yml · Validate the request"
validate=$(yq -r '.jobs.deploy.steps[] | select(.name == "Validate the request") | .run' \
  "$WORK/deployments/.github/workflows/deploy.yml")
[ -n "$validate" ] || { echo "deploy.yml has no step 'Validate the request'" >&2; exit 1; }
(cd "$WORK/deployments" && bash --noprofile --norc -eo pipefail -c "$validate")

line=$(sed -n 's/^line=//p' "$GITHUB_OUTPUT")
unchanged=$(sed -n 's/^unchanged=//p' "$GITHUB_OUTPUT")

overlay=$STATE/releases/$PROJECT.yaml
if [ "$unchanged" = true ]; then
  echo "Already the local line: $PROJECT $ENVIRONMENT → $line"
else
  mkdir -p "$STATE/releases"
  [ -s "$overlay" ] || echo '{}' >"$overlay"
  E=$ENVIRONMENT L=$line yq -i -P '.[strenv(E)] = strenv(L)' "$overlay"
  echo "Local release overlay: $PROJECT $ENVIRONMENT → $line"
fi

"$(dirname "$0")/deployments.sh" apply-only

echo
echo "Deployed: $PROJECT $ENVIRONMENT runs $line"
