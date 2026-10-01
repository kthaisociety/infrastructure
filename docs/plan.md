# Infrastructure plan

_Written 2026-09-29. Revised 2026-09-30: Dokploy managed with OpenTofu, state and backups on GleSYS, no
GCP dependency for the foundation. Revised again 2026-09-30: lessons from the DD2482 prototype, OpenBao's
deployment and bootstrap order settled, app delivery through this repo, OpenBao's API public with no
personal logins for now, and phases reordered so OpenBao comes first. Revised 2026-10-01: people log in
to OpenBao with Google and the UI is on; projects are folders read by shared modules; existing projects
are rebuilt as new OpenTofu-built ones and their data migrated, not imported. Status
(2026-10-01): `terraform/glesys` applied; OpenBao deployed by `terraform/dokploy`, initialized by hand and
public at `bao.kthais.com` (runbook Parts A–C done). Next: Part D._

**Next milestone:** OpenBao defined in this repo, running on the VPS, and serving secrets to one or two
apps (Phases 2–5). Everything after that is ordered but not scheduled.

## Goal

If the Dokploy VPS disappeared tomorrow, we should be able to rebuild core infrastructure from this repo,
GleSYS and 1Password, not from memory. We should also have a proper secret manager whose access we can
control.

In scope: OpenBao as the org's secret manager, Dokploy's core configuration (registry, secrets provider,
git providers, backup destinations, notifications), and, project by project, the apps running on
Dokploy, including which version of each app runs. GCP resources come later (see
[Later: GCP as code](#later-gcp-as-code)).

## What we're building

| Piece | What it is | Where |
|---|---|---|
| State and backups | GleSYS object storage, one instance per consumer; OpenTofu state encrypted client-side | `terraform/glesys` |
| Dokploy core | GHCR registry, GitHub App lookup, backup destination, notifications | `terraform/dokploy/core.tf` |
| OpenBao | A `dokploy_compose` on the VPS: Raft, static-key auto-unseal, API and UI at `bao.kthais.com` | `terraform/dokploy/openbao.tf` |
| OpenBao snapshots | A second compose that uploads Raft snapshots to GleSYS on a cron | `terraform/dokploy/openbao.tf` |
| OpenBao config | KV mount, auth for CI (GitHub) and people (Google), one policy and token per project-environment | `terraform/openbao` |
| Secrets providers | One Dokploy vault provider per project-environment | `terraform/dokploy`, from each `project.yaml` |
| Projects | One folder per project: a `project.yaml` both roots read, built by a shared module per app type | `terraform/projects/<project>/`, `terraform/modules/` |
| Deploys | App repos build images; this repo records the tag in git and applies | `.github/workflows/deploy.yml` |

Every change to any of it goes through a PR to this repo, and only this repo's CI applies it.

## Where the lessons come from

Several choices below were tested in a prototype built for the DD2482 course (a separate repo, not
KTHAIS infrastructure): a Dokploy cluster on GCP managed by Terraform stages with the same
`vanillauys/dokploy` provider, OpenBao 2.7 with a static seal, per-project Dokploy vault providers, and CI
that builds images and deploys them through Dokploy's API. Findings from it are marked _(prototype)_. They
were verified on Dokploy v0.30.7; we run v0.30.8.

## Decisions

### Stay on Dokploy
We already run ~16 apps on it, and people know it. We considered Komodo (GPL-3.0, self-hosted, declarative
"Resource Syncs" in git), which does deployments-as-code natively. We rejected it to make the most of
what we already run, and accepted building some things ourselves.

### OpenTofu, not Terraform
_Decided 2026-09-30._ OpenTofu is MPL-licensed (Terraform is BSL), every provider we use is on its
registry, and ≥ 1.11 supports the write-only arguments we rely on. It also encrypts state and plan files
client-side, which we want now that state holds every app's env. The config language is unchanged, so
directories keep the name `terraform/` and files stay `.tf`. CI pins the version (`TOFU_VERSION` in the
workflows, currently 1.12.6).

### OpenTofu for Dokploy, with `vanillauys/dokploy`
_Reversed 2026-09-30._ We had rejected Terraform for Dokploy because we believed no stable provider
existed. [`vanillauys/dokploy`](https://registry.terraform.io/providers/vanillauys/dokploy) (MIT) is
good enough:

- Semver since v1.0.0, v1.7.0 as of 2026-09-19. An acceptance suite runs against a pinned Dokploy release
  (v0.30.7) on every PR and nightly. The prototype used it end to end without hitting a provider bug.
- Covers what we need: projects, environments, applications, compose, the six database engines, domains,
  mounts, registries, the vault/OpenBao secrets provider, backup destinations and backups, notifications,
  users and permissions.
- Most secret attributes have a write-only companion (`*_wo` + `*_wo_version`), so those secrets stay
  out of state. Exception: an application's `docker.password` (see
  [Apps run images](#apps-run-images-built-by-their-own-repos-deployed-by-this-one)).
- Supports adopting a running server by import, with a read-only harness (`dogfood/`) that generates
  `import` blocks.

Risks we accept: it's unofficial and maintained by one person. Mitigations: pin the minor version
(`~> 1.8.0`), keep our Dokploy version at or above the one the provider targets, and fork it if it's
abandoned. This replaces the custom reconciler we had designed for deployments as code.

### What the Dokploy provider can't do
- **Create the GitHub App.** It's a browser flow, and Dokploy's API has no `github.create`. We register it
  by hand once, and `core.tf` declares it as a `dokploy_github_provider` data source looked up by its
  name in Dokploy. Project modules take its ID as an input, so the git provider is still defined in
  exactly one place. GitLab, Gitea and Bitbucket providers can be managed as resources, but we don't use
  them.
- **Create Dokploy's first admin and API key** on a fresh server. That's a manual step.
- **Create an API key for another user.** `dokploy_api_key` only makes keys for the user the provider
  authenticates as. This is one reason deploys are centralized in this repo rather than handed out per
  app.
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
  into `env`, including values read from another root module's state.
- Secret attributes (database passwords, registry password, vault provider token, destination keys)
  always use the `*_wo` companion where one exists. To rotate, change the value and bump `*_wo_version`.
- State still holds env strings, infrastructure layout, the GleSYS credentials `terraform/glesys`
  creates, OpenBao tokens and GHCR pull credentials, so it's encrypted client-side before it reaches
  GleSYS (below).

### State and backups on GleSYS Object Storage
We already use GleSYS as an S3 backup destination, so state and OpenBao snapshots go there too. Nothing
in the foundation depends on GCP, so there's no GCP project, billing account or org-admin bootstrap.

- **GleSYS's model:** an object storage *instance* lives in one datacenter and holds buckets.
  *Credentials* belong to an instance and have full access to all of it; there's no per-bucket or
  read-only scoping in the GleSYS API. So we isolate by instance:

  | Instance (ID) | Used by |
  |---|---|
  | tfstate (`os-eea34`) | CI: OpenTofu state, bucket `kthais-tfstate` |
  | `openbao-snapshots` (new) | OpenBao's snapshot job |
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
  `tofu init`); the snapshot job creates its own bucket if missing; the backups bucket exists.
- **Chicken-and-egg:** `terraform/glesys` stores its state in the `tfstate` instance it manages. Create
  that instance, the `kthais-tfstate` bucket and CI's credential by hand in the GleSYS UI, then import
  the instance. CI's credential stays hand-made: OpenTofu managing the key it runs with would be
  circular. Rotate it by hand.
- **State:** one bucket, one key per root module (`glesys/terraform.tfstate`, `dokploy/...`,
  `openbao/...`), via OpenTofu's `s3` backend with the GleSYS endpoint.
- **Encryption:** OpenTofu state and plan encryption with the `pbkdf2` key provider and `aes_gcm`,
  `enforced = true`. The passphrase lives in 1Password and a GitHub secret. GleSYS only ever stores
  ciphertext. A root module that reads another's state needs a `remote_state_data_sources` entry with
  the same passphrase.
- **No locking:** GleSYS ignores S3 conditional writes (`If-None-Match`; tested 2026-09-30), so
  OpenTofu's `use_lockfile` can't work. It's still safe: applies run only in CI, one at a time via one
  concurrency group shared by every workflow that applies (`tofu.yml` and `deploy.yml`), and plans run
  with `-lock=false`. Never apply from a laptop.
- **Versioning** is enabled on the state bucket (tested 2026-09-30), so a bad or overwritten state can be
  restored from an earlier version.
- **App backups:** Dokploy's backup destination is `website-psql-backups`; new projects' backups go
  there too, or get their own instance.

`terraform/glesys/versions.tf` is the reference backend and encryption block; every root module copies
it with its own `key`.

### Secret manager: OpenBao, on the Dokploy VPS
- **Same host, not a dedicated VPS.** The secrets that matter are the apps' secrets, and they're
  decrypted on the Dokploy host anyway (see [Where resolved values end up](#where-resolved-values-end-up)).
  A root compromise there exposes them wherever OpenBao runs. A second VPS would add patching, hardening
  and monitoring for little real gain.
- **Move to its own host when** we store high-value secrets that nothing on the VPS uses (GCP org admin,
  GitHub org tokens), add a second app host, or need Dokploy admins who shouldn't see all secrets.
  Migrating is just restoring a snapshot on the new host.
- **Storage:** integrated Raft, single node. OpenBao's recommended storage, and it's what
  `bao operator raft snapshot` backs up.
- **Auto-unseal with the [`static` seal](https://openbao.org/docs/configuration/seal/static/)**, so
  restarts don't leave it sealed and deploys that reference secrets don't fail. The 32-byte key
  (`openssl rand -out unseal.key 32`) is kept in 1Password and mounted as a file. The key id in the
  config must stay paired with the key for the life of the data. Rotation goes through `current_key` /
  `previous_key`. _(prototype: a forced restart came back unsealed within two seconds.)_
- **Why not a cloud KMS:** with KMS the unseal key never touches the disk and can be revoked. With the
  static seal it sits on the host next to OpenBao's data. That doesn't change our threat model, since
  host root can already read every app's secret. What matters still holds: a snapshot stolen from GleSYS
  is useless without the key, which lives only on the host and in 1Password.
- **UI behind Google sign-in** (`ui = true` from Phase 4; off until then). The API and UI are public at
  `bao.kthais.com` (see [OpenBao's API is public](#openbaos-api-is-public-hardened)). Dokploy's server
  and the snapshot job reach it at `http://openbao:8200` on `dokploy-network`. The break-glass
  `userpass` login works only inside the container (`ssh` to the host, then `docker exec`), against
  `http://127.0.0.1:8200`. No port is published on the host at all.

### OpenBao's deployment: a compose file written in OpenTofu
_Changed 2026-09-30._ OpenBao is a `dokploy_compose` in `terraform/dokploy/openbao.tf` whose compose file
is built with `yamlencode` from an HCL object, and whose OpenBao config is passed as `jsonencode(...)` in
the image's `BAO_LOCAL_CONFIG` env var. The image's entrypoint writes it to its config directory.

- **Why:** no files to keep in sync with the host, no git source or GitHub App dependency for core
  infrastructure, and no templating: values go straight in. _(prototype: the registry, OpenBao and the CI
  runners were all deployed this way.)_
- **Rejected:** a git-sourced compose from `dokploy-core/openbao/`, the previous plan. It needs the GitHub
  App to deploy the secret manager, and splits one service's definition across two places.
- **Cost:** Dokploy shows the compose file in its UI, so it must hold no secrets. It doesn't: the unseal
  key is a mounted file, and the snapshot job is a separate compose (below).
- **The public route is Traefik labels in the compose file**, not a `dokploy_domain`. _(prototype)_
  Dokploy adds a domain's labels only when it deploys the service, and nothing redeploys it after a
  `dokploy_domain` is created, so the route would be missing until someone redeployed by hand. The cost
  is that the domain doesn't show in Dokploy's UI.
- Compose interpolation still applies to the generated file: a literal `$` is `$$`.
- The unseal key is placed on the host by hand, at a fixed path readable by the container's user, and
  bind-mounted. OpenBao can't fetch its own key from itself, and we keep it out of state.
- The service joins `dokploy-network` (external) with the alias `openbao`, so the address doesn't depend
  on Dokploy's generated app name.

### OpenBao is initialized by hand, once
_Decided 2026-09-30._ After the first deploy, an operator runs `bao operator init` inside the container. It returns
recovery keys (3 shares, threshold 2: Sam, Vilhelm and the org break-glass vault, each in 1Password; done
2026-10-01) and a root token. The root token sets up the
GitHub Actions JWT auth for this repo and the first infra admin logins (Phase 3), and is then revoked.

- **Why:** initialization happens once in the life of the data. A rebuilt host restores a snapshot and
  isn't initialized again, so automating it saves nothing later. Manual init gives us recovery keys
  directly, and we want them as break-glass.
- **Rejected:** OpenBao's self-initialization (`initialize` blocks in the config). The prototype used it:
  on first start OpenBao runs a list of API requests as a root token it then revokes. It makes sense on a
  cluster rebuilt from scratch every day, and when OpenBao is public from the first second. Neither is
  true here. It produces no recovery keys; those would have to be generated afterwards through the
  authenticated rotation endpoints, which is a manual step anyway.

### OpenBao snapshots: their own compose, credentials from OpenBao
A second `dokploy_compose`, `openbao-snapshots`: a small container that runs
`bao operator raft snapshot save` on a cron and uploads the file to the `openbao-snapshots` GleSYS
instance, creating the bucket if missing.

- **Its credentials come from OpenBao, not from state.** `terraform/openbao` reads the GleSYS credential
  from `terraform/glesys`'s state, creates a periodic token that can only read
  `sys/storage/raft/snapshot`, and writes both to `secret/infrastructure/production`. The compose's env
  holds only `${{vault.infrastructure-production....}}` references. This fixes a contradiction in the
  previous plan, which put the GleSYS credential into a compose env from state.
- **Why a separate compose:** its references can only resolve once OpenBao is configured and the
  `infrastructure-production` provider exists. Kept apart, OpenBao itself deploys with nothing to resolve,
  which is what the bootstrap order and disaster recovery need.
- Snapshots are encrypted by OpenBao; restoring one on a fresh host auto-unseals with the same static key.
- The GleSYS credential can also read and delete snapshots, since GleSYS can't scope it. Bucket
  versioning, if GleSYS supports it on that instance, limits the damage.

### Apps consume secrets through Dokploy's built-in secrets provider
Dokploy has a native HashiCorp Vault / OpenBao provider
([docs](https://docs.dokploy.com/docs/core/secrets-providers/hashicorp)). App env vars hold references,
not values:

```
DB_PASSWORD=${{vault.<provider>.<path>:<field>}}
```

Settled _(prototype)_:
- **References are resolved by Dokploy's server at deploy time.** Dokploy's database only stores the
  reference (`compose.one` returns the reference, the container gets the value).
- **A changed secret takes effect only after a redeploy.** Rotating a secret is `bao kv patch`, then
  redeploy the service. Nothing redeploys automatically when a value changes in OpenBao.
- **Dokploy refuses a provider that isn't assigned to the service's project.** Using another project's
  provider fails with a 403 (`listSecretNames`), even when the path exists.
- **Token auth only.** Dokploy stores one OpenBao token per provider and never renews it.
- Each provider is a `dokploy_vault_provider` with `verify_connection = true`, so a bad token fails the
  apply instead of the next deploy. The test runs from Dokploy's server, so it also proves Dokploy
  reaches `http://openbao:8200`.
- The KV v2 mount is named `secret`, Dokploy's default.

### Where resolved values end up
"Never in Dokploy's database" is true, but resolved values aren't only in OpenBao _(prototype)_:

- For a compose, Dokploy writes them to `/etc/dokploy/compose/<app>/code/.env` on the host.
- They're in the container's or service's spec (`docker inspect`, `docker service inspect`).

So root on the host can read every deployed secret. That's inherent to injecting env vars at deploy
time, and it's why [Access control](#access-control-and-its-limits) treats host root as "everything".

### Secret layout: one Dokploy vault provider per project and environment
Dokploy's vault providers are assigned to specific projects and environments (`assignments` on
`dokploy_vault_provider`), and a service can only use providers assigned to its project. We use that as
the isolation boundary:

- **Path layout** in the `secret` KV v2 mount: `<project>/<environment>`, one secret per project and
  environment, whose fields are the env var names. For example `onboarding-service/production` with
  fields `MATTERMOST_BOT_TOKEN`, `ONBOARDING_SERVICE_SECRET`, ….
- **One vault provider per project and environment**, named `<project>-<environment>`, assigned only to
  that Dokploy project and environment. A reference looks like:

  ```
  MATTERMOST_BOT_TOKEN=${{vault.onboarding-service-production.onboarding-service/production:MATTERMOST_BOT_TOKEN}}
  ```

  So a project can't reference another project's secrets, and staging can't read production.
- **Two independent fences.** Dokploy refuses a provider from another project, and even a wrong
  assignment can't read another project's path, because the token's policy doesn't allow it.
- **The token's policy.** Read on `secret/data/<project>/<environment>`, read and list on the matching
  `secret/metadata/` path for the env editor's autocomplete, and read on `auth/token/lookup-self`.
  _(prototype)_ Dokploy's connection test validates the token with `lookup-self`, which normally comes
  from the `default` policy. Our tokens have no default policy, and without that one grant
  `verify_connection` fails with a bare `token validation failed (status 403)` although reads would work.
  We grant `lookup-self` alone rather than all of `default`.
- **Shared secrets** (e.g. `ONBOARDING_SERVICE_SECRET`, which both `landingpage-backend` and
  onboarding-service need) live at `shared/<name>/<environment>`, and only the policies of the projects
  that need them can read it.
- **Who writes secrets:** infra admins, in the UI (see
  [People log in with Google](#people-log-in-with-google-userpass-is-break-glass)). Later, each project's owners
  write their own `secret/data/<project>/*`. OpenTofu never writes app secrets; the one exception is
  `infrastructure/production`, which only OpenTofu writes.
- **One folder per project**, `terraform/projects/<project>/project.yaml`, read by both root modules and
  by the deploy workflow, so adding a project is adding a folder (see
  [Projects are folders](#projects-are-folders-built-by-shared-modules)).

### Provider tokens: periodic orphans from a token role, renewed by apply
Tokens are created by OpenTofu, not a script: with ~16 projects × environments there are too many to
manage by hand.

- `terraform/openbao` defines a token role `dokploy-provider`: tokens are orphans (they outlive the CI
  login that created them), periodic (768 h), renewable, without the `default` policy, and can only get
  policies matching `dokploy-project-*`. The role is what stops a provider token ever holding a broader
  policy.
- Each project-environment gets a `vault_token` from that role with `renew_min_lease` of 14 days, so any
  apply within 14 days of expiry renews it. The token string doesn't change on renewal, so Dokploy needs
  no update. _(prototype)_
- We use the deprecated `vault_token` resource rather than an ephemeral token: an ephemeral token would
  be new on every apply, and every provider in Dokploy would change each time.
- A weekly scheduled run of `terraform/openbao` keeps every token renewed even when nothing changes.
  Unrenewed, a token expires 32 days after its last renewal. Running containers keep working, but every
  deploy that references the provider fails until the next apply.
- `terraform/dokploy` reads the tokens from `terraform/openbao`'s state (`terraform_remote_state`) and
  passes them to `dokploy_vault_provider` as `token_wo`. Tokens are in both states, which are encrypted.

### Apps run images built by their own repos, deployed by this one
_Decided 2026-09-30._ An app's own repo tests it, builds its image and pushes it to GHCR. This repo is
the only deploy authority: it records which image each app runs, in git, and OpenTofu applies it.

**How a deploy works**

1. The app repo's CI, on `main`: test, build, push `ghcr.io/kthaisociety/<project>:<sha>`.
2. Its last step triggers this repo's `deploy.yml` (`workflow_dispatch`) with `project`, `environment`
   and `tag`.
3. `deploy.yml` checks the request: the project and environment exist in its `project.yaml`, and the tag
   exists in that project's GHCR package. It can't check which repo sent the request: every app repo
   uses the same App, so the caller's identity isn't in the dispatch.
4. It commits the new tag to the project's own file (`terraform/projects/<project>/image.yaml`, next to
   its `project.yaml`, one per project so tag commits never conflict) on `main`, then runs the `terraform/dokploy` apply in the
   same run, in the same concurrency group as `tofu.yml`. `terraform/dokploy` reads each project's
   `image.yaml` next to its `project.yaml` (`environment: tag`), and `modules/app` sets each
   environment's image to `ghcr.io/kthaisociety/<project>:<tag>`; a project without one stays on its
   GitHub App source.
5. The image change redeploys the app (`deploy_on_change`). A failed deploy fails the apply, so the
   workflow run is the deploy's result, and the app repo sees it through the dispatch.

**Why**
- **One deploy authority.** Only this repo's CI holds Dokploy credentials. No app repo can change
  anything in Dokploy, and there's no per-app credential to issue, rotate or revoke. The provider
  couldn't create per-app Dokploy keys anyway.
- **Git is the record of what runs.** Rollback is reverting the tag commit. A disaster-recovery rebuild
  (below) brings every app back on the version it ran, not on whatever the module was created with.
- **OpenTofu owns the image like everything else.** No `ignore_changes`, and no drift between what git
  says and what runs.
- **Builds leave the VPS.** Dokploy's GitHub App flow builds on the same host that runs every app,
  OpenBao and the databases. Building in GitHub Actions also gives each app a place for tests and an
  image scan before anything reaches the server.

**The one credential app repos hold:** an org-owned GitHub App, installed only on this repo, with
`actions: write` and nothing else. App repos get its ID and private key as org secrets, available to the
repos named in the `project.yaml` files. With it they can start this repo's workflows; they can't push code, read
secrets or reach Dokploy. The worst a leaked key, or any app repo, can do is deploy a tag that already
exists in some project's GHCR package: roll a project back or forward to an image its own repo built.
Each GHCR package grants write access only to its app's repo, so no one can get an arbitrary image
deployed this way; keep it that way when creating packages.
`actions: write` also lets the holder cancel and re-run this repo's workflow runs, which only ever
apply `main`. It's one credential for the whole org, kept in 1Password with everything else.

**Costs we accept**
- A bot commit on `main` per deploy. The deploy App (or this repo's own bot) needs a bypass on `main`'s
  branch protection for the tag files only. A push from `GITHUB_TOKEN` doesn't trigger workflows, which
  is why `deploy.yml` applies in the same run instead of relying on the push.
- Deploys queue behind other applies (one concurrency group), and each one plans the whole
  `terraform/dokploy` root module. With ~16 projects that's expected to take a minute or two. If it gets
  slow, split projects into their own root modules (see below).
- A broken `main` blocks deploys. That's the right coupling: `main` is always what's applied.
- GHCR pull credentials sit in state: an application's `docker.password` has no write-only companion.
  It's one read-only GHCR token (`read:packages`), shared by all apps, and state is encrypted. Check
  first whether Dokploy's host-level `docker login` from the GHCR `dokploy_registry` already lets apps
  pull without per-app credentials (see [Verify before building](#verify-before-building)).

**Rejected**
- **CI in each app repo calls Dokploy's API** (`application.saveDockerProvider`, `application.deploy`),
  with OpenTofu ignoring the image. The prototype did this. It's faster and keeps git out of the loop,
  but every app repo holds a Dokploy key with power over every app (Dokploy keys have their user's
  permissions), git no longer says what runs, and a rebuild can't restore the right versions.
- **This repo calls Dokploy's API on dispatch** instead of committing the tag. Same single authority, but
  git still doesn't record what runs.
- **Dokploy's GitHub App builds on push.** It's what we have today, and it's how projects are imported at
  first (Phase 7). It stays the fallback for a project that has no CI yet, but it builds on the VPS and
  has no place for tests or scans.

### Projects are folders, built by shared modules
_Decided 2026-10-01._ Adding a project should be adding a folder and merging, with OpenBao and Dokploy
wired up by the same apply.

- **`terraform/projects/<project>/project.yaml`** is the only file a standard project needs. Both roots
  find projects with `fileset(path.module, "../projects/*/project.yaml")`; there's no list to edit.

  ```yaml
  name: onboarding-service
  repo: kthaisociety/onboarding-service
  type: app                      # which shared module builds it
  environments:
    production:
      domain: onboarding.kthais.com
      port: 8080
      env:                       # non-secret, written as-is
        LOG_LEVEL: info
      secrets:                   # names only; values live in OpenBao
        - MATTERMOST_BOT_TOKEN
        - GOOGLE_ADMIN_SERVICE_ACCOUNT_JSON
      shared: [onboarding-service-secret]
  ```

- **Two shared modules, one per root**, because the wiring spans both and they must stay separate
  (`terraform/dokploy` plans on PRs; `terraform/openbao` can't).
  - `modules/app-secrets` (in `terraform/openbao`), per environment: the `dokploy-project-<project>-<env>`
    policy, its token, and an empty `secret/<project>/<env>` entry (metadata only, no data) so the path
    is there in the UI to fill.
  - `modules/app` (in `terraform/dokploy`), per environment: the Dokploy project and environment, the
    vault provider `<project>-<env>` with that token, and the services. Env is the plain `env` values
    plus one generated reference per secret name, so nobody hand-writes
    `${{vault.<provider>.<path>:<KEY>}}`, and no secret value is in git or state.
- **App types.** The default `type: app` is an application plus Postgres and Redis, each optional in
  `project.yaml`. Variants (a static site, a compose stack, a worker) become their own types as they come
  up. A project that fits no type gets its own module in `terraform/dokploy/projects/<project>/` and one
  line in `projects.tf`; it still uses `modules/app-secrets`, so its OpenBao side is the same.
- **UI-managed projects** (only if one has to use OpenBao before it's rebuilt) have `managed: false` and their Dokploy project and environment
  IDs in `project.yaml`. Only `app-secrets` and the vault provider apply to them; the services stay in the
  UI. Not through the `dokploy_project` data source, which would copy shared env vars into state.
- **A new project's first deploy waits for its secrets.** The PR plan can't see the new token (OpenBao
  applies only on `main`), so `modules/app` reads it with `try()`; on `main`, `openbao` applies first. A
  new project starts with `deploy: false` until an admin has filled its path (verify item 11).
- **Domains need DNS and a route.** `domain:` makes a `dokploy_domain` (the Traefik route and its
  certificate). The DNS record is still a PR in `dnscontrol`, the only place DNS is managed. Without the
  record Let's Encrypt can't validate; without the route Traefik answers 404 on its default certificate.

### Existing projects are rebuilt, not imported
_Decided 2026-10-01._ An existing project moves to OpenTofu as a **new** Dokploy project built by
`modules/app`, next to the old one, with its data copied over; it isn't adopted with `import` blocks.
onboarding-service goes first.

- **Why:** the result is exactly what the code says, with no import-time drift to reconcile and no UI
  leftovers (old env vars, mounts, webhooks). The old project stays, stopped, as the rollback until the
  new one has run for a week.
- **Two copies at once is safe for onboarding-service:** it has no background jobs; it only acts when
  landingpage-backend or the frontend calls it, so an idle copy does nothing.
- **The cutover is a URL or a route, not DNS.** Callers that reach a service through an env URL
  (`ONBOARDING_SERVICE_URL` in landingpage-backend and the frontend) switch by changing that URL, so the
  new service is tested on its own hostname or internal name first. A service people reach at a public
  domain is tested on a temporary hostname (DNS record plus `dokploy_domain`), then the domain moves:
  remove it from the old app in the UI, apply it on the new one. Both are on the same host, so DNS
  doesn't change, and Traefik reuses the certificate it already has for that name.
- **Data:** stop the old app, copy its data (a SQLite file, a `pg_dump`), start the new one, switch the
  callers. Minutes of downtime, at a quiet time.
- **Costs:** a short write freeze per project, and anything kept outside env (volumes, file mounts,
  schedules, backups) has to be found and recreated. Import stays the fallback for a project whose data
  can't be copied easily.

### Dokploy's Traefik is kept current by hand
_2026-10-01._ Dokploy doesn't upgrade an existing Traefik container when Dokploy itself is upgraded. Ours
was still 3.1.2 on Docker Engine 29.8.1, which refuses the old API version Traefik before 3.6.1 asks
for, so Traefik's Docker provider had silently stopped: every route came from Dokploy's files, and any
service routed by labels (OpenBao, compose domains) got Traefik's 404. We recreated `dokploy-traefik` by
hand on `traefik:v3.7.13` with the same binds, ports and network (runbook C0). Unverified whether
Dokploy's "Reload Traefik" recreates it on Dokploy's pinned image; don't use it until checked.

### OpenBao's API is public, hardened
_Decided 2026-09-30._ OpenBao's API is routed by Traefik at `bao.kthais.com`, with a Let's Encrypt
certificate. The UI is on from Phase 4, behind Google sign-in (see
[People log in with Google](#people-log-in-with-google-userpass-is-break-glass)).

- **Why:** `terraform/openbao` has to call OpenBao's API (mounts, policies, auth, tokens), and Dokploy's
  API can't do that for it. Its only link to OpenBao is reading secrets through the vault providers. A
  public API lets that job run on GitHub-hosted runners like every other job.
- **Rejected: a self-hosted runner on the VPS**, the previous plan. It needs its own GitHub App, a key
  placed on the host by hand, and a two-pass first build, all for one job. **Also rejected:** Tailscale
  in CI, a new dependency and secret we don't otherwise need.
- **Why it's safe:** OpenBao is built to face the internet over TLS, with every request authenticated.
  CI logs in with GitHub's OIDC token, which only this repo's `production` environment can get, and
  people log in with Google, limited to an allowlist of kthais.com accounts. Host root already exposes
  every secret, so a closed network would protect less than it looks. The hardening below is defense in
  depth, and each piece is tested before an app depends on OpenBao.

Hardening, all in the Traefik labels and OpenBao config in `openbao.tf`:
- **Only the GitHub (CI) and Google (people) login paths are public.** Traefik blocks `/v1/auth/userpass/`
  (the break-glass login, below) and the
  root-recovery endpoints `/v1/sys/generate-root`, `/v1/sys/rekey`, `/v1/sys/rotate/recovery` and
  `/v1/sys/init`. `generate-root` accepts calls with no token; guessing the recovery keys is
  infeasible, but there's no reason to offer it. Blocked means Traefik answers 403 (an `ipAllowList`
  middleware that allows nothing). All of these still work from inside the container.
- **`userpass` tokens only work from inside the container.** Every `userpass` user has
  `token_bound_cidrs = 127.0.0.1/32`, and only `docker exec` reaches OpenBao from `127.0.0.1`; a request
  through Traefik or from Dokploy comes from a `dokploy-network` address. So even a stolen admin
  password or token is useless without shell on the host. The admin policy requires that value on
  every user it creates (`required_parameters` / `allowed_parameters`), so no admin can create a user
  without it, or with any other policy.
- **Rate limiting** on the route (Traefik middleware), and OpenBao's file audit device on from the
  first apply of `terraform/openbao`.
- **CI's JWT role is bound tightly:** to `repo:kthaisociety/infrastructure:environment:production`,
  with a short TTL. Its policy is effectively admin (it writes policies), so the binding is what
  protects it. PRs don't plan `terraform/openbao` (see Phase 4).

### People log in with Google; `userpass` is break-glass
_Decided 2026-10-01, replacing "no personal logins for now" (2026-09-30)._ Editing secrets inside the
container over SSH was too error-prone for day-to-day changes, and the identity service is months away.
OpenBao's OIDC auth method trusts Google directly.

- **Google OAuth client** `openbao` in `clean-healer-452020-n9`, made by hand (GCP isn't in OpenTofu
  yet). Internal consent screen, so only kthais.com Workspace accounts can sign in. Redirect URIs: the UI's
  `https://bao.kthais.com/ui/vault/auth/oidc/oidc/callback` and the CLI's
  `http://localhost:8250/oidc/callback`. Client ID and secret are in 1Password and in the `production`
  environment as `OPENBAO_OIDC_CLIENT_ID` and `OPENBAO_OIDC_CLIENT_SECRET`.
- **Role `infra-admin`** on the `oidc` mount, bound to `hd = kthais.com` (Workspace accounts, whose emails Google
  has verified) and an exact email allowlist (`openbao_admin_emails` in `terraform/openbao`): sam@, vilhelm@,
  pavlos.spanoudakis@ and max.astrand@kthais.com. Tokens last an hour and carry the `infra-admin`
  policy. Adding or removing a person is a PR here.
- **What `infra-admin` can do:** read and write every project's KV paths except `infrastructure/`, and
  manage `userpass` users. Nothing under `sys/`: mounts, policies, auth methods and tokens change only
  through `terraform/openbao` in CI.
- **The trade-off:** a token from a Google login isn't bound to `127.0.0.1`; it works from anywhere for
  its hour. Workspace sign-in (with its 2FA), the allowlist, the short TTL and the policy protect it,
  instead of SSH. Accepted, for a UI people will actually use.
- **`userpass` is the break-glass login**, for when Google or the OAuth client is broken. Users are
  created by hand (Part B made `sam` and `vilhelm`), the login path is blocked at Traefik and tokens are
  bound to `127.0.0.1`, so it only works inside the container. Passwords are in each admin's 1Password
  and never in state.
- **App owners don't log in yet.** They hand secrets to an admin through 1Password. Per-project owners
  can come later (see
  [Later: per-project owners](#later-per-project-owners-and-the-identity-service)).

### Access control, and its limits
OpenBao policies give per-path, per-operation control. Some things can't be prevented on any platform:

| Who | Can read |
|---|---|
| Secret owners, via OpenBao policies | Exactly the paths they're granted |
| Operators of a service, via Dokploy access | That service's secrets (exec into the container) |
| Dokploy admins and anyone with host root | Everything |
| Infra admins, via Google or `userpass` | Every project's secrets (not `infrastructure/`) |
| This repo's CI | Everything in Dokploy and OpenBao |

So: keep Dokploy admins and SSH users to a minimum, give each project's Dokploy access and OpenBao
policy to the same people, and keep non-runtime secrets in paths no Dokploy provider token can read.
This repo's `main` can only be changed by org admins (a ruleset), and its secrets only reach a job
through an environment (below), so write access alone reads nothing.

### OpenTofu runs only in CI, never on a laptop
Every root module is planned on PRs and applied on merge to `main` by GitHub Actions.

- **Secrets:** `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (the `tfstate` credential, read by the S3
  backend), `TF_VAR_state_passphrase`, `GLESYS_USERID` / `GLESYS_TOKEN` (GleSYS API key for
  `terraform/glesys`), and the Dokploy API key. Each is set only on the jobs that need it. GleSYS
  credentials can't be read-only, so plan and apply use the same ones. Plans run with `-lock=false`.
- **Where the secrets live:** in two GitHub environments holding the same values, never at repo level.
  `production` (apply) is limited to `main`, with no admin bypass. `plan` (PR plans) needs approval from
  an infra admin (`sammosios`, `vilhelmprytz`); admins can approve their own runs.
- **Apply** runs only in the `production` environment, limited to `main`.
- **Order on merge:** `glesys` → `openbao` → `dokploy`, as jobs in one workflow, all on GitHub-hosted
  runners. On the very first build the order is different (see [Bootstrap order](#bootstrap-order)).
- **Dokploy auth:** an API key for a dedicated Dokploy `terraform` admin user, generated in the UI with
  rate limiting **off** (a rate-limited key answers `401` mid-apply, not `429`). Dokploy has no read-only
  API keys, so plan needs the same admin key as apply.
- Because plan needs these secrets, approving a PR's plan runs that branch's workflow and Terraform code
  with them. Review the whole diff first, including `external` data sources, `local-exec` and lockfile
  changes. Anyone with write access can open PRs; nobody without an approval reads a secret.

### 1Password holds break-glass material
OpenBao recovery keys and static unseal key, the GleSYS API key and the `tfstate` credential, the
state encryption passphrase, Dokploy admin credentials (including the `terraform` user's password; its API key lives only in GitHub and is rotated by making a new one), each
infra admin's OpenBao password (their own), the deploy App's private key, and the GHCR pull token. With the repo, GleSYS and the
1Password vault, anyone can rebuild everything.

## Bootstrap order

In steady state every merge applies `glesys` → `openbao` → `dokploy`. The first build can't start at
`terraform/openbao`, for two reasons that no tool removes:

- **OpenBao has to be running before `terraform/openbao` can plan.** OpenTofu configures a provider
  before it creates anything, so the `vault` provider in `terraform/openbao` needs a live OpenBao and a
  login at plan time. The same run can't also deploy it. Deploying it is `terraform/dokploy`'s job
  (Phase 2).
- **A new OpenBao has no way in until it's initialized.** Before `bao operator init` there are no auth
  methods, so CI has nothing to log in with, and the `vault` provider has no init resource. Someone has
  to make the first credential: init returns a root token, which creates CI's GitHub login, and is
  revoked (Phase 3).

Both happen once in the life of the data. After a disaster, the new OpenBao is initialized only to get
a throwaway root token for the restore call; the snapshot then brings back the original recovery keys,
CI's login and the admins, and nothing is set up again. Phase 3 is a handful of commands inside the container; its only product is the
recovery keys and CI's login. Self-initialization could declare CI's login in OpenBao's config and
remove Phase 3 (CI's JWT role needs no secret), but it produces no recovery keys, and generating them
afterwards is a manual step inside the container of the same size. See
[OpenBao is initialized by hand, once](#openbao-is-initialized-by-hand-once).

So `terraform/dokploy` is applied in two passes the first time:

1. `glesys` (done in Phase 1).
2. `dokploy` with the OpenBao compose only, **with no public route**. Unseal key placed on the host by
   hand first.
3. By hand, inside the container: `bao operator init`, then with the root token: JWT auth for this
   repo's CI, the first infra admin logins, then revoke the root token.
4. `dokploy` again, turning on the public route, and test its blocks.
5. `openbao`: KV mount, token role, policies, tokens, `infrastructure/production`. (The audit device is
   in OpenBao's server config, step 2.)
6. `dokploy` again, adding the vault providers and the `openbao-snapshots` compose.

**Why no public route until after init:** whoever calls `sys/init` on a fresh OpenBao owns it. Traefik
blocks that path, but the block is only trusted once tested, and it can only be tested once the route
is live. Initialized first, `sys/init` does nothing, so a flaw in the block costs nothing.

Exact commands for all of it: [openbao-deploy.md](openbao-deploy.md).

From then on, the normal order holds: nothing in `openbao` depends on something `dokploy` creates later
in the same run.

## Repo layout

```
infrastructure/                       # github.com/kthaisociety/infrastructure (public)
  terraform/
    projects/<project>/project.yaml  # one folder per project; read by openbao/, dokploy/ and deploy.yml  [todo]
    glesys/       # object storage instances, credentials                            — CI                [written]
    dokploy/      # one root module for everything on Dokploy                         — CI                [todo]
      core.tf     #   GHCR registry, GitHub App lookup, backup destination, notifications
      openbao.tf  #   OpenBao compose (config and Traefik route inline) and the openbao-snapshots compose
      projects.tf #   modules/app for every project.yaml (vault provider, services); custom modules by name
      projects/<project>/  # only for projects that fit no app type
    openbao/      # KV v2, JWT auth for CI, Google OIDC and userpass for people, token role, policies — CI [todo]
    modules/
      app-secrets/ # OpenBao side of a project: policy, token, empty KV path                      [todo]
      app/        # Dokploy side of a project, one per app type (default: app + Postgres + Redis) [todo]
    gcp/          # GCP projects, OAuth clients, etc.                                               [later]
  docs/
    openbao-deploy.md  # exact steps from no OpenBao to two apps using it (Phases 2–5)           [written]
    runbook.md    # disaster recovery, token rotation, adding a secret path, adding a project     [todo]
  .github/workflows/
    tofu.yml      # plan on PR, apply on main: glesys → openbao → dokploy; weekly openbao run    [glesys only]
    deploy.yml    # workflow_dispatch from app repos: validate, commit tag, apply dokploy         [todo]
    build.yml     # reusable workflow for app repos: test, build, push to GHCR, dispatch deploy   [todo]
```

`dokploy-core/` from the previous plan is gone: OpenBao's compose and config live in `openbao.tf`.

### Why one Dokploy root module
Core resources (registry, vault providers, GitHub App, backup destination) are passed straight into each
project module as inputs, with no remote-state lookups. Each project module is self-contained, so it's
clear exactly what a project runs. With ~16 apps, one state and one plan are manageable. If plans (and so
deploys) get slow or the blast radius gets uncomfortable, split projects into their own root modules
later; `deploy.yml` then applies only the affected project's module.

Projects use the shared modules from the start (see
[Projects are folders](#projects-are-folders-built-by-shared-modules)); a project that fits no app type
gets its own module under `dokploy/projects/<project>/`.

## Phases

### Phase 1 — GleSYS and GitHub
1. _(Done)_ In the GleSYS UI: create the `tfstate` instance, a credential on it, and the `kthais-tfstate`
   bucket. Create a GleSYS API key. Store both in 1Password.
2. _(Done)_ Generate the state passphrase and store it in 1Password.
3. _(Done 2026-10-01)_ GitHub settings: repo public (free rulesets); a `main` ruleset (restrict updates
   to org admins, signed commits, linear history, no force-push or deletion); the `production` and
   `plan` environments above, each with the secrets; non-admins on triage; workflow token read-only;
   approval for all outside contributors' runs.
4. _(Written 2026-09-30)_ `terraform/glesys`: imports the four existing instances, and creates the
   `openbao-snapshots` instance and the snapshot job's credential. `tofu.yml` plans it on PRs and applies
   it on merge.
5. _(Done 2026-09-30)_ Tested GleSYS: versioning works, conditional writes don't.

### Phase 2 — OpenBao on Dokploy
_Done 2026-10-01._ Exact steps: [openbao-deploy.md](openbao-deploy.md), Parts A and C.

1. Keep Dokploy at or above the provider's target (we run v0.30.8; provider 1.8.0 targets v0.30.8).
2. Create the Dokploy `terraform` admin user and its API key (rate limiting off), into 1Password and
   GitHub.
3. `bao.kthais.com` in the `dnscontrol` repo (`HOST_SYNAPSE("bao")`).
4. Generate the unseal key on the host, and store it in 1Password.
5. `terraform/dokploy` with only the backend, the provider and `openbao.tf` (the infrastructure project
   and the OpenBao compose, with its config, Traefik route and blocked paths inline), and its job in
   `tofu.yml`. It starts off `dokploy-network` and with no route (`openbao_initialized` and `openbao_public` false), so nothing can call `sys/init` before we do. Core resources wait for Phase 6.
   Merge; CI applies.
6. After Phase 3: turn the route on, and check the certificate, the redirect and every blocked path,
   including path-encoding tricks (verify item 9).

### Phase 3 — Initialize OpenBao, by hand
_Done 2026-10-01._ Exact steps: [openbao-deploy.md](openbao-deploy.md), Part B. Inside the container, before the route is
public:

1. `bao operator init`. Recovery keys go to 1Password, split among key holders.
2. With the root token: JWT auth for GitHub Actions, the `infrastructure-ci` role bound to this repo's
   `production` environment, and the `terraform` policy it uses.
3. `userpass` and the first infra admins.
4. Revoke the root token. Verify auto-unseal by restarting the container.

### Phase 4 — Configure OpenBao as code
Exact steps: [openbao-deploy.md](openbao-deploy.md), Part D.

1. Write `terraform/openbao/`: KV v2 at `secret` (the file audit device is in the server config), the `dokploy-provider` token
   role, the `infra-admin` policy, Google OIDC with the `infra-admin` role, and `modules/app-secrets`
   for every `project.yaml`. Plus `infrastructure/production`: the GleSYS snapshot credential and the
   snapshot token. Import what Phase 3 made (the JWT mount, config and role, the `terraform` policy, the
   `userpass` mount).
2. Add the `openbao` job to `tofu.yml` (GitHub-hosted, logs in with the JWT role), and the weekly
   schedule. There's no `terraform/openbao` plan on PRs: CI's OpenBao login is bound to `production`,
   which only runs on `main`, and a read-only PR login would still read every secret while refreshing
   state. PRs get `fmt` and `validate`; the apply run prints its plan first. Merge; CI applies.
   The same PR turns the UI on (`ui = true` in `terraform/dokploy`), so the login page never appears
   before the Google login exists.
3. Check Google sign-in in the UI, that an account outside the allowlist is refused, that a `userpass`
   login works inside the container, and that its token is refused through `bao.kthais.com`.

### Phase 5 — Connect Dokploy to OpenBao, and the first apps
Exact steps: [openbao-deploy.md](openbao-deploy.md), Part E.

The first apps use OpenBao while they're still managed in the Dokploy UI. Their vault providers are
OpenTofu resources, assigned to the existing projects by the Dokploy project and environment IDs
written in their `project.yaml` (`managed: false`). Not through the `dokploy_project` or `dokploy_environment` data sources:
those copy each project's shared env vars, which are secrets today, into state. The apps themselves aren't touched by OpenTofu until Phase 7. That's consistent with "OpenTofu owns a
service completely, or not at all": a provider is its own resource, not part of the service.

1. Add the vault providers to `terraform/dokploy`: a `dokploy_vault_provider` per project-environment
   from the `project.yaml` files, tokens from `terraform/openbao`'s state as `token_wo`, `verify_connection = true`.
2. Add the `openbao-snapshots` compose to `openbao.tf`, its env only references. Apply.
3. Verify a snapshot arrives in GleSYS, and restore it on a throwaway OpenBao with the same unseal key.
4. First apps: **onboarding-service** and **landingpage-backend**. They share
   `ONBOARDING_SERVICE_SECRET`, so they also prove the `shared/` path. An infra admin writes their
   secrets in the OpenBao UI, then replaces the values in each app's env in the Dokploy UI with references,
   and redeploys. Keep the old values in 1Password until both apps have run on references for a week.
5. Answer verify items 1 and 2 (per-environment assignments, token renewal).

**Milestone reached here:** OpenBao defined in this repo, running, backed up, and serving two apps.

### Phase 6 — Dokploy core in OpenTofu
1. Add `core.tf` to `terraform/dokploy`: GHCR `dokploy_registry` (`password_wo`), the
   `dokploy_github_provider` data source for the existing GitHub App, the GleSYS backup
   `dokploy_destination` for `website-psql-backups`, and notifications. Import what already exists
   instead of recreating it.
2. Apply, and confirm the next plan is empty.

### Phase 7 — Projects into OpenTofu, one at a time
Projects are rebuilt next to the running ones and their data copied over (see
[Existing projects are rebuilt](#existing-projects-are-rebuilt-not-imported)), still on Dokploy's
GitHub App source. Moving to CI-built images is Phase 8.

The first project is **onboarding-service**: one Go app built from its Dockerfile, SQLite on a volume,
no database service. It skips Phase 5's UI step: its new project gets references from the start. Its
module is a `dokploy_project`, a `dokploy_application` from the GitHub App, a `dokploy_mount` volume on
`/data`, and a `dokploy_volume_backup` of `/data`; no public domain, since its callers reach it through
`ONBOARDING_SERVICE_URL`. The Google service account JSON moves from a file
mount to an env reference (base64 in `GOOGLE_ADMIN_SERVICE_ACCOUNT_JSON`), because a file mount's
content would end up in state.

For each project:
1. Add its folder with `deploy: false` and merge: `terraform/openbao` makes its policy, token and empty
   path; `terraform/dokploy` makes the new project, its vault provider and the services, not deployed.
   A project that fits no type gets a module in `terraform/dokploy/projects/<project>/`.
2. An infra admin writes its secrets to `<project>/<environment>` in the UI.
3. Set `deploy: true` and merge. Test the new copy on its own hostname or internal name.
4. Cut over: stop the old app, copy its data, start the new one, point callers (or the domain) at it.
5. Tell the project's maintainers that config changes now go through PRs here.

### Phase 8 — Deploys through this repo
1. Create the deploy GitHub App (org-owned, installed on this repo only, `actions: write`). Its ID and
   private key become org secrets, available to the repos named in the `project.yaml` files.
2. Write `build.yml` (reusable, called by app repos: test, build, push to GHCR, dispatch) and
   `deploy.yml` (validate, commit the tag, apply `terraform/dokploy`). Tags live in one file per
   project, so tag commits never conflict.
3. First project: onboarding-service. Its repo calls `build.yml`; once an image is in GHCR, switch its
   module from the `github` source to `docker` with that tag, turn off `auto_deploy`, and apply.
4. Then the rest, one project per PR. A project without CI stays on the GitHub App source until it has
   some.

Add app types to `terraform/modules/app` as projects need them. Write
`docs/runbook.md` along the way: disaster recovery, token rotation, adding a secret path, adding a
project, adding an infra admin, rolling back a deploy.

## Verify before building

Things we believe but haven't tested. Each is checked in the phase that first depends on it; if one
fails, the decision it supports is revisited before building on it.

| # | Question | Phase | If it fails |
|---|---|---|---|
| 1 | Dokploy assignments work per environment, not just per project (the prototype only tested projects) | 5 | One provider per project; staging and production share a token scope |
| 2 | A renewed provider token keeps working without updating Dokploy | 5 | Push the token to Dokploy on every renewal (`token_wo_version` bump) |
| 3 | A vault provider can be assigned to a UI-managed project without OpenTofu touching the project | 5 | Import the first two projects into OpenTofu (Phase 7) before switching them to references |
| 4 | A GHCR image pulls with no per-app credentials after the GHCR `dokploy_registry`'s host login | 8 | Per-app `docker.username` / `docker.password` from one variable (in encrypted state) |
| 5 | A `dokploy_application` can switch from the `github` source to `docker` in place, without replacement | 8 | Recreate the application in a maintenance window; domains and mounts are re-attached by the same apply |
| 6 | A full `terraform/dokploy` plan with every project stays around two minutes | 8 | Split projects into their own root modules |
| 7 | GleSYS supports versioning on the `openbao-snapshots` instance's bucket | 5 | Accept that the snapshot credential can delete snapshots; keep a second copy elsewhere |
| 8 | `docker exec` requests reach OpenBao from `127.0.0.1`, and requests through Traefik don't | 4 | Bind admin tokens to the container's own address instead |
| 9 | Traefik's path blocks can't be bypassed by path encoding or double slashes (`/v1//sys/...`, `%2F`) | 2 | Allowlist paths instead of blocking them |
| 10 | Writing only KV v2 metadata makes an empty path that shows in the UI | 4 | The path appears on the admin's first write instead |
| 11 | Dokploy fails a deploy whose reference names a missing key, rather than deploying an empty value | 5 | `deploy: false` becomes mandatory until the path is filled |

Results so far:
- **9, checked 2026-10-01:** double slashes, dot segments, `%69`-style escapes, trailing slashes and
  query strings all get Traefik's 403. `%2F` (e.g. `/v1/sys%2Finit`) and uppercase (`/v1/SYS/init`) pass
  Traefik and reach OpenBao, but no real handler: OpenBao doesn't decode `%2F` into a path separator
  (`/v1/sys%2Fhealth` is a 405 too) and its paths are case-sensitive. Acceptable; tighten later by
  rejecting encoded slashes at Traefik.

## Later: per-project owners, and the identity service

People already log in with Google (see
[People log in with Google](#people-log-in-with-google-userpass-is-break-glass)), but only as infra
admins.

- **Per-project owners** don't need the identity service: an `owners:` list of emails in a project's
  `project.yaml` becomes an OIDC role scoped to that project's KV paths, made by
  `modules/app-secrets`. Every access change stays a reviewed PR here.
- **The [identity service](identity-service.md)**, once it exists and verifies Google sign-ins correctly
  (its Step 1), can replace Google as OpenBao's OIDC issuer, with the same roles. Decide then whether
  groups come from its tokens or stay as emails in `project.yaml`.
- **People never get `sys/`.** Mounts, policies and auth stay with CI, which logs in with GitHub's OIDC
  and depends on neither Google nor the identity service.
- **`userpass` stays** as the break-glass login inside the container.

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
3. Place the OpenBao unseal key from 1Password on the host. Apply `terraform/dokploy` targeting core
   and OpenBao only, **with `-var openbao_initialized=false -var openbao_public=false`**: the defaults in
   git are `true`, and an empty OpenBao on `dokploy-network` can be initialized by any container there.
   Check it's on its own `_default` network only (runbook A6) before going on.
4. Inside the container: `bao operator init` the empty OpenBao only to get a throwaway root token, then
   `bao operator raft snapshot restore -force` the latest snapshot from GleSYS. The restored data
   replaces the throwaway init: it auto-unseals with the same static key, and every secret, policy,
   token, admin login and the original recovery keys are back. The throwaway root token went with the
   replaced data: check `bao token lookup` with it now fails.
5. Apply `terraform/openbao`, then `terraform/dokploy` in full. The vault providers, the snapshot job and
   every OpenTofu-managed project are recreated and deployed, each on the image tag recorded in this
   repo. UI-managed projects are still recreated by hand.
6. Restore application data (databases, volumes) from GleSYS backups. Every project module should
   define a backup to the GleSYS destination, so this is covered for migrated projects.
