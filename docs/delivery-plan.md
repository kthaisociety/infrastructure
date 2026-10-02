# Delivery plan: builds, releases and deploys

_Written 2026-10-02. Status: proposed. Nothing here is built yet._

How an app goes from a merged PR to running on Dokploy: every app repo builds images in CI and pushes
them to a registry; versions follow semantic commits and approved releases; a separate **deployments**
repo declares which image every project runs, and a CI bot keeps that declaration current. It replaces
the plan's "Apps run images built by their own repos, deployed by this one" and Phase 8, and puts
[#9](https://github.com/kthaisociety/infrastructure/pull/9) (onboarding-service built by Dokploy's
GitHub App) on hold: onboarding-service moves straight to this model instead.

## Goal

- **Images, not builds on the server.** Dokploy only pulls `registry/image:tag@digest`. How an app is
  built (Go, Node, Python, a Dockerfile or not) is its own repo's business. The GitHub App source, and
  every build setting in our config, goes away.
- **Git says what runs.** For every project and environment, one file holds the exact image. Rollback is
  a revert; a disaster-recovery rebuild brings back the versions that were running.
- **Production versions are deliberate.** Development and staging run whatever `main` built, by commit.
  Production runs a semver release that a code owner approved, with a changelog in the app's repo.
- **The platform stays strict; deployments can move fast.** Bot commits and frequent changes live in a
  repo that can't touch the underlying infrastructure.

## Decisions

### Two repos: `infrastructure` and `deployments`

| | `infrastructure` (this repo) | `deployments` (new) |
|---|---|---|
| Holds | The platform: GleSYS storage, OpenBao (its deployment, auth methods, admin policies, KV mount, token role, snapshots), Dokploy core (registry credentials, backup destination, notifications) | Every project: `project.yaml`, the image each environment runs, `modules/project` and `modules/project-secrets` |
| Changes | Rare, reviewed by infra admins | Frequent: tag bumps by a bot, project config by PR |
| Who writes | Humans, by PR | Humans by PR; the deploy bot through its own PRs, which only change image files |
| CI's OpenBao rights | `terraform`: everything | Only what projects need: `dokploy-project-*` policies, tokens from the `dokploy-provider` role, secret **metadata** (empty paths). Not `infrastructure/*`, auth methods, admin policies or the token role |
| CI's Dokploy rights | Admin API key | A key for its own non-admin Dokploy user, `cicd-bot`, limited to project resources (open question 3) |

Why split:
- **Permissions.** The deploy bot needs to change `main` without a human review. In `infrastructure`
  that would sit next to OpenBao's auth config and the admin policy. In `deployments` the worst a bad bot
  change does is run a different, already-built image of an existing project.
- **Blast radius of CI.** `infrastructure`'s OpenBao login can do anything. `deployments`' login can't
  touch OpenBao's auth, admin policies or `infrastructure/*`. **It can still read every project's
  secrets, indirectly:** it can mint a token from `dokploy-provider` with any `dokploy-project-*` policy,
  and those policies read secret data. So its PR plans stay behind the `plan` environment's reviewer
  gate, as today (open question 7), and its `production` login is limited to `main`.
- **Noise.** Tag bumps would bury platform changes in `infrastructure`'s history.

What moves from `infrastructure` to `deployments`: `terraform/projects/`, `modules/project`,
`modules/project-secrets`, the `module "project_secrets"` and shared-path parts of `terraform/openbao`,
and `terraform/dokploy/projects.tf`. `infrastructure` keeps the `dokploy-provider` token role and the
`infrastructure-production` provider.

How the move keeps everything working:
- **Policies, empty secret paths, Dokploy projects, apps and vault providers** move without being
  recreated: `removed { lifecycle { destroy = false } }` in `infrastructure`, `import` blocks in
  `deployments`. Both plans must show no destroy and no replace for these.
- **Provider tokens are re-minted, not moved.** A `vault_token` can't be imported with its value (import
  goes by accessor, and the resource then plans a replacement). So `deployments` mints new tokens, and
  each imported `dokploy_vault_provider` gets its new token on the same apply (its `token_wo_version`
  comes from the token's hash). Only after that apply succeeds does `infrastructure` drop the old tokens
  (plain removal, which revokes them). Order: `deployments` apply first, `infrastructure` second.
- **Token renewal moves too.** `deployments` gets its own weekly scheduled apply, like `infrastructure`'s
  today. Without it, its tokens expire 32 days after the last apply and every deploy that resolves
  secrets fails. It's in place before the old tokens are dropped.

`deployments` is one root module with both providers (OpenBao and Dokploy), so a project's policy,
token, vault provider and app are created in one apply, in order. That removes the "new project has no
token on the PR plan" problem the two-root setup has. It reads what it needs from `infrastructure`'s
state (Dokploy registry id, backup destination id) through `terraform_remote_state`.

### Semantic commits, enforced

Every app repo (and both infra repos) uses [Conventional Commits](https://www.conventionalcommits.org):
`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `ci:`, …, `!` or `BREAKING CHANGE:` for majors.

- PRs are squash-merged, so the PR title becomes the commit on `main`. A required check validates the
  title (e.g. `amannn/action-semantic-pull-request`).
- The check is one reusable workflow, called from every repo, so the rules live in one place.
- Rulesets on `main` require the check, linear history and squash merges. No direct pushes to `main`,
  for bots either: the deploy bot goes through PRs too (see "The deploy bot").

### Versions: digests for development and staging, semver for production

| Environment | What runs | Who decides |
|---|---|---|
| `staging` (every project, by default) | The image `main` just built: tag `sha-<short sha>`, pinned by digest | Automatic, on every merge to `main` |
| `production` | A release: tag `X.Y.Z`, pinned by digest | A code owner, by approving the release PR |

- **Every image reference is pinned by digest**: `ghcr.io/kthaisociety/<project>:1.4.0@sha256:…`. A tag can
  be moved; a digest can't. The tag is there for humans.
- **Releases promote, they don't rebuild.** The `X.Y.Z` tag is added to the digest that was already
  built from the release commit, so production runs exactly those bytes. Promotion waits for that build,
  and for staging where the project has one (see "Releases", step 4).

### Releases: a release PR that code owners approve

Per app repo, with [release-please](https://github.com/googleapis/release-please) (decided, open question
5). One release PR per repo at a time: each merge to `main` creates it or adds to it, so any number of
feature PRs end up in one release, and feature PRs never wait for it. release-please runs with the
**release App**'s token, not `GITHUB_TOKEN`: GitHub runs no workflows for events made with
`GITHUB_TOKEN`, so the release PR would never get its required checks and could never be merged.

1. As `feat:`/`fix:` commits land on `main`, the release bot keeps one open **release PR**: the next
   version (from the commit types) and the `CHANGELOG.md` entries.
2. A code owner (`CODEOWNERS`, required review on the release PR) merges it when they want a release.
3. Merging creates a new commit on `main` (the squash of the release PR), tags it `vX.Y.Z` and publishes
   a GitHub Release with the changelog.
4. Promotion, in the release workflow, **only after the release commit is built and tested**:
   - wait for the `build` run of the release commit to succeed. For a project without staging that
     means the image `sha-<release commit>` is pushed; with staging, also that it's deployed there and its
     checks passed (the build waits for its own staging deploy, see "The deploy bot");
   - add the `X.Y.Z` tag to that digest, then request a `production` deploy of `X.Y.Z`.

   If the build or staging fails, nothing is promoted; the release exists in git, without an image.

The changelog and the version live in the app's repo; the deployments repo only records which version
runs where.

### Builds: one reusable workflow, images in GHCR

- App repos call a reusable `build` workflow: test, build, push `ghcr.io/kthaisociety/<project>:sha-<short>`,
  report the digest, then ask `deployments` to deploy it to `staging` (if any).
- Pushing uses the repo's own `GITHUB_TOKEN` (`packages: write`); no extra secret.
- Each GHCR package grants write only to its own repo, so no repo can publish another app's image.
- **Images are private** (decided 2026-10-02). Dokploy pulls with one read-only credential, stored once
  as a Dokploy registry (`password_wo`) in `infrastructure`: a classic personal access token with only
  `read:packages`, from a machine user account. GHCR accepts only classic tokens (and `GITHUB_TOKEN` inside
  Actions), so neither a fine-grained token nor a GitHub App works: an App's tokens also expire after an
  hour, and Dokploy stores a fixed password. The machine account is a member with read access to the
  packages and nothing else; its token lives in 1Password and the `production` environment.

### The deploy bot: declarative, in git

`deployments` holds, per project, `projects/<project>/release.yaml`:

```yaml
production: ghcr.io/kthaisociety/onboarding-service:1.4.0@sha256:…
staging: ghcr.io/kthaisociety/onboarding-service:sha-3f2c1ab@sha256:…
```

1. An app's workflow (build for staging, release for production) triggers `deployments`' `deploy.yml`
   (`workflow_dispatch`: project, environment, **tag**, and a `request_id` it generates). The request
   carries no digest.
2. `deploy.yml` checks the request and **resolves the digest itself**:
   - the project and environment exist in `project.yaml`;
   - the tag exists in that project's GHCR package, and `deploy.yml` reads the digest it points to from
     the registry. The caller can't pair an approved tag with other bytes, because it never names the
     bytes;
   - for `production`: the tag is `X.Y.Z`, the project's repo has a GitHub Release `vX.Y.Z`, and the
     digest equals the one tagged `sha-<release commit>` (the commit `vX.Y.Z` points to).
3. It opens a PR that changes only that project's line in `release.yaml`, with a semantic title
   (`deploy(onboarding-service): production 1.4.0`). The required checks run on it, plus one more:
   `bot-scope`, which fails if a bot PR touches anything but `projects/*/release.yaml`. When they pass,
   the deploy App merges it (squash; GitHub signs the merge commit).
4. The merge to `main` applies, in one concurrency group. The image change redeploys the app; a failed
   deploy fails that apply run.
5. **`deploy.yml` waits for that apply and ends with its result.** It finds the apply run by the merge
   commit's SHA, waits for it to finish, and fails if the apply failed or never started. If the checks
   on the bot PR fail, it closes the PR and fails too. So one `deploy.yml` run is one deploy, start to
   finish.
6. **The app's workflow waits for `deploy.yml`.** `deploy.yml`'s `run-name` contains the `request_id`, so
   the app workflow finds its own run (a dispatch doesn't return a run id), waits for it, and reports
   its result. So a build that deploys to staging is only green once that image runs there, and a
   release only once it runs in production. A build of a project **without** staging deploys nothing:
   it's green once the image is pushed.

Rulesets on `deployments`' `main`: one ruleset with signatures, linear history and the required checks
(`bot-scope` included), which nobody bypasses; a second one requiring a human approval, which only the
deploy App bypasses. So the bot skips review, never the checks, and only for image lines.

OpenTofu reads the image from `release.yaml` and doesn't ignore any part of it: what's in git is what
runs, and a manual redeploy of some other image is drift the next apply undoes.

Two credentials, kept apart:
- **Trigger:** one org-owned GitHub App with `actions: write` on `deployments` only, its key an org secret
  for app repos. It can ask for a deploy of an existing tag and nothing else; `deploy.yml` does the
  checking.
- **Deploy App:** used only inside `deployments`' own workflow, to open and merge the bot PRs
  (`contents` and `pull-requests: write` on `deployments`). Its key never leaves that repo.

## Build order

1. **This plan**, reviewed (#10, merged 2026-10-02). Questions 1–3 are answered.
2. **`deployments` repo**: repo, rulesets, `production`/`plan` environments, its own OpenBao JWT role and
   policy (made in `infrastructure`), its Dokploy key, its weekly apply. Move the project parts out of
   `infrastructure` as in "How the move keeps everything working": `deployments` applies first
   (imports, new tokens), then `infrastructure` (keeps the rest, revokes old tokens). Check both plans
   show no destroy or replace outside the old tokens. The first apply is also the test of open
   question 3: if `cicd-bot` can't create a vault provider, it fails there.
3. **GHCR pull credential** as a Dokploy registry in `infrastructure` (verify item 4: does a registry
   alone let Dokploy pull, or does each app need it set).
4. **Reusable workflows**: semantic PR titles, build, release. Then onboarding-service adopts them:
   rulesets, `CODEOWNERS`, first image, first release `1.0.0`.
5. **`deploy.yml` and the GitHub App.** Until it exists, `release.yaml` is bumped by hand in a PR.
6. **onboarding-service on the new project**, image-based. The migration doc's data copy and switchover
   steps stay as they are; only the source changes from the GitHub App to `release.yaml`.
7. The next projects, one at a time: landingpage-backend, then the rest.
8. **[`docs/app-delivery.md`](app-delivery.md)** (outline written 2026-10-02): one linear guide, from a `git push` or a merged release PR to the app
   running on Dokploy: every check, approval, workflow and apply on the way, what each one proves, how
   to roll back, and where to look when a step fails. Each step above adds a draft section as it's
   built; it's finished last, against the real system, so it describes what exists.

## Bot accounts and credentials

**Every new app is added by hand to each App's installation and to its secrets' repository access**
(see [app-delivery.md](app-delivery.md), "Adding a new app"). Nothing is scoped to "all repositories":
a secret is readable by every workflow in every repo it's visible to, so "all" would let any repo in the
org, including side projects, read the release App's key and act on every app repo.

**GitHub Free limits** (checked 2026-10-02), which is why app repos and `deployments` are public:
- Rulesets and branch protection: public repos only. Organization-wide rulesets: GitHub Team and up,
  public repos included, so every repo gets its own ruleset.
- Organization secrets: not readable by private repos.
- Environment required reviewers: public repos only.

Every non-human identity in this plan is **created by hand**: GitHub has no API to create a user
account, a GitHub App's private key is only downloadable once from its settings, and Dokploy only lets
the organization owner set a member's permissions and only the user itself create its API keys. What
OpenTofu can manage is where those credentials are used (e.g. the Dokploy registry entry, with
`password_wo` from a `production` secret), not the accounts themselves.

So they're documented instead, in `docs/bot-accounts.md` (written with the step that creates each one):
per account, why it exists, its exact permissions, where its credentials are stored (1Password item,
GitHub environment secret), how to rotate them, and what breaks if they expire or are revoked.

| Identity | Kind | Used for | Created in step |
|---|---|---|---|
| GHCR pull account (e.g. `kthais-cicd`) | GitHub user, classic token `read:packages` | Dokploy pulling private images | 3 |
| `cicd-bot` | Dokploy user, `member` role, API key | `deployments`' applies | 2 |
| `deployments` CI login | OpenBao JWT role (in `infrastructure`) | `deployments`' OpenBao changes | 2 (as code) |
| Trigger App | GitHub App, `actions: write` on `deployments` | App repos requesting deploys | 5 |
| Deploy App | GitHub App, `contents`/`pull-requests: write` on `deployments` | Opening and merging bot PRs | 5 |
| Release App (`kthais-release`, created 2026-10-02) | GitHub App, org-owned; `contents`, `pull-requests`, `issues: write`; installed on selected app repos | release-please's release PRs, so their checks run | 4 |

Until the GHCR pull account exists, a classic `read:packages` token from an infra admin's own account
can stand in. It's stored in one place (the `production` environment), so switching is one secret; its
1Password item says "temporary, tied to <name>".

## Open questions

1. ~~Private or public images.~~ **Private** (2026-10-02), with a classic `read:packages` token.
2. ~~A machine GitHub account.~~ **Yes, created by hand** for the pull token (see "Bot accounts and
   credentials"). It has to be a user account, not a GitHub App (see "Builds"). An admin's own token
   can stand in until it exists.
3. **Dokploy permissions for `deployments`.** Decided: its own `member` Dokploy user, `cicd-bot`, with
   create projects/services/environments and API access, and no access to the `infrastructure`
   project. Not tested ahead (decided 2026-10-02): whether a member can create vault providers. The
   first apply in step 2 shows it; if it can't, `cicd-bot` becomes an admin, and the split then
   protects OpenBao's config but not Dokploy's settings.
4. ~~Staging.~~ **Every project has `staging` and `production` by default** (2026-10-02). A per-project
   switch to skip staging can come later, when a project needs it; the flow already handles a project
   without staging. onboarding-service goes first and exercises both deploy paths, the promotion gate,
   per-environment secret paths and verify item 1 (a provider assigned per environment).
   Each project decides what its staging secrets are. onboarding-service's are **inert**, so its staging
   has no power over real accounts:
   - `GOOGLE_ADMIN_SERVICE_ACCOUNT_JSON`: a dummy service account JSON with no real key. The app's
     `googleworkspace.NewClient` only parses it at boot (the key is used on the first Google call), so
     it starts, and any call to Google fails.
   - `MATTERMOST_BOT_TOKEN`: a dummy value. The startup ping only logs a failure.
   - `ONBOARDING_SERVICE_SECRET`: its own random value, so production and staging can't call each other.
   - Non-secret env as production, with its own empty volume.
5. ~~Release tool.~~ **release-please** (2026-10-02): the release PR is the approval step.
6. ~~Where reusable workflows live.~~ **`kthaisociety/workflows`** (2026-10-02), its own repo: app repos
   don't depend on the repo that holds deploy credentials, and pin the workflows by tag. Created
   2026-10-02, **public, and it must stay public**: a public repo can't call reusable workflows from a
   private one (the "organization" Actions access setting only opens a private repo to other private
   repos), and every app repo is public. It holds no secrets.
7. **PR plans in `deployments`.** Its CI login can mint tokens that read project secrets (see "Two repos"),
   so it can't be handed to unreviewed PR code. Default: PR plans in the `plan` environment behind a
   reviewer, as in `infrastructure`. Option: a separate PR role whose policy can read policies and look
   up tokens but not create tokens or write policies. Bot PRs then need a reviewer for their plan, or
   skip the plan (they only change an image line).
