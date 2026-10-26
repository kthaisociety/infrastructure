#!/usr/bin/env bash
# deployments' tofu.yml, locally: its `check` job, then the apply main runs. Images come from the local
# release overlay, not the repo's release.yaml (lib.sh, use_local_releases).
#   deployments.sh apply | plan
#   deployments.sh apply-only    no checks: what deploy.yml applies with
source "$(dirname "$0")/lib.sh"

cmd=${1:-apply}

checkout deployments

if [ "$cmd" != apply-only ]; then
  run_job_steps deployments tofu.yml check
fi

use_local_releases
add_overrides deployments
deployments_env

cd "$WORK/deployments/terraform"
case $cmd in
  apply | apply-only)
    log "deployments · terraform · tofu apply"
    tofu_init
    tofu apply -auto-approve
    ;;
  plan)
    log "deployments · terraform · tofu plan"
    tofu_init
    tofu plan
    ;;
  *)
    echo "usage: deployments.sh apply | plan | apply-only" >&2
    exit 2
    ;;
esac
