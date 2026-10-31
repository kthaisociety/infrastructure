# App delivery: from a push to running on Dokploy

_Updated 2026-10-29. The design and its reasons are in [delivery-plan.md](delivery-plan.md); this is the
guide to using it. Each part says whether it's **built** or **not yet**: treat anything "not yet" as
intended, not as fact._

Every app has two environments, `staging` and `production`. When the pipeline is complete, merging to
`main` deploys to staging and merging the release PR deploys to production; nothing else deploys.

```
feature PR ──merge──▶ build ──▶ sha-<commit> ──deploy.yml──▶ staging
                         └─▶ release PR updated (next version + changelog)
release PR ──merge (code owner)──▶ vX.Y.Z + GitHub Release
                         ├─▶ build ──▶ sha-<release commit> ──deploy.yml──▶ staging
                         └─▶ release: wait for that build ──▶ X.Y.Z = same digest ──deploy.yml──▶ production
```

**Built.** Each half runs once the app opts in with its job: `deploy-staging` in `build.yml`,
`deploy-production` in `release.yml` (section 2.1). Both call `request-deploy.yml`, which asks
`deployments`' `deploy.yml` with the `kthais-dispatch` App and waits for the result. `deploy.yml` checks
the request, commits the one `release.yaml` line itself (as `kthais-deploy`, no PR) and applies, in one run.

## 1. The pieces

| Piece | Where | What it does | Status |
|---|---|---|---|
| App repo | e.g. `kthaisociety/onboarding-service` | code, `CHANGELOG.md`, version (release-please manifest), three workflow files calling `kthaisociety/workflows` | built (onboarding-service) |
| `kthaisociety/workflows` | public, tags `v0.1.0`… | `semantic-pr.yml`, `build.yml`, `release.yml` (reusable). Must stay public: public repos can't call workflows from a private one | built |
| GHCR | `ghcr.io/kthaisociety/<repo>` | the images, public: Dokploy pulls with no credentials. Writable only by its own repo. Check visibility once per new package (2.1) | built |
| `kthaisociety/deployments` | public | per project `project.yaml` (config, secret names) and `release.yaml` (exact image per environment); OpenTofu that builds the Dokploy side | built (deployments#1); `deploy.yml` built (deployments#10) |
| `kthaisociety/infrastructure` | public | the platform, and each project's OpenBao side: one line in `terraform/openbao/projects.yaml` | built |
| OpenBao | `bao.kthais.com` | secret values at `secret/<project>/<env>` and `secret/shared/<env>` | built |
| Dokploy | `synapse.aisociety.se` | runs the images. Never builds, never decides what runs | built |
| Bots | [bot-accounts.md](bot-accounts.md) | `kthais-release`, `kthais-dispatch`, `kthais-deploy` (GitHub Apps), `Deployments CI` (Dokploy user) | created |

## 2. Adding a new app

Moving an **existing** app off the Dokploy UI (inventory, data copy, switchover):
[app-migration.md](app-migration.md), which builds on the steps below.

In order. Each step says what "done" looks like.

### 2.1 The app repo
- **Public** (public by design; the org is on GitHub Free, where rulesets and org secrets don't work
  for private repos). Secrets never go in the repo or the image: config comes from env at runtime.
- **Reads all config from env at runtime.** Watch out for frameworks that bake env into the build
  (Next.js `NEXT_PUBLIC_*`, Vite `VITE_*`): the same image runs in staging and production, so such values
  must either be the same in both, or be read at runtime instead. Check this before adopting.
- **A Dockerfile** (or anything `docker build` can build) listening on one port.
- **`.github/workflows/`**, copied from onboarding-service:
  - `pr.yml`: `title` (calls `semantic-pr.yml@v0.2.0`) and the app's own tests;
  - `build.yml`: on `main`, tests, then `build.yml@v0.2.0` (pushes `sha-<7>`), then `deploy-staging`
    (`request-deploy.yml@v0.2.0`, `environment: staging`, with the `DISPATCH_APP_*` secrets);
  - `release.yml`: on `main`, its own file (it waits for `build.yml`'s run of the release commit, which
    never finishes if both are in one run), calls `release.yml@v0.2.0` with the `RELEASE_APP_*` secrets,
    then `deploy-production` (`request-deploy.yml@v0.2.0`, `environment: production`, the released
    version, only when a release was created).
  - The project in `deployments` defaults to the repo's name, so name the repo after the project.
- **release-please config** at the root: `release-please-config.json` (`release-type`: `go`, `node`,
  `python`, …, or `simple`; `bootstrap-sha`: the commit before adoption, so the first changelog starts
  there) and `.release-please-manifest.json` (`{".": "0.0.0"}`).
- **`.github/CODEOWNERS`**: who approves releases (today `* @sammosios`). Keep it to the people who
  actually review: GitHub requests a review from, and emails, every code owner on every PR, including the
  deploy bot's and release-please's. A team works too, but the whole team gets every request; it needs
  write access.
- **Repo settings:** squash merges only, squash commit title = PR title (so a one-commit PR can't skip
  the title check), delete branches after merge.
- **Ruleset on `main`:** no deletion or force-push, linear history, signed commits, PRs only, squash
  only, all conversations resolved, code-owner review, required checks: `title / PR title is a
  Conventional Commit` and the tests. Greptile isn't required: tag `@greptileai review this PR` on a PR
  that wants a second look.
- **Add the repo to the bots' scope** (nothing is "all repositories", on purpose):
  - `kthais-release`: org → Settings → GitHub Apps → `kthais-release` → Configure → add the repo; then add
    it to the org secrets' repository access:
    ```sh
    gh secret set RELEASE_APP_CLIENT_ID   --org kthaisociety --visibility selected --repos <all app repos> --body 'Iv23li6i9JI6PjjqVXkQ'
    gh secret set RELEASE_APP_PRIVATE_KEY --org kthaisociety --visibility selected --repos <all app repos> < key.pem
    ```
    `--repos` replaces the whole list: name every repo. (Or in the UI: each secret → Repository access.)
  - `kthais-dispatch`: stays installed on `deployments` only; add the repo to `DISPATCH_APP_CLIENT_ID` /
    `DISPATCH_APP_PRIVATE_KEY`'s repository access the same way.
  - `kthais-deploy`: nothing.
- **After the first build, check the package is public** with a pull while logged out:
  ```sh
  docker logout ghcr.io; docker pull ghcr.io/kthaisociety/<repo>:sha-<7>
  ```
  If it's denied: org → Packages → `<repo>` → Package settings → Danger Zone → Change visibility →
  Public. Package visibility is a setting of its own: GitHub's documented default for a new package is
  private, though onboarding-service's came out public (its repo was public when it was first pushed,
  2026-10-02). Check either way; it's once per package.
- **Done when:** a merge to `main` pushes `ghcr.io/kthaisociety/<repo>:sha-<7>`, which pulls logged out,
  and release-please has opened a release PR whose checks ran.

### 2.2 Its OpenBao side, in `infrastructure`
- One line in `terraform/openbao/projects.yaml`: `my-app: {}` (staging and production), or
  `my-app: { environments: [...] }` for others. Add `storage: {}` for object storage (2.7).
- PR, plan, merge. Creates per environment the policy `dokploy-project-<project>-<env>` and the empty path
  `secret/<project>/<env>`. The policy also reads the environment's shared store, `secret/shared/<env>`.
  It also lets `deployments`' CI write `secret/<project>/<env>/database/*`, where it puts the credentials
  of the databases it creates (section 2.6).
- Why here: a policy's contents decide what a token can read, and `deployments`' CI can mint tokens;
  only this repo writes policies. `deployments`' `check` fails with exactly this line until it exists.
- Needed again only for a new environment. Not for new secrets, shared secrets, config or deploys.

### 2.3 Its secrets, in OpenBao
From a laptop (`brew install openbao`, `BAO_ADDR=https://bao.kthais.com`, `bao login -method=oidc
role=infra-admin`), or the UI at `https://bao.kthais.com/ui`:
- Every name in `project.yaml`'s `secrets`, at `secret/<project>/staging` and `secret/<project>/production`;
  shared ones at `secret/shared/<env>`, once for every project. Every project can read the shared store
  of its environment, so put only values there that any app may see.
- `put` for the first key on an empty path, `patch` after (a second `put` replaces the whole secret).
- Not under `secret/<project>/<env>/database/`: `deployments`' CI writes those, and people can only read them.
- Values through stdin, never as arguments; long values from the clipboard (a terminal paste is cut at
  1024 characters). `printf '%s' "$(pbpaste)"` drops only trailing newlines (a copy often adds one) and
  keeps internal ones, so multi-line values such as PEM keys arrive intact:
  ```sh
  printf '%s' "$(pbpaste)" | bao kv put -mount=secret <project>/production KEY=-
  printf '%s' "$(pbpaste)" | bao kv patch -mount=secret <project>/production OTHER=-
  pbcopy < /dev/null
  bao kv get -mount=secret -format=json <project>/production | jq '.data.data | map_values(length)'
  ```
  Never `tr -d '\n'`: it would also remove a multi-line value's internal newlines.
- Before the first write, a path shows "404" in the UI and CLI: it exists as metadata only. Normal.
- **Staging's secrets:** separate from production's, never copies. Either real staging credentials, or
  **inert** ones when the app can act on real accounts (onboarding-service: a service-account JSON with no
  real key, a dummy Mattermost token, its own shared secret; see
  [onboarding-service-migration.md](onboarding-service-migration.md)).

### 2.4 Its Dokploy side, in `deployments`
- `projects/<project>/project.yaml` (format in 6.2) and `projects/<project>/release.yaml` with a line per
  environment, `null` for now. Both required: a missing file or line fails `check`.
- PR (a reviewer approves the `plan` run), merge. Creates the Dokploy project `<project>` with `staging`
  and `production`, and per environment a provider token, a vault provider `<project>-<env>` (connection
  tested), and the app with its volumes, **not deployed** (a placeholder image, deploys off). The app
  exists before its first deploy so its volumes are attached by then: a mount can only be added to an app
  that exists.

### 2.5 Domains (if public)
- `domains:` per environment in `project.yaml`, each host with its container `port` (deployments#14).
  `modules/project` makes the Dokploy domain: Traefik route and Let's Encrypt certificate.
- **DNS stays a manual `dnscontrol` PR** per host, pointing at the Dokploy host, merged first. Without the
  record Let's Encrypt can't validate; without the route Traefik answers 404 on its default certificate.
  New projects use `<name>` and `<name>-staging` on kthais.com.

### 2.6 Databases **[deployments#19, in review]**
- `databases:` under `defaults` in `project.yaml` (`postgres: {}`, `redis: {}`): each environment gets its
  own. The pipeline generates the credentials and writes them to `secret/<project>/<env>/database/<engine>`.
- The app gets a setting only by listing its name in `secrets` (`DATABASE_URL`, `PGHOST`, `REDIS_URL`, …).
  The list per engine is in `deployments`' `docs/project-yaml.md`. Nobody writes these values by hand.

### 2.7 Object storage
- `storage` on the project's line in `terraform/openbao/projects.yaml`. PR, plan, merge.
  - `my-app: { storage: {} }`: one bucket per environment, `kthais-<project>-<env>`.
  - `my-app: { storage: { buckets: [uploads, user-files] } }`: several,
    `kthais-<project>-<env>-uploads` and so on. Names are lowercase letters, digits and single hyphens.
    One bucket per kind of data that needs its own settings (later: public read, Object Lock), or for an
    app that expects a bucket to itself; inside one environment they're not a security boundary.
- Creates, per environment, its own GleSYS instance `<project>-<env>` with a credential for the app, and
  the buckets in it (`terraform/glesys/storage.tf`; OpenTofu creates them with a credential of its own
  in the instance). One instance per environment because a credential reaches every bucket of its
  instance: staging's key can't touch production's files. Bucket names are global across all of GleSYS,
  hence the prefix.
- `terraform/openbao` writes the credential, endpoint, region and bucket names to
  `secret/<project>/<env>/storage`. People can only read it.
- The app lists the names it reads in `project.yaml`'s `secrets` (`deployments`' guide), and passes them
  to its S3 client: `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_ENDPOINT`, `S3_REGION`, and
  `S3_BUCKET` for the single bucket, or `S3_BUCKET_<NAME>` per bucket of the list (`user-files` gives
  `S3_BUCKET_USER_FILES`). Merge this first: until the storage exists, a deploy that lists them fails
  resolving them.
- **Adding a bucket** to the list is just that.
- **Removing a bucket, or storage**, can't be done by deleting the line. The instance, the buckets and
  the OpenBao secret are `prevent_destroy`, so the plan fails. `tofu destroy -target` is refused too, and
  a `removed` block can't take one key of a `for_each`, only every project's buckets at once. So OpenTofu
  forgets them, and they're deleted by hand. A platform admin, per environment:
  1. In `deployments`, stop the app listing the names, or its next deploy fails resolving them.
  2. Copy the files if they're needed, and empty the bucket.
  3. In `terraform/glesys`, forget the bucket:
     `tofu state rm 'minio_s3_bucket.storage["kthais-<project>-<env>-<bucket>"]'`. For the whole storage,
     every bucket, then `'glesys_objectstorage_instance.storage["<project>/<env>"]'`, and in
     `terraform/openbao`, `'vault_kv_secret_v2.storage["<project>/<env>"]'`.
  4. Merge the PR removing the bucket or `storage` from `projects.yaml` straight away: until it's merged,
     any apply would try to create them again. Removing a bucket only updates the storage secret; removing
     storage makes OpenTofu delete the instance's two credentials itself.
  5. Delete what's left by hand, with a temporary credential from the GleSYS UI: the bucket, and for the
     whole storage the instance and the OpenBao secret.
- **Renaming a bucket** isn't possible: S3 has no rename, and the name is also the variable's. Add the new
  name next to the old one, copy the files across (one key reaches both), switch the app to the new
  `S3_BUCKET_<NAME>`, in its code too, then remove the old bucket as above. Going from `{}` to a list is
  the same: the single bucket can't become a named one.
- **Rotating a credential** isn't built yet: it takes replacing
  `glesys_objectstorage_credential.storage["<project>/<env>"]`, after which the next apply writes the new
  one to OpenBao and the app needs a redeploy (tested on GleSYS 2026-10-30: the old key stops working,
  the bucket is untouched). Ask Platform.

### 2.8 First deploy, to staging
- The next build of `main` deploys it (or re-run the last `build` run). `deploy.yml` writes `release.yaml`'s
  `staging:` line, and the app switches from the placeholder to the image, volumes already attached.
  By hand instead: Actions → deploy → Run workflow in `deployments`.
- **Done when:** the deploy succeeds (every `${{vault…}}` reference resolved; a missing key fails the
  deploy), the app logs look right, and it answers on `http://<app name>:<port>` from `dokploy-network`.

### 2.9 First release, to production
- release-please only opens a release PR after a `feat:` or `fix:`, or a commit with a `Release-As:`
  footer. For a chosen first version, squash-merge any PR with this in the commit message:
  ```
  Release-As: 1.0.0
  ```
- A code owner merges the release PR: tag `v1.0.0`, GitHub Release, the release commit's image tagged
  `1.0.0` (same digest, no rebuild), and `deploy-production` deploys it.

## 3. Day to day

### 3.1 A change, to staging
- PR in the app repo (title, tests, code-owner review) → squash merge → `build` pushes `sha-<7>` → `deploy-staging`
  asks `deploy.yml`, which checks the digest, commits the `staging:` line, applies, and reports back. The
  build is green only once staging runs the image.

### 3.2 A release, to production
- Review the release PR (version, `CHANGELOG.md`), a code owner merges it → tag, GitHub Release →
  `release` waits for the release commit's build → tags `X.Y.Z` on that digest.
- Then `deploy-production` asks `deploy.yml`, which also checks that the GitHub Release exists and the
  digest is the release commit's, and deploys production.
- **Keeping a change out of production:** revert it on `main` before merging the release PR, or ship it
  behind an `env` flag that's off in production. Production only moves when a release PR merges.
- **Rollback:** run `deploy.yml` by hand with the previous version.

### 3.3 Config and secrets
- Non-secret env, volumes, new secret names: a PR to `project.yaml`. Merging redeploys.
- Secret values: change in OpenBao, then redeploy; a running app keeps the values it started with. Redeploy
  without a change: the app's **Deploy** button in Dokploy (it doesn't change config, so OpenTofu won't undo it).
- Never edit an app's settings in the Dokploy UI: the next apply overwrites them.

## 4. Rolling back
- Revert the `release.yaml` commit in `deployments` (or set the previous image): merging redeploys it.
- An environment that has had an image can't go back to `null` (`check` rejects it: the app would point
  at the never-deployed placeholder). To take an app down, stop it in Dokploy; to remove it, remove the
  environment from `project.yaml`.
- Never move a version tag, never edit the image in the Dokploy UI.
- Only `main`'s current tip is ever applied: re-running an old apply run does nothing.

## 5. When something fails

| Symptom | Look at | Likely cause → fix |
|---|---|---|
| PR blocked, `title` red | the PR's checks | title isn't a Conventional Commit → edit the title |
| PR can't merge, all green | the PR | unresolved conversations, or (where required) no code-owner approval |
| `build` red | its run | tests, or the image push |
| No release PR, or release PR without checks | `release` run | no `feat:`/`fix:`/`Release-As:` yet; or `kthais-release` not installed on the repo / secrets not visible to it |
| `release` red at "Wait for the release commit's build" | that run | the release commit's `build` failed or took over 45 min → fix, re-run |
| `deployments` `check` red: "isn't in … projects.yaml" | the check | add the printed line in `infrastructure` (2.2) |
| `deployments` `check` red: image format | the check | `release.yaml` needs `<image>:<tag>@sha256:<digest>` |
| `deployments` `check` red: "can't go back to null" | the check | roll back by setting a previous image, not `null` |
| `deployments` `plan` waiting | the run | needs a reviewer to approve the `plan` environment |
| Apply: `verify_connection` / vault provider error | `apply` run | Dokploy can't reach OpenBao or the token is wrong; check OpenBao is up and the provider token |
| Apply: 403 from OpenBao | `apply` run | `deployments-ci`'s policy lacks a path, or the project isn't in `projects.yaml` (no policy) |
| Deploy fails resolving a reference | Dokploy deploy log | the key isn't in OpenBao at that path → write it, redeploy |
| Deploy fails pulling the image | Dokploy deploy log | wrong digest, or the package isn't public: check the package's own visibility (2.1), not only the repo's |
| Apps stop resolving secrets weeks later | Dokploy deploy log | provider token expired (32 days without an apply): `kthaisociety/deployments` → Actions → **tofu** → Run workflow on `main`. Its apply renews every app's token; for one that had already expired it should mint a new one and push it to Dokploy (expected `vault_token` behaviour, not yet observed: if the apply fails on it instead, say so in the run and escalate to an infra admin). Verify: Dokploy → Settings → Secrets → the provider's Test connection, then redeploy the app. The `infrastructure-production` provider's token is renewed by `kthaisociety/infrastructure`'s **tofu** workflow instead. If the workflow itself fails, fix that first: there's no laptop apply. |
| Warnings "Deprecated Resource vault_token" in plans | — | expected: we keep `vault_token` on purpose (a stable token per provider) |

## 6. Reference

### 6.1 Names
- Projects: lowercase letters, digits, single hyphens; not `infrastructure` or `shared`. Environments:
  lowercase letters and digits only (names join as `<project>-<env>`, split at the last hyphen).
- OpenBao: policy `dokploy-project-<project>-<env>`, path `secret/<project>/<env>`, shared
  `secret/shared/<env>`, database credentials `secret/<project>/<env>/database/<engine>` (written by
  `deployments`' CI), object storage `secret/<project>/<env>/storage` (written by this repo).
- GleSYS, for a project with storage: instance `<project>-<env>`, bucket `kthais-<project>-<env>`, or
  `kthais-<project>-<env>-<bucket>` for each in its list.
- Dokploy: project `<project>`, vault provider `<project>-<env>`, app internal name
  `<project>-<env>-<6 random>` (Dokploy picks the suffix; the apply output `projects` shows it), volume
  `<project>-<env>-<name>`.
- Images: `sha-<7>` (every build of `main`), `X.Y.Z` (releases, never moved); always pinned by digest.
- Secret references (generated, never hand-written): `${{vault.<project>-<env>.<project>/<env>:KEY}}`,
  shared `${{vault.<project>-<env>.shared/<env>:KEY}}`.

### 6.2 `project.yaml` (in `deployments`)
The reference is `deployments`' [project.yaml guide](https://github.com/kthaisociety/deployments/blob/main/docs/project-yaml.md),
with a [template](https://github.com/kthaisociety/deployments/blob/main/docs/project.template.yaml) to
start from. Its `check` rejects anything the guide doesn't allow. The shape:

```yaml
repo: kthaisociety/my-app            # GitHub repo; the image is ghcr.io/<repo> unless `image:` says otherwise
defaults:                            # the same in every environment
  env:       { KEY: "value" }        # not secret, written as-is; an environment can change a value
  secrets:   [SECRET_NAME]           # names only; values in OpenBao at secret/<project>/<env>
  shared:    [KEY]                   # names only; values in OpenBao at secret/shared/<env>
  databases: { postgres: {} }        # each environment gets its own (2.6); list its names in secrets
  volumes:   { /data: data }         # optional, avoid: keep apps stateless
environments:
  staging:                           # takes only env and domains; {} when nothing differs
    domains:
      my-app-staging.kthais.com: { port: 8000 }
  production:
    domains:
      my-app.kthais.com: { port: 8000 }
```

Object storage isn't in `project.yaml`: `storage` in this repo's `projects.yaml` (2.7), then its names in
`secrets`. Not supported yet: build arguments.

### 6.3 `release.yaml` (in `deployments`)
```yaml
staging: ghcr.io/kthaisociety/my-app:sha-3b6e8e5@sha256:<64 hex>
production: null                     # null: not deployed yet (the app exists, with a placeholder image)
```

### 6.4 Workflows
| Repo | Workflow | Runs on | Permissions |
|---|---|---|---|
| app | `pr.yml` | PRs | `pull-requests: read` (title), `contents: read` (tests) |
| app | `build.yml` | push to `main` | `contents: read`, `packages: write` |
| app | `release.yml` | push to `main` | `contents: read`, `packages: write`, `actions: read`; `kthais-release` token |
| `deployments` | `tofu.yml` | PRs (`check`; `plan` after approval), `main`, weekly, by hand (`apply`) | `id-token: write` for OpenBao; `plan`/`production` environment secrets |
| `deployments` | `deploy.yml` | dispatch from app repos (`kthais-dispatch`), or by hand | `contents: read`, `id-token: write` for OpenBao; `production` environment secrets; `kthais-deploy` token to commit `release.yaml` |
| `infrastructure` | `tofu.yml` | PRs, `main`, weekly | as above |

OpenTofu 1.12.6 in both repos (1.13.1 is out; upgrade both together).
