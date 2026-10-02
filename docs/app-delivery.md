# App delivery: from a push to running on Dokploy

_Updated 2026-10-02. The design and its reasons are in [delivery-plan.md](delivery-plan.md); this is the
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

**Today (step 12 not built):** the build and release halves run; `deploy.yml` doesn't exist yet, so a
deploy is a one-line PR to the project's `release.yaml` in `deployments` (section 3.1).

## 1. The pieces

| Piece | Where | What it does | Status |
|---|---|---|---|
| App repo | e.g. `kthaisociety/onboarding-service` | code, `CHANGELOG.md`, version (release-please manifest), three workflow files calling `kthaisociety/workflows` | built (onboarding-service) |
| `kthaisociety/workflows` | public, tags `v0.1.0`… | `semantic-pr.yml`, `build.yml`, `release.yml` (reusable). Must stay public: public repos can't call workflows from a private one | built |
| GHCR | `ghcr.io/kthaisociety/<repo>` | the images. A package linked to a public repo is public: Dokploy pulls with no credentials. Writable only by its own repo | built |
| `kthaisociety/deployments` | public | per project `project.yaml` (config, secret names) and `release.yaml` (exact image per environment); OpenTofu that builds the Dokploy side | built (deployments#1); `deploy.yml` not yet |
| `kthaisociety/infrastructure` | public | the platform, and each project's OpenBao side: one line in `terraform/openbao/projects.yaml` | built |
| OpenBao | `bao.kthais.com` | secret values at `secret/<project>/<env>` and `secret/shared/<name>/<env>` | built |
| Dokploy | `synapse.aisociety.se` | runs the images. Never builds, never decides what runs | built |
| Bots | [bot-accounts.md](bot-accounts.md) | `kthais-release`, `kthais-dispatch`, `kthais-deploy` (GitHub Apps), `Deployments CI` (Dokploy user) | created |

## 2. Adding a new app

In order. Each step says what "done" looks like.

### 2.1 The app repo
- **Public** (public by design; the org is on GitHub Free, where rulesets and org secrets don't work
  for private repos). Secrets never go in the repo or the image: config comes from env at runtime.
- **Reads all config from env at runtime.** Watch out for frameworks that bake env into the build
  (Next.js `NEXT_PUBLIC_*`, Vite `VITE_*`): the same image runs in staging and production, so such values
  must either be the same in both, or be read at runtime instead. Check this before adopting.
- **A Dockerfile** (or anything `docker build` can build) listening on one port.
- **`.github/workflows/`**, copied from onboarding-service:
  - `pr.yml`: `title` (calls `semantic-pr.yml@v0.1.0`) and the app's own tests;
  - `build.yml`: on `main`, tests then `build.yml@v0.1.0` (pushes `sha-<7>`);
  - `release.yml`: on `main`, its own file (it waits for `build.yml`'s run of the release commit, which
    never finishes if both are in one run), calls `release.yml@v0.1.0` with the `RELEASE_APP_*` secrets.
- **release-please config** at the root: `release-please-config.json` (`release-type`: `go`, `node`,
  `python`, …, or `simple`; `bootstrap-sha`: the commit before adoption, so the first changelog starts
  there) and `.release-please-manifest.json` (`{".": "0.0.0"}`).
- **`.github/CODEOWNERS`**: who approves releases (`* @kthaisociety/it-team`). The team needs write access.
- **Repo settings:** squash merges only, squash commit title = PR title (so a one-commit PR can't skip
  the title check), delete branches after merge.
- **Ruleset on `main`:** no deletion or force-push, linear history, signed commits, PRs only, squash
  only, all conversations resolved, code-owner review, required checks: `title / PR title is a
  Conventional Commit`, the tests, `Greptile Review`. (onboarding-service: only the first four so far.)
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
- **Done when:** a merge to `main` pushes `ghcr.io/kthaisociety/<repo>:sha-<7>`, which pulls logged out
  (`docker pull …` or the registry API), and release-please has opened a release PR whose checks ran.

### 2.2 Its OpenBao side, in `infrastructure`
- One line in `terraform/openbao/projects.yaml`: `my-app: {}` (staging and production), or
  `my-app: { shared: [name] }` if it reads shared secrets, or `environments: [...]` for others.
- PR, plan, merge. Creates per environment the policy `dokploy-project-<project>-<env>` and the empty path
  `secret/<project>/<env>`.
- Why here: a policy's contents decide what a token can read, and `deployments`' CI can mint tokens;
  only this repo writes policies. `deployments`' `check` fails with exactly this line until it exists.
- Needed again only for a new environment or a new shared secret. Not for new secrets, config or deploys.

### 2.3 Its secrets, in OpenBao
From a laptop (`brew install openbao`, `BAO_ADDR=https://bao.kthais.com`, `bao login -method=oidc
role=infra-admin`), or the UI at `https://bao.kthais.com/ui`:
- Every name in `project.yaml`'s `secrets`, at `secret/<project>/staging` and `secret/<project>/production`;
  shared ones at `secret/shared/<name>/<env>`.
- `put` for the first key on an empty path, `patch` after (a second `put` replaces the whole secret).
- Values through stdin, never as arguments; long values from the clipboard (a terminal paste is cut at
  1024 characters):
  ```sh
  pbpaste | tr -d '\n' | bao kv put -mount=secret <project>/production KEY=-
  pbpaste | tr -d '\n' | bao kv patch -mount=secret <project>/production OTHER=-
  pbcopy < /dev/null
  bao kv get -mount=secret -format=json <project>/production | jq '.data.data | map_values(length)'
  ```
- Before the first write, a path shows "404" in the UI and CLI: it exists as metadata only. Normal.
- **Staging's secrets:** separate from production's, never copies. Either real staging credentials, or
  **inert** ones when the app can act on real accounts (onboarding-service: a service-account JSON with no
  real key, a dummy Mattermost token, its own shared secret; see
  [onboarding-service-migration.md](onboarding-service-migration.md)).

### 2.4 Its Dokploy side, in `deployments`
- `projects/<project>/project.yaml` (format in 6.2) and `projects/<project>/release.yaml` with `null` for
  every environment.
- PR (a reviewer approves the `plan` run), merge. Creates the Dokploy project `<project>` with `staging`
  and `production`, and per environment a provider token and a vault provider `<project>-<env>`
  (connection tested). No app yet: no image.

### 2.5 Domains (if public) **[not yet]**
- `modules/project` doesn't create domains yet. Planned: `domains: [...]` per environment and `port:`
  in `project.yaml`, from which it makes the Dokploy domain (Traefik route and Let's Encrypt certificate).
- **DNS stays a manual `dnscontrol` PR** per host, pointing at the Dokploy host. Without the record Let's
  Encrypt can't validate; without the route Traefik answers 404 on its default certificate. Later,
  `deployments` may open that `dnscontrol` PR itself when a new domain appears.

### 2.6 First deploy, to staging
- PR to `deployments` setting `release.yaml`'s `staging:` to `ghcr.io/kthaisociety/<repo>:sha-<7>@sha256:<digest>`
  (digest from the `build` run's summary, or the registry). Merge: the app and its volumes are created and
  deployed.
- **Done when:** the deploy succeeds (every `${{vault…}}` reference resolved; a missing key fails the
  deploy), the app logs look right, and it answers on `http://<app name>:<port>` from `dokploy-network`.

### 2.7 First release, to production
- release-please only opens a release PR after a `feat:` or `fix:`, or a commit with a `Release-As:`
  footer. For a chosen first version, squash-merge any PR with this in the commit message:
  ```
  Release-As: 1.0.0
  ```
- A code owner merges the release PR: tag `v1.0.0`, GitHub Release, and the release commit's image
  tagged `1.0.0` (same digest, no rebuild).
- PR to `deployments` setting `production:` to `…:1.0.0@sha256:<digest>`. Merge.

## 3. Day to day

### 3.1 A change, to staging
- **Today:** PR in the app repo (title, tests, Greptile) → squash merge → `build` pushes `sha-<7>` → a PR
  to `deployments` updating `staging:` → merge → apply → staging redeploys.
- **After step 12:** the same, with `build` asking `deploy.yml`, which checks the request, opens and
  merges the `release.yaml` PR itself (`kthais-deploy`, `bot-scope`), waits for the apply, and reports back.

### 3.2 A release, to production
- Review the release PR (version, `CHANGELOG.md`), a code owner merges it → tag, GitHub Release →
  `release` waits for the release commit's build → tags `X.Y.Z` on that digest.
- **Today:** PR to `deployments` updating `production:`. **After step 12:** automatic, with
  `deploy.yml` also checking that the Release exists and the digest is the release commit's.

### 3.3 Config and secrets
- Non-secret env, volumes, new secret names: a PR to `project.yaml`. Merging redeploys.
- Secret values: change in OpenBao, then redeploy; a running app keeps the values it started with. Redeploy
  without a change: the app's **Deploy** button in Dokploy (it doesn't change config, so OpenTofu won't undo it).
- Never edit an app's settings in the Dokploy UI: the next apply overwrites them.

## 4. Rolling back
- Revert the `release.yaml` commit in `deployments` (or set the previous image): merging redeploys it.
- Never move a version tag, never edit the image in the Dokploy UI.
- Only `main`'s current tip is ever applied: re-running an old apply run does nothing.

## 5. When something fails

| Symptom | Look at | Likely cause → fix |
|---|---|---|
| PR blocked, `title` red | the PR's checks | title isn't a Conventional Commit → edit the title |
| PR blocked, `Greptile Review` missing | the PR | Greptile didn't run → comment `@greptileai review this PR` |
| PR can't merge, all green | the PR | unresolved conversations, or (where required) no code-owner approval |
| `build` red | its run | tests, or the image push |
| No release PR, or release PR without checks | `release` run | no `feat:`/`fix:`/`Release-As:` yet; or `kthais-release` not installed on the repo / secrets not visible to it |
| `release` red at "Wait for the release commit's build" | that run | the release commit's `build` failed or took over 45 min → fix, re-run |
| `deployments` `check` red: "isn't in … projects.yaml" | the check | add the printed line in `infrastructure` (2.2) |
| `deployments` `check` red: image format | the check | `release.yaml` needs `<image>:<tag>@sha256:<digest>` |
| `deployments` `plan` waiting | the run | needs a reviewer to approve the `plan` environment |
| Apply: `verify_connection` / vault provider error | `apply` run | Dokploy can't reach OpenBao or the token is wrong; check OpenBao is up and the provider token |
| Apply: 403 from OpenBao | `apply` run | `deployments-ci`'s policy lacks a path, or the project isn't in `projects.yaml` (no policy) |
| Deploy fails resolving a reference | Dokploy deploy log | the key isn't in OpenBao at that path → write it, redeploy |
| Deploy fails pulling the image | Dokploy deploy log | wrong digest, or the package isn't public (the repo isn't public) |
| Apps stop resolving secrets weeks later | Dokploy deploy log | provider token expired: the weekly apply didn't run → run `tofu` by hand |
| Warnings "Deprecated Resource vault_token" in plans | — | expected: we keep `vault_token` on purpose (a stable token per provider) |

## 6. Reference

### 6.1 Names
- Projects: lowercase letters, digits, single hyphens; not `infrastructure` or `shared`. Environments:
  lowercase letters and digits only (names join as `<project>-<env>`, split at the last hyphen).
- OpenBao: policy `dokploy-project-<project>-<env>`, path `secret/<project>/<env>`, shared
  `secret/shared/<name>/<env>`.
- Dokploy: project `<project>`, vault provider `<project>-<env>`, app internal name
  `<project>-<env>-<6 random>` (Dokploy picks the suffix; the apply output `projects` shows it), volume
  `<project>-<env>-<name>`.
- Images: `sha-<7>` (every build of `main`), `X.Y.Z` (releases, never moved); always pinned by digest.
- Secret references (generated, never hand-written): `${{vault.<project>-<env>.<project>/<env>:KEY}}`,
  shared `${{vault.<project>-<env>.shared/<name>/<env>:KEY}}`.

### 6.2 `project.yaml` (in `deployments`)
```yaml
repo: kthaisociety/my-app            # GitHub repo; the image is ghcr.io/<repo> unless `image:` says otherwise
defaults:                            # every environment, unless it overrides
  env:     { KEY: value }            # not secret, written as-is
  secrets: [SECRET_NAME]             # names only; values in OpenBao
  shared:  { shared-name: [KEY] }    # shared secrets, by name and key
  volumes: { /data: data }           # mount path: volume name (becomes <project>-<env>-data)
environments:
  staging: {}                        # same keys as defaults, to override
  production: {}
```
What the template does **not** do yet, added when the first app needs it: domains (2.5), Postgres and
Redis (optional blocks, for landingpage-backend), build arguments.

### 6.3 `release.yaml` (in `deployments`)
```yaml
staging: ghcr.io/kthaisociety/my-app:sha-3b6e8e5@sha256:<64 hex>
production: null                     # null: no app in that environment yet
```

### 6.4 Workflows
| Repo | Workflow | Runs on | Permissions |
|---|---|---|---|
| app | `pr.yml` | PRs | `pull-requests: read` (title), `contents: read` (tests) |
| app | `build.yml` | push to `main` | `contents: read`, `packages: write` |
| app | `release.yml` | push to `main` | `contents: read`, `packages: write`, `actions: read`; `kthais-release` token |
| `deployments` | `tofu.yml` | PRs (`check`; `plan` after approval), `main`, weekly, by hand (`apply`) | `id-token: write` for OpenBao; `plan`/`production` environment secrets |
| `deployments` | `deploy.yml` | dispatch from app repos | **not yet** (step 12) |
| `infrastructure` | `tofu.yml` | PRs, `main`, weekly | as above |

OpenTofu 1.12.6 in both repos (1.13.1 is out; upgrade both together).
