# Delivery plan: builds, releases and deploys

_Written 2026-10-02. Status (end of 2026-10-02): steps 1, 2 (OpenBao side), 4 and the `deployments`
OpenTofu are built; `deploy.yml` (step 5) isn't. Using it: [app-delivery.md](app-delivery.md); bot
identities: [bot-accounts.md](bot-accounts.md); the first app:
[onboarding-service-migration.md](onboarding-service-migration.md)._

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
- **Public by design.** Repos and images are public unless there's a specific reason not to be
  (decided 2026-10-02). Secrets live in OpenBao and GitHub secrets, never in a repo or an image, so being
  public costs nothing, and it's what makes rulesets and org secrets work on GitHub Free.

## Decisions

### Two repos: `infrastructure` and `deployments`

| | `infrastructure` (this repo) | `deployments` (new) |
|---|---|---|
| Holds | The platform: GleSYS storage, OpenBao (its deployment, auth methods, all policies including each project's, the empty secret paths, KV mount, token roles, snapshots), Dokploy core (backup destination, notifications) | Every project's Dokploy side: `project.yaml`, the image each environment runs, `modules/project`, and the provider tokens it mints for its vault providers |
| Changes | Rare, reviewed by infra admins | Frequent: tag bumps by a bot, project config by PR |
| Who writes | Humans, by PR | Humans by PR; the deploy bot through its own PRs, which only change image files |
| CI's OpenBao rights | `terraform`: everything | Minting tokens through `dokploy-provider` (which only grants existing `dokploy-project-*` policies), and nothing else: no policies, no secrets, no other token role |
| CI's Dokploy rights | Admin API key | A key for its own Dokploy user, `Deployments CI` (`ops+dokploy-deployments@kthais.com`), also an admin: members can't create or manage vault providers (open question 3) |

Why split:
- **Permissions.** The deploy bot needs to change `main` without a human review. In `infrastructure`
  that would sit next to OpenBao's auth config and the admin policy. In `deployments` the worst a bad bot
  change does is run a different, already-built image of an existing project.
- **Blast radius of CI.** `infrastructure`'s OpenBao login can do anything. `deployments`' login can
  only mint provider tokens. **Policies stay in `infrastructure`**, because a policy's contents, not its
  name, decide what its tokens read: a CI that could write `dokploy-project-*` policies could write one
  granting everything and mint a token with it (Greptile on #16). The infrastructure project's policy is
  outside the `dokploy-project-*` glob, with its own token role, so `deployments` can't reach
  `infrastructure/*` either. **It can still read every app's secrets, indirectly**, by minting a token
  with a project's policy: inherent to wiring Dokploy's providers. So its login is bound to `production`
  (main only) and `plan` (PR plans, after a reviewer approves the run; open question 7).
- **Noise.** Tag bumps would bury platform changes in `infrastructure`'s history.

What stays in `infrastructure` (decided after Greptile on #16): each project's OpenBao side,
`modules/project-secrets`, now policy and empty secret paths only, from `terraform/openbao/projects.yaml`.
Adding a project is one line there (`my-app: {}`), then its folder in `deployments`, whose checks fail
until that line exists. What moves to
`deployments`: the provider tokens (minted there) and everything Dokploy (`modules/project`).

How the move keeps everything working:
- **Dokploy projects, apps and vault providers** don't exist in OpenTofu yet (#9 was closed), so
  there's nothing to move: `deployments` creates them.
- **Provider tokens are re-minted, not moved.** A `vault_token` can't be imported with its value. So
  `deployments` mints new tokens for its vault providers, and `infrastructure` then drops its own (plain
  removal, which revokes them). Nothing uses the old ones yet.
- **Token renewal moves too.** `deployments` gets its own weekly scheduled apply, like `infrastructure`'s
  today. Without it, its tokens expire 32 days after the last apply and every deploy that resolves
  secrets fails. It's in place before the old tokens are dropped.

`deployments` is one root module with both providers (OpenBao and Dokploy), so a project's token,
vault provider and app are created in one apply, in order.

**Its state shares `infrastructure`'s bucket, under its own passphrase** (decided 2026-10-02):
`kthais-tfstate`, key `deployments/terraform.tfstate`, the same CI credential, and **a different
encryption passphrase**. GleSYS credentials cover a whole instance, so `deployments`' CI can reach
`infrastructure`'s state objects; the passphrase keeps them unreadable to it (OpenBao tokens, GleSYS
keys), and the bucket's versioning makes an overwrite recoverable. A separate instance would also rule
out tampering; not worth the extra instance while the same people and gates guard both repos. It
**doesn't read `infrastructure`'s state** either: the few values it needs (e.g. the backup
destination's id) are non-secret ids in its own config, or looked up through the Dokploy provider.

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
**`kthais-release`** App's token, not `GITHUB_TOKEN`: GitHub runs no workflows for events made with
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
- **Images are public**, like the repos they're built from (decided 2026-10-02, replacing "private"):
  an image holds nothing its public repo doesn't, and never a secret (config and secrets come from env
  at deploy time). So Dokploy pulls with no credential at all: no pull token, no Dokploy registry entry,
  no machine account. Each package's visibility is set to public once, after its first build (see
  app-delivery.md, "Adding a new app").
  If an app ever needs a private image: GHCR accepts only a classic personal access token
  (`read:packages`) for pulls, from a user account; neither fine-grained tokens nor GitHub App tokens
  work, and an App token would expire within the hour anyway.

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
   `kthais-deploy` merges it (squash; GitHub signs the merge commit).
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
`kthais-deploy` bypasses. So the bot skips review, never the checks, and only for image lines.

OpenTofu reads the image from `release.yaml` and doesn't ignore any part of it: what's in git is what
runs, and a manual redeploy of some other image is drift the next apply undoes.

Two credentials, kept apart:
- **`kthais-dispatch`:** `actions: write` on `deployments` only (installed there), its key in the org
  secrets `DISPATCH_APP_CLIENT_ID` / `DISPATCH_APP_PRIVATE_KEY`, visible to the app repos. It can ask for
  a deploy of an existing tag and nothing else; `deploy.yml` does the checking.
- **`kthais-deploy`** (App ID 5165860): `contents` and `pull-requests: write` on `deployments` only, used
  only by that repo's own workflows to open and merge the bot PRs. Its key is a repo secret there
  (`DEPLOY_APP_CLIENT_ID` / `DEPLOY_APP_PRIVATE_KEY`) and never leaves it.

## Build order

1. **This plan** — done (#10, 2026-10-02).
2. **`deployments` repo** — built 2026-10-02: public repo, rulesets (checks with no bypass; human review
   that only `kthais-deploy` bypasses), `production`/`plan` environments and secrets, the `deployments-ci`
   OpenBao login (#16), project policies in `infrastructure`'s `projects.yaml` (#17), OpenTofu root and
   `modules/project` with weekly apply and the stale-commit guard (deployments#1). Its first apply is the
   test of open question 3.
3. ~~GHCR pull credential~~ — not needed: images of public repos are public. Dokploy pulling one with
   no registry is checked on the first staging deploy (verify item 4, reworded).
4. **Reusable workflows** — built: `kthaisociety/workflows` `v0.1.0` (semantic PR titles, build,
   release). onboarding-service adopted them (onboarding-service#9): first image pushed; first release
   pending (needs a `Release-As:` commit); its ruleset still lacks the PR and check rules.
5. **`deploy.yml`** — not yet. Until it exists, deploying is a one-line `release.yaml` PR.
6. **onboarding-service on the new project** — in progress, steps in
   [onboarding-service-migration.md](onboarding-service-migration.md).
7. The next projects, one at a time: landingpage-backend (needs Postgres and a domain in
   `modules/project`), then the rest.
8. **[`docs/app-delivery.md`](app-delivery.md)** — written 2026-10-02 against what exists, each part
   marked built or not yet; finished when step 5 is.

## Decisions made while building (2026-10-02)

- **A project's OpenBao side is one line in `infrastructure`** (`terraform/openbao/projects.yaml`,
  `my-app: {}`). Policies decide what tokens read, so only the strict repo writes them (Greptile on #16
  showed a CI that writes `dokploy-project-*` policies can grant itself anything). Rejected: one policy
  per project for all its environments (staging could read production's secrets); `infrastructure`
  reading `deployments`' project list at apply time (no `infrastructure` edits, but a run-time dependency
  between the repos, an extra App permission and a "start the other run and wait" step, which is the
  kind of plumbing that breaks quietly). The manual line is rare (new projects and environments only),
  and `deployments`' check fails with the exact line, so it can't be forgotten.
- **Design frozen here.** Remaining effort goes into finishing and documenting what exists, not new
  mechanisms; the template grows only when an app needs it.
- **Template scope.** `modules/project` builds one app per environment from an image, with env, secrets
  and volumes. Not yet: domains, Postgres, Redis, build arguments. Each is added with the first app that
  needs it (domains and Postgres with landingpage-backend). Apps whose framework bakes env into the
  build (Next.js `NEXT_PUBLIC_*`) need checking first: one image runs in both environments.
- **Domains:** `project.yaml` will declare them per environment, and `modules/project` will create the
  Dokploy domain (Traefik route, certificate). DNS stays a manual `dnscontrol` PR per host; later,
  `deployments` may open that PR itself when a new domain appears.
- **Images are public; check each new package once.** Package visibility is separate from the repo's
  (GitHub's documented default for new packages is private). onboarding-service's came out public with no
  package step, but the new-app checklist verifies with a logged-out pull and switches it if needed.
- **`vault_token` despite its deprecation warning:** a stable token per provider, renewed in place.
  An ephemeral token would be new on every apply and churn every Dokploy provider.
- **OpenTofu 1.12.6 in both repos.** 1.13.1 came out 2026-10-01; upgrade both together, in one PR each.
- **`deployments` state** shares `kthais-tfstate` under its own key and passphrase (see "Two repos").

## Bot accounts and credentials

**Every new app is added by hand to each App's installation and to its secrets' repository access**
(see [app-delivery.md](app-delivery.md), "Adding a new app"). Nothing is scoped to "all repositories":
a secret is readable by every workflow in every repo it's visible to, so "all" would let any repo in the
org, including side projects, read `kthais-release`'s key and act on every app repo.

**GitHub Free limits** (checked 2026-10-02), which is why app repos and `deployments` are public:
- Rulesets and branch protection: public repos only. Organization-wide rulesets: GitHub Team and up,
  public repos included, so every repo gets its own ruleset.
- Organization secrets: not readable by private repos.
- Environment required reviewers: public repos only.

Every non-human identity in this plan is **created by hand**: GitHub has no API to create a user
account, a GitHub App's private key is only downloadable once from its settings, and Dokploy only lets
the organization owner set a member's permissions and only the user itself create its API keys. What
OpenTofu can manage is where those credentials are used (e.g. a `*_wo` attribute fed from a
`production` secret), not the accounts themselves.

So they're documented instead, in `docs/bot-accounts.md` (written with the step that creates each one):
per account, why it exists, its exact permissions, where its credentials are stored, how to rotate them,
and what breaks if they expire or are revoked.

**GitHub App private keys are not kept anywhere but their GitHub secret** (decided 2026-10-02). An App
can hold several valid keys, and an org owner can generate one at any time, so a copy in 1Password would
only add a place to leak from. Rotating, for a leak or routinely: generate a new key on the App's page,
`gh secret set` it, delete the old key, which stops working at once. The Client IDs aren't secret and
are recorded in `bot-accounts.md`.

**Re-running an old run must not roll back.** `kthais-dispatch` (held by every app repo) has
`actions: write` on `deployments`, which also allows re-running past runs, and a re-run uses its original
commit. So every apply in `deployments` first checks that its commit is still the tip of `main`, and
refuses otherwise; a re-run of an old apply then does nothing.

| Identity | Kind | Used for | Created in step |
|---|---|---|---|
| `Deployments CI` | Dokploy user, `member` role, API key | `deployments`' applies | 2 |
| `deployments` CI login | OpenBao JWT role (in `infrastructure`) | `deployments`' OpenBao changes | 2 (as code) |
| `kthais-release` (created 2026-10-02) | GitHub App, org-owned; `contents`, `pull-requests`, `issues: write`; installed on selected app repos; org secrets `RELEASE_APP_*` for those repos | release-please's release PRs, so their checks run | 4 |
| `kthais-dispatch` (created 2026-10-02) | GitHub App, org-owned; `actions: write`; installed on `deployments` only; org secrets `DISPATCH_APP_*` for the app repos | App repos requesting deploys | 5 |
| `kthais-deploy` (created 2026-10-02, App ID 5165860) | GitHub App, org-owned; `contents`, `pull-requests: write`; installed on `deployments` only; repo secrets `DEPLOY_APP_*` there | Opening and merging bot PRs; the only bypass of `deployments`' review ruleset | 5 |

No GHCR pull account: images are public (see "Builds").

## Open questions

1. ~~Private or public images.~~ **Public** (2026-10-02; first decided private, reversed the same day
   when the repos went public by design).
2. ~~A machine GitHub account.~~ **Not needed**: it was only for pulling private images.
3. ~~Dokploy permissions for `deployments`.~~ **Admin** (2026-10-02). Its own user, `Deployments CI`,
   started as a `member`; its first apply (deployments#1) showed members can't create or manage vault
   providers, only use ones already assigned to them (`vaultProvider.testConnection`: "unauthorized to
   access resource vaultProvider", 401). Dokploy's
   custom roles can grant exactly that, but need a paid license. So it's an admin: the split between the
   repos still protects OpenBao's configuration (`deployments-ci` only mints provider tokens), not
   Dokploy's settings or the `infrastructure` project. The gates in front of each repo's apply differ:
   - `infrastructure` `main`: PRs only, required checks (`title`, `changes`, `fmt`, `openbao-validate`,
     `Greptile Review`), no code-owner approval required; org admins bypass.
   - `deployments` `main`: required checks nobody bypasses (`title`, `check`, `bot-scope`), and a
     separate rule requiring a code owner's approval (plus `Greptile Review` and resolved threads),
     which `kthais-deploy` and org admins bypass. `kthais-deploy`'s PRs are limited to one
     `release.yaml` by `bot-scope`.
   Revisit with a custom role if the license ever comes.
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
7. ~~PR plans in `deployments`.~~ **In the `plan` environment, after a reviewer approves the run**
   (2026-10-02): `deployments-ci` accepts both `production` and `plan` (#16), since even a plan needs the
   OpenBao login (one root with both providers). Bot PRs skip the plan: they only change an image line,
   and `bot-scope` enforces that.
