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
| Who writes | Humans, by PR | Humans by PR; the deploy bot directly to its image files |
| CI's OpenBao rights | `terraform`: everything | Only what projects need: `dokploy-project-*` policies, tokens from the `dokploy-provider` role, secret **metadata** (empty paths). Never secret values |
| CI's Dokploy rights | Admin API key | A key for its own non-admin Dokploy user, `cd-bot`, limited to project resources (open question 3) |

Why split:
- **Permissions.** The deploy bot needs to commit to `main` without review. In `infrastructure` that would
  sit next to OpenBao's auth config and the admin policy. In `deployments` the worst a bad commit does is
  run a different image of an existing project.
- **Blast radius of CI.** `infrastructure`'s OpenBao login can do anything, which is why it never plans
  on PRs. `deployments`' login can't read a single secret value, so its PRs can get real plans.
- **Noise.** Tag bumps would bury platform changes in `infrastructure`'s history.

What moves from `infrastructure` to `deployments`: `terraform/projects/`, `modules/project`,
`modules/project-secrets`, the `module "project_secrets"` and shared-path parts of `terraform/openbao`,
and `terraform/dokploy/projects.tf`. `infrastructure` keeps the `dokploy-provider` token role and the
`infrastructure-production` provider. The move is done with `tofu state mv` into the new state (or
`removed` + `import` blocks), so nothing is recreated: policies and tokens keep working.

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
- Rulesets on `main` require the check, linear history and squash merges.

### Versions: digests for development and staging, semver for production

| Environment | What runs | Who decides |
|---|---|---|
| `staging` (optional per project) | The image `main` just built: tag `sha-<short sha>`, pinned by digest | Automatic, on every merge to `main` |
| `production` | A release: tag `X.Y.Z`, pinned by digest | A code owner, by approving the release PR |

- **Every image reference is pinned by digest**: `ghcr.io/kthaisociety/<project>:1.4.0@sha256:…`. A tag can
  be moved; a digest can't. The tag is there for humans.
- **Releases promote, they don't rebuild.** The `X.Y.Z` tag is added to the digest that was already
  built from that commit (and ran on staging, if the project has one), so production runs exactly the
  bytes that were tested.

### Releases: a release PR that code owners approve

Per app repo, with [release-please](https://github.com/googleapis/release-please) (or an equivalent;
open question 5):

1. As `feat:`/`fix:` commits land on `main`, the release bot keeps one open **release PR**: the next
   version (from the commit types) and the `CHANGELOG.md` entries.
2. A code owner (`CODEOWNERS`, required review on the release PR) merges it when they want a release.
3. Merging tags `vX.Y.Z` and publishes a GitHub Release with the changelog.
4. The tag triggers promotion: the `X.Y.Z` image tag on the existing digest, then a deploy request for
   `production`.

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
   (`workflow_dispatch`: project, environment, image with digest).
2. `deploy.yml` checks the request: the project and environment exist; the digest exists in that
   project's GHCR package; for `production`, the tag is a semver tag with a GitHub Release in the
   project's repo.
3. It commits the new line to `release.yaml` on `main` through the GitHub API (commits made that way are
   signed by GitHub, which the `main` ruleset requires), then applies in the same run, in one
   concurrency group.
4. The image change redeploys the app; a failed deploy fails the run, which the app repo sees.

OpenTofu reads the image from `release.yaml` and doesn't ignore any part of it: what's in git is what
runs, and a manual redeploy of some other image is drift the next apply undoes.

The trigger credential: one org-owned GitHub App with `actions: write` on `deployments` only, its key
an org secret for app repos. It can start deploys of existing images and nothing else.

## Build order

1. **This plan**, reviewed. Questions 1–3 are answered; check question 3 against Dokploy's permissions.
2. **`deployments` repo**: repo, rulesets, `production`/`plan` environments, its own OpenBao JWT role and
   policy (made in `infrastructure`), its Dokploy key. Move the project parts out of `infrastructure`
   with state moves, and confirm an empty plan in both repos.
3. **GHCR pull credential** as a Dokploy registry in `infrastructure` (verify item 4: does a registry
   alone let Dokploy pull, or does each app need it set).
4. **Reusable workflows**: semantic PR titles, build, release. Then onboarding-service adopts them:
   rulesets, `CODEOWNERS`, first image, first release `1.0.0`.
5. **`deploy.yml` and the GitHub App.** Until it exists, `release.yaml` is bumped by hand in a PR.
6. **onboarding-service on the new project**, image-based. The migration doc's data copy and switchover
   steps stay as they are; only the source changes from the GitHub App to `release.yaml`.
7. The next projects, one at a time: landingpage-backend, then the rest.

## Open questions

1. ~~Private or public images.~~ **Private** (2026-10-02), with a classic `read:packages` token.
2. ~~A machine GitHub account.~~ **Yes, one is created** for the pull token. It has to be a user account,
   not a GitHub App (see "Builds"). Name and owner of its credentials to decide.
3. **Dokploy permissions for `deployments`.** Decided: its own non-admin Dokploy user, `cd-bot`. To
   check before step 2: can that user create projects, apps and vault providers while being unable to
   touch the `infrastructure` project (OpenBao's compose) and Dokploy's settings? If not, `cd-bot` needs
   admin, and the split protects OpenBao's config but not Dokploy.
4. **Staging.** Which projects get a `staging` environment, and on the same host? It doubles their
   resource use.
5. **Release tool.** release-please (release PR, changelog, works per language) or semantic-release
   (releases on every merge, no approval step). The approval requirement points to release-please.
6. **Where reusable workflows live**: in `deployments`, or a separate `kthaisociety/workflows` repo that
   every app repo can call. Private repos can only call workflows from repos that allow it (an org
   setting).
7. **PR plans in `deployments`.** Its OpenBao policy can't read secret values, but a plan still reads the
   provider tokens it manages. Either a separate read-only role for PRs, or PR plans in the `plan`
   environment with a reviewer gate, as today.
