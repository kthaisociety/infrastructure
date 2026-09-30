# Infrastructure plan

_Written 2026-09-29. Revised 2026-09-30: Dokploy managed with OpenTofu, state and backups on GleSYS, no
GCP dependency for the foundation. Status: nothing written or applied yet._

## Goal

If the Dokploy VPS disappeared tomorrow, we should be able to rebuild core infrastructure from this repo,
GleSYS and 1Password, not from memory. We should also have a proper secret manager whose access we can
control.

In scope: OpenBao as the org's secret manager, Dokploy's core configuration (registry, secrets provider,
git providers, backup destinations, notifications), and, project by project, the apps running on
Dokploy. GCP resources come later (see [Later: GCP as code](#later-gcp-as-code)).

## Decisions

### Stay on Dokploy
We already run ~16 apps on it, and people know it. We considered Komodo (GPL-3.0, self-hosted, declarative
"Resource Syncs" in git), which does deployments-as-code natively. We rejected it to make the most of
what we already run, and accepted building some things ourselves.

### OpenTofu, not Terraform
_Decided 2026-09-30._ OpenTofu is MPL-licensed (Terraform is BSL), every provider we use is on its
registry, and ≥ 1.11 supports the write-only arguments we rely on. It also encrypts state and plan files
client-side, which we want now that state holds every app's env. The config language is unchanged, so
directories keep the name `terraform/` and files stay `.tf`. CI pins the version (`tofu_version` in the
workflows, currently 1.12.6).

### OpenTofu for Dokploy, with `vanillauys/dokploy`
_Reversed 2026-09-30._ We had rejected Terraform for Dokploy because we believed no stable provider
existed. [`vanillauys/dokploy`](https://registry.terraform.io/providers/vanillauys/dokploy) (MIT) is
good enough:

- Semver since v1.0.0, v1.7.0 as of 2026-09-19. An acceptance suite runs against a pinned Dokploy release
  (v0.30.7) on every PR and nightly.
- Covers what we need: projects, environments, applications, compose, the six database engines, domains,
  mounts, registries, the vault/OpenBao secrets provider, backup destinations and backups, notifications,
  users and permissions.
- Every secret attribute has a write-only companion (`*_wo` + `*_wo_version`), so secrets can stay out
  of state.
- Supports adopting a running server by import, with a read-only harness (`dogfood/`) that generates
  `import` blocks.

Risks we accept: it's unofficial and maintained by one person. Mitigations: pin the minor version
(`~> 1.7`), keep our Dokploy version at or above the one the provider targets, and fork it if it's
abandoned. This replaces the custom reconciler we had designed for deployments as code.

### What the Dokploy provider can't do
- **Create the GitHub App.** It's a browser flow, and Dokploy's API has no `github.create`. We register it
  by hand once, and `core.tf` declares it as a `dokploy_github_provider` data source looked up by its
  name in Dokploy. Project modules take its ID as an input, so the git provider is still defined in
  exactly one place. GitLab, Gitea and Bitbucket providers can be managed as resources, but we don't use
  them.
- **Create Dokploy's first admin and API key** on a fresh server. That's a manual step.
- **Trigger deploys as events.** It deploys when a service is created or changes (`deploy_on_change`,
  default `true`), and a failed deploy fails the apply. Redeploys on git push stay with Dokploy's GitHub
  integration.
- **Detect UI edits to secrets.** Dokploy masks vault provider secrets and omits registry passwords on
  read, so OpenTofu won't notice if someone changes them in the UI.

### OpenTofu owns a service completely, or not at all
`dokploy_application` and `dokploy_compose` write the service's whole source, build and env config on
every apply, so UI edits are overwritten. Once a project is in OpenTofu, its config changes go through
PRs. Projects not yet migrated stay UI-managed; nothing in OpenTofu touches them.

Database engines own their data volume. Never declare or import a `dokploy_mount` for a database's data
directory: destroying it deletes the data.

### Keeping secrets out of state
- `env` is a plain, non-sensitive string. It holds only non-secret config and OpenBao references
  (`$${{vault.<provider>.<path>:<field>}}`, `$$` escapes interpolation). Never interpolate a secret value
  into `env`.
- Secret attributes (database passwords, registry password, vault provider token, destination keys)
  always use the `*_wo` companion. To rotate, change the value and bump `*_wo_version`.
- State still holds env strings and infrastructure layout, so it's encrypted client-side before it
  reaches GleSYS (below).

### State and backups on GleSYS Object Storage
We already use GleSYS as an S3 backup destination, so state and OpenBao snapshots go there too. Nothing
in the foundation depends on GCP, so there's no GCP project, billing account or org-admin bootstrap.

- **GleSYS's model:** an object storage *instance* lives in one datacenter and holds buckets.
  *Credentials* belong to an instance and have full access to all of it; there's no per-bucket or
  read-only scoping in the GleSYS API. So we isolate by instance:

  | Instance (ID) | Used by |
  |---|---|
  | tfstate (`os-eea34`) | CI: OpenTofu state, bucket `kthais-tfstate` |
  | `openbao-snapshots` (new) | OpenBao's snapshot sidecar |
  | `website-psql-backups` (`os-8d2b7`) | Dokploy: backups of the website's Postgres |
  | `mattermost-backups` (`os-a273a`) | Mattermost's own backups |
  | `mattermost-file-storage` (`os-558b4`) | Mattermost's live file uploads (production data) |

  A leaked key for one instance can't touch the others. All are imported into `terraform/glesys` and
  `prevent_destroy`; consumers keep their existing credentials, which GleSYS can't import.
- **Managed in `terraform/glesys`** with the official [`glesys/glesys`](https://github.com/glesys/terraform-provider-glesys)
  provider (`glesys_objectstorage_instance`, `glesys_objectstorage_credential`). Instances can be
  imported; credentials can't, so existing ones get replaced by OpenTofu-managed ones and then deleted.
  Credential secret keys end up in state; state is encrypted.
- **Buckets** aren't in the GleSYS API. The state bucket is created by hand (it must exist before
  `tofu init`); the snapshot sidecar creates its own bucket if missing; the backups bucket exists.
- **Chicken-and-egg:** `terraform/glesys` stores its state in the `tfstate` instance it manages. Create
  that instance, the `kthais-tfstate` bucket and CI's credential by hand in the GleSYS UI, then import
  the instance. CI's credential stays hand-made: OpenTofu managing the key it runs with would be
  circular. Rotate it by hand.
- **State:** one bucket, one key per root module (`glesys/terraform.tfstate`, `dokploy/...`,
  `openbao/...`), via OpenTofu's `s3` backend with the GleSYS endpoint.
- **Encryption:** OpenTofu state and plan encryption with the `pbkdf2` key provider and `aes_gcm`,
  `enforced = true`. The passphrase lives in 1Password and a GitHub secret. GleSYS only ever stores
  ciphertext.
- **No locking:** GleSYS ignores S3 conditional writes (`If-None-Match`; tested 2026-09-30), so
  OpenTofu's `use_lockfile` can't work. It's still safe: applies run only in CI, one at a time via the
  workflow's concurrency group, and plans run with `-lock=false`. Never apply from a laptop.
- **Versioning** is enabled on the state bucket (tested 2026-09-30), so a bad or overwritten state can be
  restored from an earlier version.
- **Snapshots:** the `openbao-snapshots` instance. Its credential can read and delete snapshots too,
  since GleSYS can't scope it; bucket versioning (if GleSYS supports it) limits the damage.
- **App backups:** Dokploy's backup destination is `website-psql-backups`; new projects' backups go
  there too, or get their own instance.

Backend sketch, per root module:

```hcl
terraform {
  backend "s3" {
    bucket                      = "<state bucket>"
    key                         = "dokploy/terraform.tfstate"
    region                      = "<glesys region>"
    endpoints                   = { s3 = "<glesys endpoint>" }
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }

  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }
    state {
      method   = method.aes_gcm.state
      enforced = true
    }
    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}
```

### Secret manager: OpenBao, on the Dokploy VPS
- **Same host, not a dedicated VPS.** The secrets that matter are the apps' secrets, and they're
  decrypted on the Dokploy host anyway. A root compromise there exposes them wherever OpenBao runs.
  A second VPS would add patching, hardening and monitoring for little real gain.
- **Move to its own host when** we store high-value secrets that nothing on the VPS uses (GCP org admin,
  GitHub org tokens), add a second app host, or need Dokploy admins who shouldn't see all secrets.
  Migrating is just restoring a snapshot on the new host.
- **Deployed by OpenTofu** as a `dokploy_compose` in `terraform/dokploy`, from `dokploy-core/openbao/`.
  Its unseal key is placed on the host by hand, not by OpenTofu: OpenBao can't fetch its own key from
  itself, and we keep it out of state. The snapshot credential comes from `terraform/glesys`.
- **UI disabled** (`ui = false`), no domain, no public Traefik route. Clients are on the Dokploy Docker
  network. People use the `bao` CLI over SSH port-forward or Tailscale.
- **Storage:** integrated Raft, single node.
- **Auto-unseal with the [`static` seal](https://openbao.org/docs/configuration/seal/static/)**, so
  restarts don't leave it sealed and apps don't lose access to secrets. The 32-byte key
  (`openssl rand -out unseal.key 32`) is kept in 1Password and mounted as a file. It supports rotation
  through `current_key` / `previous_key`. Recovery keys from `bao operator init` are split among 2–3
  people and kept in 1Password.
- **Why not a cloud KMS:** with KMS the unseal key never touches the disk and can be revoked. With the
  static seal it sits on the host next to OpenBao's data. That doesn't change our threat model, since
  host root can already read every app's secret. What matters still holds: a snapshot stolen from GleSYS
  is useless without the key, which lives only on the host and in 1Password.
- **Backups:** Raft snapshots on a cron to the GleSYS snapshot bucket. Snapshots are encrypted by
  OpenBao; restoring one on a fresh host auto-unseals with the same static key.

### Apps consume secrets through Dokploy's built-in secrets provider
Dokploy has a native HashiCorp Vault / OpenBao provider
([docs](https://docs.dokploy.com/docs/core/secrets-providers/hashicorp)). App env vars hold references,
not values:

```
DB_PASSWORD=${{vault.<provider>.<path>:<field>}}
```

Implications:
- **Token auth only.** Dokploy stores one OpenBao token per provider (see the secret layout above).
- Each provider is a `dokploy_vault_provider` resource with `verify_connection = true`, so a bad token
  fails the apply instead of the next deploy.
- **Scope follows providers.** Anyone who can edit env vars in a Dokploy project can reference any path
  the providers assigned to it can read, which is why there's one provider per project and environment.
- **Unverified:** whether references are resolved at deploy time and whether resolved values end up in
  Dokploy's database. Values will be visible in container env (`docker inspect`) either way. Test once
  OpenBao is up.
- The KV v2 mount name in OpenBao must match the provider config (Dokploy defaults to `secret`).
- Dokploy reaches OpenBao at `http://openbao:8200` on the internal network.

### Secret layout: one Dokploy vault provider per project and environment
Dokploy's vault providers are assigned to specific projects and environments (`assignments` on
`dokploy_vault_provider`), and a service can only use providers assigned to its project and
environment. We use that as the isolation boundary:

- **Path layout** in the `secret` KV v2 mount: `<project>/<environment>`, one secret per project and
  environment, whose fields are the env var names. For example `onboarding-service/production` with
  fields `MATTERMOST_BOT_TOKEN`, `ONBOARDING_SERVICE_SECRET`, ….
- **One vault provider per project and environment**, named `<project>-<environment>`, assigned only to
  that Dokploy project and environment. Its token's policy can read only
  `secret/data/<project>/<environment>`. A reference looks like:

  ```
  MATTERMOST_BOT_TOKEN=${{vault.onboarding-service-production.onboarding-service/production:MATTERMOST_BOT_TOKEN}}
  ```

  So a project can't reference another project's secrets, and staging can't read production.
- **Shared secrets** (e.g. `ONBOARDING_SERVICE_SECRET`, which both `landingpage-backend` and
  onboarding-service need) live at `shared/<name>/<environment>`, and only the policies of the projects
  that need them can read it.
- **People:** a policy per project lets its owners (a Google group, via OIDC) write
  `secret/data/<project>/*`. They set secrets with `bao kv put` / `bao kv patch`.
- **One list of projects and environments**, `terraform/projects.yaml`, read by both root modules, so
  adding a project is one entry.

Tokens are created by OpenTofu, not a script: with ~16 projects × environments there are too many to
manage by hand. `terraform/openbao` creates each project-environment's policy and token, and
`terraform/dokploy` reads the tokens from `terraform/openbao`'s state (`terraform_remote_state`) and
passes them to `dokploy_vault_provider` as `token_wo`. This puts tokens in both states, which are
encrypted. (`terraform/dokploy`'s encryption block needs a `remote_state_data_sources` entry
with the same passphrase to read it.) The order is always openbao → dokploy, and no module depends on the other in reverse.

**Token lifetime:** periodic tokens, renewed by a scheduled workflow that runs `terraform/openbao`
weekly. **Verify** that renewing a token doesn't require updating Dokploy (it shouldn't: the token
string stays the same).

### Access control, and its limits
OpenBao policies give per-path, per-operation control. Some things can't be prevented on any platform:

| Who | Can read |
|---|---|
| Secret owners, via OpenBao policies | Exactly the paths they're granted |
| Operators of a service, via Dokploy access | That service's secrets (exec into the container) |
| Dokploy admins and anyone with host root | Everything |

So: keep Dokploy admins and SSH users to a minimum, give each project's Dokploy access and OpenBao
policy to the same people, and keep non-runtime secrets in paths no Dokploy provider token can read.

### OpenTofu runs only in CI, never on a laptop
Every root module is planned on PRs and applied on merge to `main` by GitHub Actions.

- **Secrets:** `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (the `tfstate` credential, read by the S3
  backend), `TF_VAR_state_passphrase`, `GLESYS_USERID` / `GLESYS_TOKEN` (GleSYS API key for
  `terraform/glesys`), and later the Dokploy API key. GleSYS credentials can't be read-only, so plan and apply use the same
  ones. Plans run with `-lock=false`.
- **Apply** runs only in the `production` environment, limited to `main`.
- **Order on merge:** `glesys` → `openbao` → `dokploy`, as jobs in one workflow. `openbao` runs on the
  self-hosted runner; the others on GitHub-hosted runners.
- **Dokploy auth:** an API key for a dedicated Dokploy `terraform` user, generated in the UI with rate
  limiting **off** (a rate-limited key answers `401` mid-apply, not `429`). Dokploy has no read-only
  API keys, so plan needs the same admin key as apply.
- Because plan needs these secrets, anyone who can push a branch here can read them. Repo write access
  is limited to infra admins.

### 1Password holds break-glass material
OpenBao recovery keys and static unseal key, the GleSYS API key and the `tfstate` credential, the
state encryption passphrase, Dokploy admin credentials, the `terraform` user's Dokploy API key, and
the Dokploy provider token for OpenBao. With the repo, GleSYS and the 1Password vault, anyone can rebuild
everything.

## Repo layout

```
infrastructure/                       # github.com/kthaisociety/infrastructure (private)
  terraform/
    projects.yaml # every project and its environments; read by openbao/ and dokploy/
    glesys/       # object storage instances, credentials, buckets                     — CI                [todo]
    dokploy/      # one root module for everything on Dokploy                     — CI                [todo]
      core.tf     #   registry (GHCR), GitHub App lookup, backup destination, notifications
      vault.tf    #   one dokploy_vault_provider per project-environment, tokens from openbao state
      openbao.tf  #   OpenBao compose service
      projects.tf #   module "<project>" { source = "./projects/<project>" } per project
      projects/<project>/  # everything one project runs: project, environments, apps, DBs, domains, backups
    openbao/      # KV v2, Google OIDC for people, per project-env policies and tokens — CI (self-hosted runner) [todo]
    modules/      # shared modules, extracted from projects/ once patterns repeat                  [later]
    gcp/          # GCP projects, OAuth clients, etc.                                               [later]
  dokploy-core/
    openbao/      # compose.yml, config.hcl (raft, static seal, ui=false), snapshot cron → GleSYS  [todo]
  docs/
    runbook.md    # disaster recovery, token rotation, adding a secret path                        [todo]
  .github/workflows/
    tofu.yml      # plan on PR, apply on main: glesys → openbao → dokploy; weekly token renewal  [todo]
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

### Phase 1 — GleSYS and GitHub
1. In the GleSYS UI: create the `tfstate` instance, a credential on it, and the `kthais-tfstate` bucket
   (with any S3 client). Create a GleSYS API key. Store both in 1Password.
2. Generate the state passphrase and store it in 1Password.
3. GitHub settings: a `production` environment limited to `main`, the secrets above, and branch
   protection on `main`.
4. `terraform/glesys` _(written 2026-09-30)_: imports the four existing instances, and creates the
   `openbao-snapshots` instance and the snapshot sidecar's credential. `tofu.yml` plans it on PRs and applies it on merge.
5. _(Done 2026-09-30)_ Tested GleSYS: versioning works, conditional writes don't.

### Phase 2 — Dokploy core in OpenTofu
1. We run Dokploy v0.30.8, which is newer than the provider's target (v0.30.7). Keep Dokploy at or above
   the provider's target when either is upgraded.
2. Create the Dokploy `terraform` user and its API key (UI, rate limiting off). Put it in 1Password and
   GitHub.
3. CI uses GitHub-hosted runners; the panel's API is reachable from them with the API key.
4. Write `terraform/dokploy` with core resources only: GHCR `dokploy_registry`, the
   `dokploy_github_provider` data source for the existing GitHub App, the GleSYS backup
   `dokploy_destination` for `website-psql-backups`, and notifications. Import what already exists instead of recreating it.
5. Add the `dokploy` job to `tofu.yml`. Apply, and confirm the next plan is empty.

### Phase 3 — Deploy OpenBao
1. Write `dokploy-core/openbao/`: OpenBao with Raft storage, the `static` seal and `ui = false`, plus a
   snapshot sidecar that uploads to the `openbao-snapshots` instance.
2. Generate the unseal key, store it in 1Password, and place it on the host by hand. The snapshot
   credential comes from `terraform/glesys`'s state into the compose's env.
3. Add `openbao.tf` to `terraform/dokploy`: a project and a `dokploy_compose` with git source
   `dokploy-core/openbao/`, bind-mounting the unseal key. Apply via CI.
4. Run `bao operator init`. Recovery keys go to 1Password, split among key holders.
5. Verify auto-unseal by restarting the container, and verify a snapshot arrives in GleSYS.

### Phase 4 — Configure OpenBao as code
1. Self-hosted GitHub Actions runner on the VPS, since OpenBao isn't reachable from GitHub-hosted runners.
2. OpenBao JWT auth trusting GitHub Actions OIDC, bound to this repo on `main`, so CI has no static
   OpenBao token. Set this up with the initial root token, then revoke the root token.
3. Write `terraform/openbao/`: KV v2 mount, Google Workspace OIDC for people (groups → policies), a
   file audit device, and, from `projects.yaml`, a policy and periodic token per project-environment
   plus an owner policy per project.
4. Add the `openbao` job to `tofu.yml` (self-hosted runner), and the weekly renewal schedule.

### Phase 5 — Connect Dokploy to OpenBao
1. Add `vault.tf` to `terraform/dokploy`: a `dokploy_vault_provider` per project-environment, tokens
   from `terraform/openbao`'s state, `verify_connection = true`. Apply.
2. Check how references resolve (deploy time? stored?), and that a renewed token keeps working.

### Phase 6 — Projects into OpenTofu, one at a time
The first project is **onboarding-service**: one Go app built from its Dockerfile, SQLite on a volume,
no database service. Its module is a `dokploy_project`, a `dokploy_application` from the GitHub App, a
`dokploy_mount` volume on `/data`, its domain, and a `dokploy_volume_backup` of `/data`. Its secrets
(`ONBOARDING_SERVICE_SECRET`, `MATTERMOST_BOT_TOKEN`, and the Google service account JSON, base64 in
`GOOGLE_ADMIN_SERVICE_ACCOUNT_JSON`) become OpenBao references. The service account JSON moves from a
file mount to an env reference, because a file mount's content would end up in state.

For each project:
1. Add it to `projects.yaml` and apply, so its policies, token and vault provider exist. Its owners
   write its secrets to `<project>/<environment>`.
2. Write `terraform/dokploy/projects/<project>/`. Generate `import` blocks with the provider's
   `dogfood/generate_imports.py` (read-only), then hand-write the config: env holds only non-secrets
   and `$${{vault.…}}` references, database passwords use `database_password_wo`.
3. Plan until the only diffs are the intended ones (secrets → references, plus the expected
   `deploy_on_change`/`deployment_timeout` diff after import). Apply; the service redeploys.
4. Tell the project's maintainers that config changes now go through PRs here.

Once a few projects are in, extract repeated patterns into `terraform/modules/`. Write
`docs/runbook.md` along the way: disaster recovery, token rotation, adding a secret path, adding a
project.

## Later: GCP as code

`terraform/gcp/` will define GCP projects, OAuth clients and similar. It's not part of the foundation
above, and nothing above depends on it. When we pick it up:

- **CI needs a GCP identity** with org-level roles (e.g. `projectCreator`), which only an org admin can
  grant. That means a one-time bootstrap: workload identity federation from GitHub Actions plus plan and
  apply service accounts. A version of this was written and then removed; it's in the first commit
  (`6d3958c`, `terraform/bootstrap/`). Its state goes in GleSYS like everything else.
- **Billing** isn't needed for projects that only hold OAuth clients and free APIs. We need it only if we
  use paid services. If we do, the billing account belongs to the organization, not a person:
  1. Create it inside the kthais.com org, from a kthais.com account (not a personal Gmail).
  2. Payments profile of type Organization/Business in KTHAIS's name and registration number, paid with
     KTHAIS's own card from the treasurer (invoicing only applies at much higher spend).
  3. Grant `billing.admin` to a Google group (e.g. `gcp-billing-admins@kthais.com`, 2+ members including
     the treasurer), then remove the creator's personal role. Grant `billing.user` to whoever applies
     `terraform/gcp`.
  4. A budget alert (e.g. $5/month) to that group.
- **OAuth clients:** as far as we know, standard OAuth client IDs for Google Sign-In can't be created
  through the API. That's fine: the identity service will be the only Google OAuth client, with only
  its own callback URLs registered in Google. It's created by hand once. Projects become clients of the
  identity service instead, and their allowed return URLs are an exact-match allowlist in the identity
  service's config, in code. See [identity-service.md](identity-service.md).
- **Good candidates:** service accounts apps use (e.g. onboarding-service's Workspace admin account),
  enabled APIs, and IAM. Key creation and domain-wide delegation in the Workspace admin console stay
  manual.
- Existing projects, such as the one holding the kthais.com sign-in client, would be imported.

## Disaster recovery (target)

1. New VPS: install Docker and Dokploy, create the first admin. **Unverified** whether Dokploy's first
   admin and API key creation can be scripted; for now, assume a short manual step.
   Create the `terraform` user's API key and update the GitHub secret. Register the GitHub App again
   (browser flow) under the same name.
2. Start a fresh `terraform/dokploy` state: move the old state object in GleSYS aside (e.g. to
   `dokploy-lost-<date>/`) rather than deleting it. Every ID in it points at the dead server.
3. Place the OpenBao unseal key from 1Password on the host. Apply `terraform/dokploy`
   targeting core and OpenBao only.
4. Restore the latest Raft snapshot from GleSYS. It auto-unseals with the static key, and every secret
   and policy is back.
5. Apply `terraform/dokploy` in full. The vault provider and every OpenTofu-managed project are
   recreated and deployed. UI-managed projects are still recreated by hand.
6. Restore application data (databases, volumes) from GleSYS backups. Every project module should
   define a backup to the GleSYS destination, so this is covered for migrated projects.

## Open questions

- Does Dokploy block a service from referencing a provider not assigned to its project and environment?
  The docs imply so; test before relying on it.
