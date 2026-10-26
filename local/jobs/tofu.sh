#!/usr/bin/env bash
# Any tofu command in one root, against the local server, with that root's local env: for looking around
# (state list, output, console) or fixing state by hand.
#   tofu.sh <infrastructure/dokploy | infrastructure/openbao | deployments> <tofu args...>
source "$(dirname "$0")/lib.sh"

[ $# -ge 2 ] || { echo "usage: tofu.sh <infrastructure/dokploy | infrastructure/openbao | deployments> <tofu args...>" >&2; exit 2; }
target=$1
shift

case $target in
  infrastructure/dokploy | infrastructure/openbao)
    checkout infrastructure
    add_overrides infrastructure
    infrastructure_env
    dir=$WORK/infrastructure/terraform/${target#infrastructure/}
    ;;
  deployments)
    checkout deployments
    use_local_releases
    add_overrides deployments
    deployments_env
    dir=$WORK/deployments/terraform
    ;;
  *)
    echo "unknown root '$target': infrastructure/dokploy, infrastructure/openbao or deployments" >&2
    exit 2
    ;;
esac

cd "$dir"
tofu_init
tofu "$@"
