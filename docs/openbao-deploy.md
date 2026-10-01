# Deploying OpenBao

_Written 2026-09-30; Parts A–C done 2026-10-01. The exact steps for Phases 2–5 of [plan.md](plan.md): from no OpenBao to OpenBao
serving secrets to onboarding-service and landingpage-backend. The plan says why; this says how. Follow
it in order: each part assumes the previous one is done and checked._

| Part | What | Who / where | Plan phase |
|---|---|---|---|
| [A](#part-a-deploy-openbao-privately) | Deploy OpenBao with no public route | PRs here and in `dnscontrol`, SSH to the host | 2 |
| [B](#part-b-initialize-by-hand) | Initialize it, create CI's login and the first admins | SSH to the host, inside the container | 3 |
| [C](#part-c-make-it-public) | Turn on the public route and check its blocks | PR here, `curl` from a laptop | 2 |
| [D](#part-d-configure-openbao-as-code) | `terraform/openbao` in CI, Google sign-in, the UI | PR here | 4 |
| [E](#part-e-connect-dokploy-snapshots-and-the-first-two-apps) | Vault providers, snapshots, the first two apps | PRs here, SSH, Dokploy UI | 5 |

**Why it's deployed privately first:** a fresh OpenBao isn't initialized, and whoever calls
`sys/init` first owns it. The public route blocks `/v1/sys/init`, but we only trust that block once we've
tested it (Part C). So OpenBao starts with no route at all, we initialize it from inside the container,
and only then make it public. After init, `sys/init` does nothing.

## Values used throughout

| Name | Value |
|---|---|
| Host | the Synapse host, `176.126.70.246` (`HOST_SYNAPSE` in `dnscontrol/functions.js`) |
| Public API | `https://bao.kthais.com` |
| Internal address | `http://openbao:8200` on `dokploy-network` |
| Image | `openbao/openbao:2.7.0` (the version the prototype verified; bump deliberately) |
| Unseal key on the host | `/etc/openbao/unseal.key`, mounted at `/openbao/unseal.key` |
| Seal key id | `kthais-1` (stays paired with the key for the life of the data) |
| CI's login | JWT auth at `auth/jwt`, role `infrastructure-ci`, audience `https://bao.kthais.com` |
| People's login | OIDC auth at `auth/oidc` (Google), role `infra-admin`, from Part D |
| Break-glass login | `userpass`, inside the container only |
| CI's policy | `terraform` |
| Admin policy | `infra-admin` |
| Dokploy panel | `https://synapse.aisociety.se` (same host) |

**Opening a shell inside the container**, used in Parts B, D and E. Run it on the host after
`ssh <you>@176.126.70.246`:

```sh
BAO=$(sudo docker ps -q --filter label=com.docker.compose.service=openbao)
echo "$BAO"        # exactly one container id; stop if it's empty or more than one
sudo docker exec -it -e BAO_ADDR=http://127.0.0.1:8200 "$BAO" sh
```

Docker on the host needs `sudo`. Dokploy's own terminal also works, but it opens `bash` by default and
the image only has `sh`: pick `sh`.

Commands marked _(in the container)_ run in that shell. `ash` there keeps no history file, so values
typed or pasted don't persist.

---

## Part A: Deploy OpenBao privately

### A1. Check Dokploy's version
In `https://synapse.aisociety.se`, the version is in the sidebar's footer. It must be **v0.30.8 or
later** (the provider's target). We run v0.30.8.

### A2. Dokploy API key for OpenTofu
1. In Dokploy, invite a user for OpenTofu (Settings → Users), role **admin** (not owner: `ops@` stays
   the owner and break-glass account), email `ops+dokploy-terraform@kthais.com`, name `Terraform CI`.
   Open the invitation link in a private window and set a password; it goes to 1Password.
2. Sign in as that user, Settings → Profile → API keys → Generate, named
   `github-actions-infrastructure-<yyyy-mm>`. **Turn rate limiting off** (a rate-limited key answers
   `401` mid-apply). No expiry.
3. The key isn't kept anywhere but GitHub. To rotate it, generate a new one, set it, and delete the old
   one once CI passes. After a disaster Dokploy starts fresh, so an old key would be useless anyway.
4. GitHub, this repo → Settings → Secrets and variables → Actions:
   - Secret `DOKPLOY_API_KEY`: the key, in both the `plan` and `production` environments (never
     repo-level: any branch could read it). `gh secret set DOKPLOY_API_KEY --env <env>`.

### A3. DNS: `bao.kthais.com`
In the `dnscontrol` repo, `domains/kthais.com.js`, directly above `LE_CAA`:

```js
  // bao, OpenBao secrets manager (API, and the UI from Part D)
  // https://github.com/kthaisociety/infrastructure
  HOST_SYNAPSE("bao"),
```

`dnscontrol check`, open a PR, merge. Then `dig +short bao.kthais.com` answers `176.126.70.246`. The
zone's CAA allows Let's Encrypt, which is what Dokploy's Traefik uses.

### A4. The unseal key
Generated on the host, so it's only ever there and in 1Password.

```sh
ssh <you>@176.126.70.246
sudo install -d -m 0755 /etc/openbao
sudo sh -c 'umask 077; openssl rand -out /etc/openbao/unseal.key 32'
sudo docker run --rm --entrypoint id openbao/openbao:2.7.0 openbao   # uid=100 gid=1000 in 2.7.0
sudo chown 100:1000 /etc/openbao/unseal.key
sudo chmod 0400 /etc/openbao/unseal.key
sudo base64 /etc/openbao/unseal.key                              # copy into 1Password
```

1Password: item "OpenBao static unseal key", field `key_base64` and field `key_id` = `kthais-1`. To put
it back on a new host: `base64 -d > /etc/openbao/unseal.key`, then the same `chown`/`chmod`.

**Losing this key and the host together loses every secret.** Snapshots can't be restored without it.

### A5. The PR: `terraform/dokploy` with OpenBao
_Written 2026-10-01 (in the same PR as this runbook)._ New root module. Files and what's in them:

**`terraform/dokploy/versions.tf`**
- `required_version = ">= 1.11"`, provider `vanillauys/dokploy` `~> 1.8.0` (targets Dokploy v0.30.8).
- The `s3` backend and `encryption` block copied from `terraform/glesys/versions.tf`, with
  `key = "dokploy/terraform.tfstate"`.
- `provider "dokploy"` with `endpoint = "https://synapse.aisociety.se"` (not secret). The key comes
  from the `DOKPLOY_API_KEY` environment variable, like GleSYS's.

**`terraform/dokploy/variables.tf`**: `state_passphrase`, `openbao_initialized` and `openbao_public`
(bools, default `false`; flipped by changing the defaults, since `*.tfvars` is gitignored).

**`terraform/dokploy/outputs.tf`**: the infrastructure project's and production environment's IDs, for
`terraform/openbao`.

**`terraform/dokploy/openbao.tf`**
- `dokploy_project.infrastructure`.
- `dokploy_compose.openbao`: `compose_type = "docker-compose"`, in the infrastructure project's
  production environment, `raw.compose_file = yamlencode(...)` with one service:
  - `image: openbao/openbao:2.7.0`, `command: server`, `restart: unless-stopped`.
  - `environment.BAO_LOCAL_CONFIG = jsonencode(local.openbao_config)`.
  - `volumes`: `openbao-data:/openbao/file`, and `/etc/openbao/unseal.key` bind-mounted read-only at
    `/openbao/unseal.key` with `create_host_path: false`, so a missing key fails the deploy.
  - `networks`: until `var.openbao_initialized`, only the compose's own `default` network, so no other
    container can reach the uninitialized OpenBao and call `sys/init`. After, `dokploy-network`
    (external) with alias `openbao`, for Traefik and Dokploy's server.
  - **No `ports`.** Nothing is published on the host.
  - `labels`: `local.openbao_labels` when `var.openbao_public`, else `["traefik.enable=false"]`. A
    precondition refuses `openbao_public` without `openbao_initialized`.
- `local.openbao_config`:

  ```hcl
  {
    ui            = false
    disable_mlock = true
    api_addr      = "https://bao.kthais.com"
    cluster_addr  = "http://127.0.0.1:8201"
    storage  = { raft = { path = "/openbao/file", node_id = "openbao-1" } }
    listener = { tcp = { address = "0.0.0.0:8200", tls_disable = true } }
    seal = {
      static = {
        current_key_id = "kthais-1"
        current_key    = "file:///openbao/unseal.key"
      }
    }
  }
  ```

- `local.openbao_labels` (used from Part C on). Four routers on `Host(\`bao.kthais.com\`)`:
  - `bao-web`: entrypoint `web`, middleware `redirect-to-https@file`.
  - `bao`: entrypoint `websecure`, `tls.certresolver=letsencrypt`, middleware `bao-ratelimit`
    (`ratelimit.average=20`, `ratelimit.burst=40`), service port `8200`.
  - `bao-blocked`: entrypoint `websecure`, TLS as above, higher `priority`, rule
    `Host(...) && (PathPrefix(\`/v1/auth/userpass\`) || PathPrefix(\`/v1/sys/generate-root\`) ||
    PathPrefix(\`/v1/sys/rekey\`) || PathPrefix(\`/v1/sys/rotate/recovery\`) || PathPrefix(\`/v1/sys/init\`))`,
    middleware `bao-deny` (`ipallowlist.sourcerange=127.0.0.1/32`, so every caller gets 403).
  - `traefik.enable=true`, `traefik.docker.network=dokploy-network`.
  - In `yamlencode` input, a literal `$` is `$$`; none of these labels need one.

**`.github/workflows/tofu.yml`**: `dokploy-plan` (PRs, `plan` environment) and `dokploy-apply` (main, `production`
environment, `needs: glesys-apply`), shaped like the `glesys` jobs, with `DOKPLOY_API_KEY` from the
secret. On `main`, runs only after `glesys-apply`.

### A6. Merge and check
Merge. CI applies and Dokploy deploys the compose. Then on the host:

```sh
BAO=$(sudo docker ps -q --filter label=com.docker.compose.service=openbao)
echo "$BAO"                                                          # exactly one container id
sudo docker logs "$BAO" 2>&1 | tail -20                         # no errors about the seal or storage
sudo docker exec "$BAO" env BAO_ADDR=http://127.0.0.1:8200 bao status
sudo docker inspect "$BAO" --format '{{range $n, $_ := .NetworkSettings.Networks}}{{println $n}}{{end}}'
```

Expect `Seal Type static`, `Initialized false`, and one network, `openbao-…_default`: **not**
`dokploy-network`. If it's on `dokploy-network`, stop: any app could initialize it. And from a laptop, `curl -sI https://bao.kthais.com`
must **not** reach OpenBao (connection error, or Traefik's 404): there's no route yet.

---

## Part B: Initialize by hand

Do this right after A6, in one sitting, with the recovery key holders reachable.

### B1. Init
_(in the container)_

```sh
bao operator init -recovery-shares=3 -recovery-threshold=2
```

_Done 2026-10-01._ It prints 3 recovery keys and a root token. Each recovery key goes to 1Password as its
own item, shared with only its holder:

| Item | Holder |
|---|---|
| "OpenBao recovery key 1/3" | Sam (`sammosios`) |
| "OpenBao recovery key 2/3" | Vilhelm (`vilhelmprytz`) |
| "OpenBao recovery key 3/3" | the org-owned break-glass vault |

- Any two can generate a new root token in an emergency. OpenBao refuses a threshold of 1 with more than
  one share, so "either holder alone" isn't possible; the org vault's key keeps recovery possible when one
  person is gone, without either holder being able to do it alone.
- To change holders later, from inside the container: `bao operator rekey -target=recovery -init
  -key-shares=<n> -key-threshold=<t>`, then `bao operator rekey -target=recovery` with two current keys,
  and hand out the new keys.
- The root token stays in this shell only. Never store it: it's revoked in B5.

```sh
bao status        # Initialized true, Sealed false
read -rs BAO_TOKEN && export BAO_TOKEN     # paste the root token
```

### B2. CI's login: GitHub Actions JWT
_(in the container)_

```sh
bao policy write terraform - <<'EOF'
path "*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"]
}
EOF

bao auth enable jwt
bao write auth/jwt/config \
  oidc_discovery_url=https://token.actions.githubusercontent.com \
  bound_issuer=https://token.actions.githubusercontent.com

bao write auth/jwt/role/infrastructure-ci - <<'EOF'
{
  "role_type": "jwt",
  "user_claim": "sub",
  "bound_audiences": ["https://bao.kthais.com"],
  "bound_claims": { "sub": "repo:kthaisociety/infrastructure:environment:production" },
  "token_policies": ["terraform"],
  "token_ttl": "30m",
  "token_max_ttl": "1h"
}
EOF
```

Only a job in this repo's `production` environment gets a token GitHub signs with that `sub`, and
`production` is limited to `main`.

### B3. The first infra admins
_(in the container)_, once per admin. Today: `sam` and `vilhelm`.

```sh
bao auth enable userpass      # first time only
PW=$(head -c 24 /dev/urandom | base64)
bao write auth/userpass/users/<name> \
  password="$PW" \
  token_policies=infra-admin \
  token_bound_cidrs=127.0.0.1/32 \
  token_ttl=1h token_max_ttl=1h
echo "$PW"; unset PW          # hand it to <name>, who stores it in their own 1Password
```

The `infra-admin` policy doesn't exist yet; Part D creates it. Until then these logins work but can't do
anything.

### B4. Nothing else by hand
Mounts, the audit device, policies and tokens all come from `terraform/openbao`. Don't create them here.

### B5. Revoke the root token and check auto-unseal
_(in the container)_

```sh
bao token revoke -self
unset BAO_TOKEN
exit
```

On the host:

```sh
BAO=$(sudo docker ps -q --filter label=com.docker.compose.service=openbao)
sudo docker restart "$BAO"
sleep 5
sudo docker exec "$BAO" env BAO_ADDR=http://127.0.0.1:8200 bao status   # Sealed false
```

---

## Part C: Make it public

### C0. Traefik must read Docker labels
OpenBao's route is Traefik labels, so Traefik's Docker provider has to work. Traefik before 3.6.1 can't
talk to Docker Engine 29+, and fails quietly: file-based routes keep working, label-based ones get
Traefik's 404 on its default certificate. Check on the host:

```sh
sudo docker exec dokploy-traefik traefik version | head -1          # 3.6.1 or later
sudo docker exec dokploy-traefik wget -qO- http://localhost:8080/api/http/routers \
  | tr ',' '\n' | grep '"provider"' | sort | uniq -c                  # includes "docker" once OpenBao is labelled
```

_Done 2026-10-01:_ ours was 3.1.2 on Docker 29.8.1. Before upgrading, list what else has labels, because
it becomes routed the moment the provider works
(`sudo docker ps -a --filter label=traefik.enable=true`); we stopped an unused MinIO first
(`docker stop`, `docker update --restart=no`, and Stop in the Dokploy UI). Then recreate the container
with the same binds, ports and network, only the image changed:

```sh
sudo docker pull traefik:v3.7.13
sudo docker rename dokploy-traefik dokploy-traefik-old
sudo docker stop dokploy-traefik-old
sudo docker run -d --name dokploy-traefik --restart always --network dokploy-network \
  -v /etc/dokploy/traefik/traefik.yml:/etc/traefik/traefik.yml \
  -v /etc/dokploy/traefik/dynamic:/etc/dokploy/traefik/dynamic \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p 80:80/tcp -p 443:443/tcp -p 443:443/udp \
  traefik:v3.7.13
# check sites, then: sudo docker rm dokploy-traefik-old
# roll back: sudo docker rm -f dokploy-traefik && sudo docker rename dokploy-traefik-old dokploy-traefik && sudo docker start dokploy-traefik
```

Compare with `sudo docker inspect dokploy-traefik-old` first if Dokploy's setup may have changed. Don't
use Dokploy's "Reload Traefik" until we know it keeps the image.

### C1. The PR
In `terraform/dokploy/variables.tf`, set the defaults of `openbao_initialized` and `openbao_public` to
`true`. Merge; CI applies and Dokploy redeploys the compose on `dokploy-network` with the Traefik labels. The first request
may take a minute while Traefik gets the certificate.

**On a fresh host** (disaster recovery, or anything that starts with an empty data volume), the defaults
are now wrong: apply with `-var openbao_initialized=false -var openbao_public=false` first, and only drop
those once OpenBao is initialized or restored. See plan, "Disaster recovery".

### C2. Check the route and every block
From a laptop:

```sh
H=https://bao.kthais.com
curl -s $H/v1/sys/health | jq '{initialized, sealed}'   # {"initialized": true, "sealed": false}
curl -sI http://bao.kthais.com | head -1                  # a 30x redirect to https
for p in /v1/sys/init /v1/sys/generate-root/attempt /v1/sys/rekey/init \
         /v1/sys/rotate/recovery /v1/auth/userpass/login/x; do
  printf '%-32s %s\n' "$p" "$(curl -s -o /dev/null -w '%{http_code}' $H$p)"
done                                                      # every line 403
# Path tricks (verify item 9): each must be 403 or 404, never OpenBao's answer
for p in '/v1//sys/init' '/v1/sys//init' '/v1/sys/%69nit' '/v1/sys%2Finit' '/v1/./sys/init' \
         '/v1/auth//userpass/login/x' '/V1/sys/init'; do
  printf '%-32s %s\n' "$p" "$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "$H$p")"
done
```

_Done 2026-10-01 (PR #4)._ Certificate from Let's Encrypt, health `{"initialized":true,"sealed":false}`,
308 to HTTPS, every blocked path 403. Path tricks: all 403 except `%2F` (`/v1/sys%2Finit`: 405
`unsupported operation`) and uppercase (`/v1/SYS/init`: OpenBao's `permission denied`). Those pass
Traefik but match no real endpoint: `/v1/sys%2Fhealth` is a 405 too, so OpenBao doesn't decode `%2F`, and
its paths are case-sensitive. Recorded as verify item 9.

If any path trick returns what `curl -s $H/v1/sys/init` would return from inside the container
(`{"initialized":true}`) instead of 403/404, **turn the route off again** (`openbao_public = false`; `openbao_initialized` stays `true`, so
Dokploy can still reach it) and
change `bao-blocked` to an allowlist before retrying.

---

## Part D: Configure OpenBao as code

### D1. The first two project folders
Each project is a folder, `terraform/projects/<project>/project.yaml` (plan, "Projects are folders").
The first two are still managed in the Dokploy UI, so they're `managed: false` with their Dokploy IDs,
written here directly: the `dokploy_project` and `dokploy_environment` data sources would copy each
project's shared env vars into state.

```yaml
# terraform/projects/onboarding-service/project.yaml
name: onboarding-service
repo: kthaisociety/onboarding-service
managed: false
environments:
  production:
    dokploy_project_id: "<id>"
    dokploy_environment_id: "<id>"
    shared: [onboarding-service-secret]
```

`landingpage-backend` is the same shape. The IDs are in the Dokploy URL when a project or environment is
open. The `infrastructure` project isn't a folder: `terraform/dokploy` creates it, and its
`infrastructure/production` path is written by OpenTofu (snapshots, E2).

### D2. The PR: `terraform/openbao`
**`versions.tf`**
- Providers `hashicorp/vault` `~> 5.0` (it works against OpenBao).
- Backend `key = "openbao/terraform.tfstate"`, encryption as in `terraform/glesys`, plus a
  `remote_state_data_sources` entry so it can read `terraform/glesys`'s state.
- Provider:

  ```hcl
  provider "vault" {
    address          = "https://bao.kthais.com"
    skip_child_token = true
    auth_login_jwt {
      role = "infrastructure-ci"
      jwt  = var.openbao_jwt   # sensitive, ephemeral
    }
  }
  ```

**`main.tf`**
- `import` blocks for what Part B made: `vault_jwt_auth_backend` at `jwt`, `vault_jwt_auth_backend_role`
  `infrastructure-ci`, `vault_policy` `terraform`, `vault_auth_backend` `userpass`. Their config in code
  must match B2/B3 exactly, so the first plan shows no change to them.
- `vault_mount` `secret`, KV v2.
- `vault_audit` type `file`, `file_path = "stdout"`: audit lines go to the container's log, which
  Dokploy shows.
- `vault_token_auth_backend_role` `dokploy-provider`: `orphan = true`, `renewable = true`,
  `token_period = 768h`, `token_no_default_policy = true`, `allowed_policies_glob = ["dokploy-project-*"]`.
- `vault_policy` `infra-admin`:

  ```hcl
  path "secret/data/*"                    { capabilities = ["create", "read", "update", "patch", "delete", "list"] }
  path "secret/metadata/*"                { capabilities = ["read", "list", "delete"] }
  path "secret/data/infrastructure/*"     { capabilities = ["deny"] }
  path "secret/metadata/infrastructure/*" { capabilities = ["deny"] }
  path "auth/userpass/users/*" {
    capabilities        = ["create", "read", "update", "delete", "list"]
    required_parameters = ["token_bound_cidrs"]
    allowed_parameters = {
      "password"          = []
      "token_policies"    = ["infra-admin"]
      "token_bound_cidrs" = ["127.0.0.1/32"]
      "token_ttl"         = []
      "token_max_ttl"     = []
    }
  }
  path "auth/userpass/users/+/password" { capabilities = ["update"] }
  ```

- **`projects.tf`**: `module "app_secrets"` with `for_each` over
  `fileset(path.module, "../projects/*/project.yaml")`. **`terraform/modules/app-secrets`**, per
  environment: `vault_policy` `dokploy-project-<project>-<env>` (read `secret/data/<project>/<env>`,
  read+list the matching `secret/metadata/` path, read `secret/data/shared/<name>/<env>` for each shared
  secret, read `auth/token/lookup-self`); a `vault_token` from the `dokploy-provider` role with that
  policy, `renewable = true`, `renew_min_lease = 14 days`, `renew_increment = 768h`; and the empty path,
  by writing only `secret/metadata/<project>/<env>` (verify item 10). Output the tokens (sensitive) for
  `terraform/dokploy`.
- Snapshots: `vault_policy` `openbao-snapshots` (read `sys/storage/raft/snapshot`), a `vault_token`
  with `no_parent = true`, `period = 768h`, the same renewal settings, and `vault_kv_secret_v2`
  `infrastructure/production` holding `SNAPSHOT_TOKEN` and the GleSYS snapshot credential
  (`S3_ACCESS_KEY`, `S3_SECRET_KEY`) from `terraform/glesys`'s outputs.

**`oidc.tf`**: people's login, Google directly (plan, "People log in with Google").

```hcl
resource "vault_jwt_auth_backend" "oidc" {
  path               = "oidc"
  type               = "oidc"
  oidc_discovery_url = "https://accounts.google.com"
  bound_issuer       = "https://accounts.google.com"
  oidc_client_id     = var.openbao_oidc_client_id
  oidc_client_secret = var.openbao_oidc_client_secret
  default_role       = "infra-admin"
}

resource "vault_jwt_auth_backend_role" "infra_admin" {
  backend        = vault_jwt_auth_backend.oidc.path
  role_name      = "infra-admin"
  role_type      = "oidc"
  user_claim     = "email"
  oidc_scopes    = ["openid", "email"]
  allowed_redirect_uris = [
    "https://bao.kthais.com/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback",
  ]
  bound_claims = {
    hd    = "kthais.com"
    email = join(",", var.openbao_admin_emails)
  }
  token_policies = ["infra-admin"]
  token_ttl      = 3600
  token_max_ttl  = 3600
}
```

**`variables.tf`**: `openbao_jwt` (sensitive, ephemeral), `openbao_oidc_client_id`,
`openbao_oidc_client_secret` (sensitive), and `openbao_admin_emails`, defaulting to sam@, vilhelm@,
pavlos.spanoudakis@ and max.astrand@kthais.com.

**`terraform/dokploy/openbao.tf`**: `ui = true`, in this same PR, so the login page only exists once the
Google login does. The public route already passes `/ui` and `/v1/auth/oidc`.

**`tofu.yml`**: an `openbao-apply` job on `main`, `environment: production`,
`needs: [glesys-apply, dokploy-apply]` on this first run order (see plan, "Bootstrap order"), with
`permissions: id-token: write`. Before `tofu init`:

```sh
JWT=$(curl -sSf -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=https://bao.kthais.com" | jq -r .value)
echo "::add-mask::$JWT"
echo "TF_VAR_openbao_jwt=$JWT" >> "$GITHUB_ENV"
```

and the Google client from the `production` environment's secrets:

```yaml
env:
  TF_VAR_openbao_oidc_client_id: ${{ secrets.OPENBAO_OIDC_CLIENT_ID }}
  TF_VAR_openbao_oidc_client_secret: ${{ secrets.OPENBAO_OIDC_CLIENT_SECRET }}
```

No `openbao-plan` job on PRs: CI's OpenBao login is bound to `production`, which only runs on `main`,
and a read-only PR login would still read every secret while refreshing state. PRs get `tofu fmt` and
`tofu validate`; the apply run on `main` prints its plan first. Add a weekly `schedule:` trigger that
runs `openbao-apply`, which renews the tokens.

### D3. Merge and check
The `openbao-apply` job succeeds and its plan showed no changes to the imported resources.

**Google sign-in**, in a browser: `https://bao.kthais.com/ui`, method OIDC, role `infra-admin`, sign in
with a listed kthais.com account. The UI shows `secret/` with an empty `onboarding-service/production`
and `landingpage-backend/production`. `secret/infrastructure/` is denied. A kthais.com account not on the
list gets `claim "email" does not match`. From a laptop, `BAO_ADDR=https://bao.kthais.com bao login
-method=oidc role=infra-admin` works too.

**Break-glass**, on the host, _(in the container)_:

```sh
bao login -method=userpass username=<name>        # works; note the token
bao kv list secret/                                # works (may be empty)
bao kv get secret/infrastructure/production        # permission denied
bao write auth/userpass/users/test password=x token_policies=infra-admin   # permission denied (no cidr)
bao write auth/userpass/users/test password=x token_policies=terraform token_bound_cidrs=127.0.0.1/32  # denied
```

And the same admin token through the public route, **from the host** so it never leaves it:

```sh
curl -s -H "X-Vault-Token: <token>" https://bao.kthais.com/v1/auth/token/lookup-self   # permission denied
```

That's verify item 8. If it succeeds, the token binding isn't doing its job: stop and fix before Part E.

---

## Part E: Connect Dokploy, snapshots, and the first two apps

### E1. The PR: vault providers
In `terraform/dokploy`:
- A `terraform_remote_state` for `terraform/openbao` (with a `remote_state_data_sources` encryption
  entry), and the projects read with `fileset` and `yamldecode` as in `terraform/openbao`.
- `projects.tf`: `module "app"` per `project.yaml`. For `managed: false` projects
  (`terraform/modules/app` does only this), a `dokploy_vault_provider` per environment named
  `<project>-<env>`, assigned to the IDs from `project.yaml`:

  ```hcl
  hashicorp = {
    url              = "http://openbao:8200"
    mount            = "secret"
    token_wo         = var.token
    token_wo_version = parseint(substr(sha256(var.token), 0, 8), 16)
  }
  assignments       = [{ project_id = var.dokploy_project_id, environment_ids = [var.dokploy_environment_id] }]
  verify_connection = true
  ```

  The version comes from a hash of the token, so a new token reaches Dokploy without anyone bumping a
  number.
- `tofu.yml`: from now on, `dokploy-apply` needs `openbao-apply` (the steady-state order).

Merge. `verify_connection` proves every token works from Dokploy's server over `dokploy-network`.

### E2. The PR: snapshots
In `openbao.tf`, `dokploy_compose.openbao_snapshots` in the infrastructure project, two services sharing
a volume `snapshots`, both on `dokploy-network`:
- `snapshot`: `openbao/openbao:2.7.0`, loop: every 6 hours,
  `bao operator raft snapshot save /snapshots/openbao-$(date -u +%Y%m%dT%H%M%SZ).snap` with
  `BAO_ADDR=http://openbao:8200` and `BAO_TOKEN` from the env.
- `upload`: `rclone/rclone` (pinned), loop: `rclone move /snapshots glesys:openbao-snapshots`, then
  `rclone delete --min-age 30d glesys:openbao-snapshots`, with the S3 endpoint
  `https://objects.dc-sto1.glesys.net` and the credential from the env.
- The compose's `env`:

  ```
  BAO_TOKEN=$${{vault.infrastructure-production.infrastructure/production:SNAPSHOT_TOKEN}}
  S3_ACCESS_KEY=$${{vault.infrastructure-production.infrastructure/production:S3_ACCESS_KEY}}
  S3_SECRET_KEY=$${{vault.infrastructure-production.infrastructure/production:S3_SECRET_KEY}}
  ```

Merge. Within 6 hours (or restart the `snapshot` service to force one), a `.snap` file is in the
`openbao-snapshots` bucket.

### E3. Test a restore
Once, now, on the host, with a throwaway OpenBao that's never on a network:

```sh
# download the newest snapshot from the bucket to /tmp/restore-test.snap (rclone or any S3 client)
BAO=$(sudo docker ps -q --filter label=com.docker.compose.service=openbao)
sudo docker run -d --name bao-restore-test --network none \
  -v /etc/openbao/unseal.key:/openbao/unseal.key:ro \
  -e BAO_LOCAL_CONFIG="$(sudo docker inspect "$BAO" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^BAO_LOCAL_CONFIG=//p')" \
  openbao/openbao:2.7.0 server
sudo docker cp /tmp/restore-test.snap bao-restore-test:/tmp/
sudo docker exec -it -e BAO_ADDR=http://127.0.0.1:8200 bao-restore-test sh
```

_(in the test container)_: `bao operator init -recovery-shares=1 -recovery-threshold=1`, log in with the
throwaway root token, `bao operator raft snapshot restore -force /tmp/restore-test.snap`,
`bao status` (Sealed false), then `bao login -method=userpass username=<name>` with your real password
and `bao kv list secret/`: the real data is there. Then `sudo docker rm -f bao-restore-test` and delete
`/tmp/restore-test.snap`.

### E4. The first two apps
For **onboarding-service**, then **landingpage-backend**:

1. **Collect the current values.** In Dokploy, open the app → Environment. Note which variables are
   secrets. Copy the whole env into a 1Password item ("<app> env before OpenBao, <date>").
2. **Write them to OpenBao** in the UI (`https://bao.kthais.com/ui`, Google sign-in):
   `secret/onboarding-service/production` gets one key per secret (`MATTERMOST_BOT_TOKEN`,
   `GOOGLE_ADMIN_SERVICE_ACCOUNT_JSON`, …), and `secret/shared/onboarding-service-secret/production`
   gets `ONBOARDING_SERVICE_SECRET`, once, not per app. With the CLI from a laptop instead:
   `bao kv put secret/onboarding-service/production MATTERMOST_BOT_TOKEN=-` and paste the value, so it
   stays out of shell history.
3. **Replace values with references** in the app's Environment in the Dokploy UI. In the UI there's no
   `$$` escaping; that's only for HCL:

   ```
   MATTERMOST_BOT_TOKEN=${{vault.onboarding-service-production.onboarding-service/production:MATTERMOST_BOT_TOKEN}}
   ONBOARDING_SERVICE_SECRET=${{vault.onboarding-service-production.shared/onboarding-service-secret/production:ONBOARDING_SERVICE_SECRET}}
   ```

   Non-secret variables stay as they are.
4. **Save, then Deploy.** Check the deploy log, the app's health, and one real action that uses each
   secret (for onboarding-service: a Mattermost message; for landingpage-backend: a call to
   onboarding-service).
5. **Roll back** if anything fails: paste the old env from 1Password and redeploy.
6. After both apps have run on references for a week, archive the 1Password "env before" items.

### E5. Close out the plan's open checks
- **Verify item 1** (per-environment assignment): in onboarding-service's Dokploy project, create a
  throwaway environment `vault-test` with a one-line compose whose env references
  `onboarding-service-production`. Its deploy must fail. Delete the environment.
- **Verify item 2** (renewal keeps Dokploy working): after the first scheduled weekly run, in Dokploy →
  Settings → Secrets providers, "Test connection" on each provider still passes, and a redeploy of
  onboarding-service still resolves its references.
- **Verify item 3** (providers on UI-managed projects): E1 and E4 did it.

Update the plan's status line and the verify table with the results.
