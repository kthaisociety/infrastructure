#!/usr/bin/env bash
# infrastructure's tofu.yml, locally: its PR checks (fmt, openbao-validate), then the applies in the order
# main runs them, glesys → openbao → dokploy. glesys is the stand-in in mock/glesys; gcp has no local side.
#   infrastructure.sh apply | plan
#   infrastructure.sh apply-dokploy [tofu args]   only terraform/dokploy (OpenBao's first deploy)
source "$(dirname "$0")/lib.sh"

cmd=${1:-apply}
shift || true

checkout infrastructure
infrastructure_env

root() {
  local dir=$1
  shift
  log "infrastructure · terraform/$dir · tofu $*"
  (cd "$WORK/infrastructure/terraform/$dir" && tofu_init && tofu "$@")
}

glesys() {
  log "glesys (local stand-in) · tofu $*"
  rm -rf "$WORK/glesys"
  cp -R "$LOCAL/mock/glesys" "$WORK/glesys"
  (cd "$WORK/glesys" && tofu_init && tofu "$@")
}

case $cmd in
  apply | plan)
    run_job_steps infrastructure tofu.yml fmt
    run_job_steps infrastructure tofu.yml openbao-validate
    add_overrides infrastructure
    if [ "$cmd" = apply ]; then
      glesys apply -auto-approve
      root openbao apply -auto-approve
      root dokploy apply -auto-approve
    else
      glesys apply -auto-approve # the stand-in's outputs, which openbao's plan reads
      root openbao plan
      root dokploy plan
    fi
    ;;
  apply-dokploy)
    add_overrides infrastructure
    root dokploy apply -auto-approve "$@"
    ;;
  *)
    echo "usage: infrastructure.sh apply | plan | apply-dokploy [tofu args]" >&2
    exit 2
    ;;
esac
