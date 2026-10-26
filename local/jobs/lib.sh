# shellcheck shell=bash
# Shared by the local jobs. They run in the runner container on the server, on dokploy-network, as your
# user: the repos at /workspace/<repo> (read-only), local/ at /workspace/local.
set -euo pipefail

WS=/workspace
LOCAL=$WS/local
STATE=$LOCAL/.state
WORK=/tmp/work

export TF_IN_AUTOMATION=true TF_INPUT=false
export TF_PLUGIN_CACHE_DIR=$STATE/cache/tofu-plugins
export PIP_CACHE_DIR=$STATE/cache/pip PYTHONUSERBASE=$STATE/cache/python
export PATH=$PYTHONUSERBASE/bin:$PATH
mkdir -p "$TF_PLUGIN_CACHE_DIR" "$PIP_CACHE_DIR" "$WORK"

# What GitHub gives every step.
export GITHUB_OUTPUT=$WORK/github-output GITHUB_STEP_SUMMARY=$WORK/github-summary
: >"$GITHUB_OUTPUT"
: >"$GITHUB_STEP_SUMMARY"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# A fresh copy of a repo's working tree, like CI's checkout: uncommitted edits included, nothing written
# back to the repo. Without infrastructure's local/: this, and its .state.
checkout() {
  local dst=$WORK/$1 skip=()
  [ "$1" = infrastructure ] && skip=(--exclude=./local)
  rm -rf "$dst"
  mkdir -p "$dst"
  tar -C "$WS/$1" --exclude=.git --exclude=.terraform --exclude=.venv \
    --exclude='*.tfstate' --exclude='*.tfstate.*' "${skip[@]}" -cf - . | tar -C "$dst" -xf -
}

# local/overrides/<repo>/... into the copy: endpoints, backends and logins for the local server.
add_overrides() {
  cp -R "$LOCAL/overrides/$1/." "$WORK/$1/"
}

# A workflow job's `run` steps, in order, the way GitHub runs them (bash -eo pipefail, in the step's
# working-directory). The copy is the checkout and the runner has the tools, so `uses` steps are skipped;
# so are steps that only run on pull requests. One change for local: infrastructure's files are read from
# your checkout of it instead of from GitHub's main.
run_job_steps() {
  local repo=$1 workflow=$2 job=$3
  local file=$WORK/$repo/.github/workflows/$workflow
  local n i step name run cond wd default_wd
  export J=$job
  n=$(yq '.jobs[strenv(J)].steps | length' "$file")
  [ "$n" -gt 0 ] || { echo "::error::$workflow has no job $job" >&2; return 1; }
  default_wd=$(yq -r '.jobs[strenv(J)].defaults.run["working-directory"] // "."' "$file")
  for ((i = 0; i < n; i++)); do
    step=".jobs[strenv(J)].steps[$i]"
    run=$(yq -r "$step.run // \"\"" "$file")
    [ -n "$run" ] || continue
    name=$(yq -r "$step.name // \"\"" "$file")
    [ -n "$name" ] || name=$(head -1 <<<"$run")
    cond=$(yq -r "$step.if // \"\"" "$file")
    if [[ $cond == *pull_request* ]]; then
      echo "skipped (pull requests only): $name"
      continue
    fi
    if [[ $run == *'${{'* ]] || [ "$(yq "$step.env // {} | length" "$file")" != 0 ]; then
      echo "::error::$workflow $job: step '$name' needs GitHub's expressions or env; the local runner can't run it" >&2
      return 1
    fi
    run=${run//https:\/\/raw.githubusercontent.com\/kthaisociety\/infrastructure\/main\//file:\/\/$WS\/infrastructure\/}
    wd=$(yq -r "${step}[\"working-directory\"] // \"$default_wd\"" "$file")
    log "$repo · $workflow · $job · $name"
    (cd "$WORK/$repo/$wd" && bash --noprofile --norc -eo pipefail -c "$run")
  done
}

# `tofu init`, quiet unless it fails.
tofu_init() {
  local out
  out=$(tofu init -no-color "$@" 2>&1) || { echo "$out" >&2; return 1; }
}

# A token like the one GitHub Actions gives a job in <repo>'s production environment (the same `sub`),
# signed by the local signer that local OpenBao's jwt login trusts in GitHub's place.
mint_jwt() {
  local sub=$1 now header payload sig
  b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  now=$(date +%s)
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  payload=$(jq -cn --arg sub "$sub" --argjson now "$now" \
    '{iss: "https://ci.kthais.localhost", aud: "https://bao.kthais.com", sub: $sub,
      iat: $now, nbf: ($now - 5), exp: ($now + 3600)}' | b64url)
  sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$STATE/jwt/ci.key.pem" -binary | b64url)
  printf '%s.%s.%s' "$header" "$payload" "$sig"
}

# The subjects the CI roles bind, read from infrastructure's config, so the tokens match whatever it says.
infrastructure_ci_sub() {
  sed -nE 's/^ *bound_claims *= *\{ *sub *= *"([^"]+)".*/\1/p' "$WS/infrastructure/terraform/openbao/main.tf"
}
deployments_ci_sub() {
  grep -oE '"repo:[^"]*/deployments@[^"]*:environment:production"' \
    "$WS/infrastructure/terraform/openbao/deployments.tf" | tr -d '"'
}

# Locally, every project's release.yaml is the local overlay (.state/releases/<project>.yaml, written by
# `kthais-local deploy`), never the repo's: an environment the overlay doesn't name is null, not deployed.
use_local_releases() {
  local f p e v json o
  for f in "$WORK"/deployments/projects/*/project.yaml; do
    p=$(basename "$(dirname "$f")")
    o=$STATE/releases/$p.yaml
    json='{}'
    while IFS= read -r e; do
      v=""
      [ -f "$o" ] && v=$(E=$e yq -r '.[strenv(E)] // ""' "$o")
      json=$(jq -c --arg e "$e" --arg v "$v" '.[$e] = (if $v == "" then null else $v end)' <<<"$json")
    done < <(yq -r '.environments | keys | .[]' "$f")
    {
      echo "# Local overlay (kthais-local deploy), not the repo's release.yaml."
      yq -p json -o yaml -P '.' <<<"$json"
    } >"$(dirname "$f")/release.yaml"
  done
}

# Env for infrastructure's roots. Google sign-in gets a placeholder client: nobody signs in with it here.
infrastructure_env() {
  TF_VAR_state_passphrase=$(cat "$STATE/passphrase-infrastructure")
  DOKPLOY_API_KEY=$(cat "$STATE/dokploy-api-key")
  TF_VAR_openbao_jwt=$(mint_jwt "$(infrastructure_ci_sub)")
  export TF_VAR_state_passphrase DOKPLOY_API_KEY TF_VAR_openbao_jwt
  export TF_VAR_openbao_oidc_client_id=local-not-a-client TF_VAR_openbao_oidc_client_secret=local-not-a-secret
}

# Env for deployments' root: its own passphrase, as in production.
deployments_env() {
  TF_VAR_state_passphrase=$(cat "$STATE/passphrase-deployments")
  DOKPLOY_API_KEY=$(cat "$STATE/dokploy-api-key")
  TF_VAR_openbao_jwt=$(mint_jwt "$(deployments_ci_sub)")
  export TF_VAR_state_passphrase DOKPLOY_API_KEY TF_VAR_openbao_jwt
}
