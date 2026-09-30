# Infrastructure plan

_Written 2026-09-29. Revised 2026-09-30 to manage Dokploy with Terraform. Status: phase 1 scaffolded,
nothing applied._

## Goal

If the Dokploy VPS disappeared tomorrow, we should be able to rebuild core infrastructure from this repo
and 1Password, not from memory. We should also have a proper secret manager whose access we can control.

In scope: GCP resources, OpenBao as the org's secret manager, Dokploy's core configuration (registry,
secrets provider, git providers, backup destinations, notifications), and, project by project, the apps
running on Dokploy.

## Decisions

### Stay on Dokploy
We already run ~16 apps on it, and people know it. We considered Komodo (GPL-3.0, self-hosted, declarative
"Resource Syncs" in git), which does deployments-as-code natively. We rejected it to make the most of
what we already run, and accepted building some things ourselves.

### Terraform for Dokploy, with `vanillauys/dokploy`
_Reversed 2026-09-30._ We had rejected Terraform for Dokploy because we believed no stable provider
existed. [`vanillauys/dokploy`](https://registry.terraform.io/providers/vanillauys/dokploy) (MIT) is
good enough:

- Semver since v1.0.0, v1.7.0 as of 2026-09-19. An acceptance suite runs against a pinned Dokploy release
  (v0.30.7) on every PR and nightly.
- Covers what we need: projects, environments, applications, compose, the six database engines, domains,
  mounts, registries, the vault/OpenBao secrets provider, backup destinations and backups, notifications,
  users and permissions.
- Every secret attribute has a write-only companion (`*_wo` + `*_wo_version`), so secrets can stay out
  of state. Needs OpenTofu ≥ 1.11; we pin 1.12.6.
- Supports adopting a running server by import, with a read-only harness (`dogfood/`) that generates
  `import` blocks.

Risks we accept: it's unofficial and maintained by one person. Mitigations: pin the minor version
(`~> 1.7`), keep our Dokploy version at or above the one the provider targets, and fork it if it's
abandoned.

Terraform is now used for GCP (`hashicorp/google`), OpenBao (`hashicorp/vault`, API-compatible) and
Dokploy (`vanillauys/dokploy`). This replaces the custom reconciler we had designed for deployments as
code.

### What the Dokploy provider can't do
- **Create the GitHub App.** It's a browser flow, and Dokploy's API has no `github.create`. We register it
  by hand once, and `core.tf` declares it as a `dokploy_github_provider` data source looked up by its
  name in Dokploy. Project modules take its ID as an input, so the git provider is still defined in
  exactly one place. GitLab, Gitea and Bitbucket providers can be managed as resources, but
  we don't use them.
- **Create Dokploy's first admin and API key** on a fresh server. That's a manual step.
- **Trigger deploys as events.** It deploys when a service is created or changes (`deploy_on_change`,
  default `true`), and a failed deploy fails the apply. Redeploys on git push stay with Dokploy's GitHub
  integration.
- **Detect UI edits to secrets.** Dokploy masks vault provider secrets and omits registry passwords on
  read, so Terraform won't notice if someone changes them in the UI.

### Terraform owns a service completely, or not at all
`dokploy_application` and `dokploy_compose` write the service's whole source, build and env config on
every apply, so UI edits are overwritten. Once a project is in Terraform, its config changes go through
PRs. Projects not yet migrated stay UI-managed; nothing in Terraform touches them.

Database engines own their data volume. Never declare or import a `dokploy_mount` for a database's data
directory: destroying it deletes the data.

### Keeping secrets out of Dokploy's Terraform state
- `env` is a plain, non-sensitive string. It holds only non-secret config and OpenBao references
  (`$${{vault.<provider>.<path>:<field>}}`, `$$` escapes Terraform interpolation). Never interpolate a
  secret value into `env`.
- Secret attributes (database passwords, registry password, vault provider token, destination keys)
  always use the `*_wo` companion. To rotate, change the value and bump `*_wo_version`.
- The state still holds env strings and infrastructure layout, so it lives in the GCS state bucket with
  the same access restrictions as the rest.

### Secret manager: OpenBao, on the Dokploy VPS
- **Same host, not a dedicated VPS.** The secrets that matter are the apps' secrets, and they're
  decrypted on the Dokploy host anyway. A root compromise there exposes them wherever OpenBao runs.
  A second VPS would add patching, hardening and monitoring for little real gain.
- **Move to its own host when** we store high-value secrets that nothing on the VPS uses (GCP org admin,
  GitHub org tokens), add a second app host, or need Dokploy admins who shouldn't see all secrets.
  Migrating is just restoring a snapshot on the new host.
- **Deployed by Terraform** as a `dokploy_compose` in `terraform/dokploy`, from `dokploy-core/openbao/`.
  Its GCP SA keys are placed on the host by hand, not by Terraform: OpenBao can't fetch its own
  credentials from itself, and we keep them out of state.
- **UI disabled** (`ui = false`), no domain, no public Traefik route. Clients are on the Dokploy Docker
  network. People use the `bao` CLI over SSH port-forward or Tailscale.
- **Storage:** integrated Raft, single node.
- **Auto-unseal with GCP KMS**, so restarts don't leave it sealed and apps don't lose access to secrets.
  Recovery keys are split among 2–3 people and kept in 1Password.
- **Backups:** Raft snapshots on a cron to a GCS bucket. Snapshots are encrypted by OpenBao; restoring
  one on a fresh host auto-unseals because the KMS key still exists.

### Apps consume secrets through Dokploy's built-in secrets provider
Dokploy has a native HashiCorp Vault / OpenBao provider
([docs](https://docs.dokploy.com/docs/core/secrets-providers/hashicorp)). App env vars hold references,
not values:

```
DB_PASSWORD=${{vault.<provider>.<path>:<field>}}
```

Implications:
- **Token auth only.** Dokploy stores one OpenBao token per provider, with `read` + `list` on the paths
  it serves. The token is created by a script, not Terraform, to keep it out of state, and it needs a
  renewal plan. It's stored in 1Password and a GitHub environment secret, and passed to
  `dokploy_vault_provider` as `hashicorp.token_wo`.
- The provider is a `dokploy_vault_provider` resource with `verify_connection = true`, so a bad token
  fails the apply instead of the next deploy. `assignments` limits which projects can use it.
- **Scope follows providers.** Anyone who can edit env vars in Dokploy can reference any path that
  provider's token can read. To isolate secrets, add more providers with narrower tokens (e.g. per team).
- **Unverified:** whether references are resolved at deploy time and whether resolved values end up in
  Dokploy's database. Values will be visible in container env (`docker inspect`) either way. Test once
  OpenBao is up.
- The KV v2 mount name in OpenBao must match the provider config (Dokploy defaults to `secret`).
- Dokploy reaches OpenBao at `http://openbao:8200` on the internal network.

### Access control, and its limits
OpenBao policies give per-path, per-operation control. Some things can't be prevented on any platform:

| Who | Can read |
|---|---|
| Secret owners, via OpenBao policies | Exactly the paths they're granted |
| Operators of a service, via Dokploy access | That service's secrets (exec into the container) |
| Dokploy admins and anyone with host root | Everything |

So: keep Dokploy admins and SSH users to a minimum, give each project's Dokploy access and OpenBao
policy to the same people, and keep non-runtime secrets in paths no Dokploy provider token can read.

### OpenTofu, not Terraform
_Decided 2026-09-30._ OpenTofu is MPL-licensed (Terraform is BSL), all three providers are on its
registry, and ≥ 1.11 supports the write-only arguments we rely on. It can also encrypt state and plan
files client-side with a GCP KMS key, which we want now that Dokploy state holds every app's env. The
config language is unchanged, so directories keep the name `terraform/` and files stay `.tf`. CI pins
the version (`tofu_version` in the workflows).

### Terraform runs only in CI, never on a laptop
Applies to every root module, GCP, OpenBao and Dokploy alike.

- GitHub Actions authenticates to GCP with **workload identity federation**, so no service account keys
  are stored in GitHub.
- Two CI service accounts:
  - `terraform-plan`: read-only; used on PRs from any branch. Plans run with `-lock=false`.
  - `terraform-apply`: owner of the infra project; usable **only** by jobs in the `production` GitHub
    environment, which is limited to `main`.
- The one exception is `terraform/bootstrap`, which creates the CI identity itself. An org admin
  applies it once from Cloud Shell, then its state moves into GCS.
- **Dokploy auth:** an API key for a dedicated Dokploy `terraform` user, generated in the UI with rate
  limiting **off** (a rate-limited key answers `401` mid-apply, not `429`). Dokploy has no read-only
  API keys, so the plan job needs the same admin key as apply. We keep it in a `dokploy` GitHub
  environment and restrict repo write access to infra admins; anyone who can push a branch here can
  read that key.

### GCP layout
One project, **`kthais-infrastructure`**, for all shared infrastructure: Terraform state, CI identity,
OpenBao's KMS key and snapshot bucket. There's no separate OpenBao project, because the same admins
manage both and IAM can be set per key and per bucket. Region: `europe-north1`.

### 1Password holds break-glass material
OpenBao recovery keys, the `openbao-unseal` and `openbao-backup` SA keys, Dokploy admin credentials,
the Terraform Dokploy API key, and the Dokploy provider token for OpenBao. With the repo and the 1Password vault, anyone can rebuild everything.

## Repo layout

```
infrastructure/                       # github.com/kthaisociety/infrastructure (not created yet)
  terraform/
    bootstrap/    # project, tfstate bucket, WIF pool/provider, CI SAs        — org admin, once   [written]
    gcp/          # KMS unseal key, snapshot bucket, openbao-unseal/-backup SAs — CI              [written]
    openbao/      # KV v2, Google OIDC for people, policies, Dokploy provider policy — CI (self-hosted runner) [todo]
    dokploy/      # one root module for everything on Dokploy                     — CI                [todo]
      core.tf     #   registry (GHCR), vault provider, GitHub App lookup, backup destination, notifications
      openbao.tf  #   OpenBao compose service
      projects.tf #   module "<project>" { source = "./projects/<project>" } per project
      projects/<project>/  # everything one project runs: project, environments, apps, DBs, domains, backups
    modules/      # shared modules, extracted from projects/ once patterns repeat                  [later]
  dokploy-core/
    openbao/      # compose.yml, config.hcl (raft, gcpckms, ui=false), snapshot cron → GCS         [todo]
  scripts/        # dokploy-provider-token.sh                                                      [todo]
  docs/
    bootstrap.md  # one-time setup                                                                 [written]
    runbook.md    # disaster recovery, token rotation, adding a secret path                        [todo]
  .github/workflows/
    terraform-gcp.yml      # plan on PR, apply on main                                             [written]
    terraform-dokploy.yml  # plan on PR, apply on main                                             [todo]
```

### Why one Dokploy root module
Core resources (registry, vault provider, GitHub App, backup destination) are passed straight into each
project module as inputs, with no remote-state lookups. Each project module is self-contained, so it's
clear exactly what a project runs. With ~16 apps, one state and one plan are manageable. If plans get
slow or the blast radius gets uncomfortable, split projects into their own root modules later.

Project modules start as plain, explicit resources, even if they repeat each other. Once two or three
projects share a clear pattern (e.g. "Go backend + Postgres + domain + daily backup"), we extract it
into `terraform/modules/` and have projects call it.

## Phases

### Phase 1 — GCP foundation _(scaffolded, validated, not applied)_
1. Get a **billing account** for `kthais-infrastructure`. **Blocker:** the 2026-09-26 audit found no usable
   org billing account. Expected cost is well under $1/month.
2. Create the GitHub repo `kthaisociety/infrastructure` and push.
3. An org admin applies `terraform/bootstrap` from Cloud Shell, then migrates its state into GCS.
   Sam only has org read roles, so this needs someone with `projectCreator` and `billing.user`.
4. GitHub settings: a `production` environment limited to `main`; Actions variables `GCP_WIF_PROVIDER`,
   `GCP_PLAN_SA` and `GCP_APPLY_SA`; branch protection on `main`.
5. Merge a PR touching `terraform/gcp` to get it applied by CI.
6. Create the `openbao-unseal` and `openbao-backup` SA keys by hand and put them in 1Password.

### Phase 2 — Dokploy core in Terraform
1. We run Dokploy v0.30.8, which is newer than the provider's target (v0.30.7). Keep Dokploy at or above
   the provider's target when either is upgraded.
2. Create the Dokploy `terraform` user and its API key (UI, rate limiting off). Put it in 1Password and
   the `dokploy` GitHub environment.
3. CI uses GitHub-hosted runners; the panel's API is reachable from them with the API key.
4. Write `terraform/dokploy` with core resources only: GHCR `dokploy_registry`, `dokploy_github_provider`
   data source for the existing GitHub App, backup `dokploy_destination` (GCS via HMAC keys), and
   notifications. Import what already exists instead of recreating it.
5. Add `terraform-dokploy.yml` (plan on PR, apply on main). Apply, and confirm the next plan is empty.

### Phase 3 — Deploy OpenBao
1. Write `dokploy-core/openbao/`: OpenBao with Raft storage, the `gcpckms` seal and `ui = false`, plus a
   snapshot sidecar that uploads to the GCS bucket with the backup SA.
2. Place the SA keys from 1Password on the host by hand.
3. Add `openbao.tf` to `terraform/dokploy`: a project and a `dokploy_compose` with git source
   `dokploy-core/openbao/`, bind-mounting the SA keys. Apply via CI.
4. Run `bao operator init`. Recovery keys go to 1Password, split among key holders.
5. Verify auto-unseal by restarting the container, and verify a snapshot arrives in GCS.

### Phase 4 — Configure OpenBao as code
1. Self-hosted GitHub Actions runner on the VPS, since OpenBao isn't reachable from GitHub-hosted runners.
2. OpenBao JWT auth trusting GitHub Actions OIDC, bound to this repo on `main`, so CI has no static
   OpenBao token. Set this up with the initial root token, then revoke the root token.
3. Write `terraform/openbao/`: KV v2 mount, Google Workspace OIDC for people (groups → policies),
   per-app/team policies, a policy for the Dokploy provider token, and a file audit device.
4. Add a workflow for `terraform/openbao` (plan on PR, apply on main) running on the self-hosted runner.

### Phase 5 — Connect Dokploy to OpenBao
1. `scripts/dokploy-provider-token.sh` creates the provider token with the provider policy. Store it in
   1Password and the `dokploy` GitHub environment.
2. Add `dokploy_vault_provider` to `core.tf` with `token_wo` and `verify_connection = true`. Apply.
3. Check how references resolve (deploy time? stored?), and whether the token renews or expires.

### Phase 6 — Projects into Terraform, one at a time
The first project is **onboarding-service**: one Go app built from its Dockerfile, SQLite on a volume,
no database service. Its module is a `dokploy_project`, a `dokploy_application` from the GitHub App, a
`dokploy_mount` volume on `/data`, its domain, and a `dokploy_volume_backup` of `/data`. Its secrets
(`ONBOARDING_SERVICE_SECRET`, `MATTERMOST_BOT_TOKEN`, and the Google service account JSON, base64 in
`GOOGLE_ADMIN_SERVICE_ACCOUNT_JSON`) become OpenBao references. The service account JSON moves from a
file mount to an env reference, because a file mount's content would end up in state.

For each project:
1. Move its secrets into OpenBao.
2. Write `terraform/dokploy/projects/<project>/`. Generate `import` blocks with the provider's
   `dogfood/generate_imports.py` (read-only), then hand-write the config: env holds only non-secrets
   and `$${{vault.…}}` references, database passwords use `database_password_wo`.
3. Plan until the only diffs are the intended ones (secrets → references, plus the expected
   `deploy_on_change`/`deployment_timeout` diff after import). Apply; the service redeploys.
4. Tell the project's maintainers that config changes now go through PRs here.

Once a few projects are in, extract repeated patterns into `terraform/modules/`. Write
`docs/runbook.md` along the way: disaster recovery, token rotation, adding a secret path, adding a
project.

## Disaster recovery (target)

1. New VPS: install Docker and Dokploy, create the first admin. **Unverified** whether Dokploy's first
   admin and API key creation can be scripted; for now, assume a short manual step.
   Create the `terraform` user's API key and update the GitHub environment secret. Register the GitHub
   App again (browser flow) under the same name.
2. Start a fresh `terraform/dokploy` state: move the old state object in GCS aside (e.g. to
   `dokploy-lost-<date>/`) rather than deleting it. Every ID in it points at the dead server.
3. Place the OpenBao SA keys from 1Password on the host. Apply `terraform/dokploy` targeting core and
   OpenBao only.
4. Restore the latest Raft snapshot from GCS. It auto-unseals with KMS, and every secret and policy is back.
5. Apply `terraform/dokploy` in full. The vault provider and every Terraform-managed project are recreated
   and deployed. UI-managed projects are still recreated by hand.
6. Restore application data (databases, volumes) from backups. Every project module should define a
   `dokploy_backup` to the GCS destination, so this is covered for migrated projects.

## Open questions

- Billing account: whose is it, and who links it?
- Which org admin runs the bootstrap?
- How does Dokploy handle provider token expiry/renewal? Use a periodic token renewed by cron, or a
  long-TTL token rotated on a schedule?
- Is `europe-north2` (Stockholm) available and preferable to `europe-north1`?
