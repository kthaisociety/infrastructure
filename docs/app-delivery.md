# App delivery: from a push to running on Dokploy

_Outline, 2026-10-02. The design is in [delivery-plan.md](delivery-plan.md); this is the guide to using
it. Each section is filled in by the step that builds it (marked **[step n]**) and checked against the
real system before it's called done. Until then, treat anything here as intended, not as fact._

Every app has two environments, `staging` and `production`. Merging to `main` deploys to staging.
Merging the release PR deploys to production. Nothing else deploys.

```
feature PR ──merge──▶ build ──▶ sha-<commit> ──deploy.yml──▶ staging
                         └─▶ release PR updated (next version + changelog)
release PR ──merge (code owner)──▶ vX.Y.Z + GitHub Release
                         ├─▶ build ──▶ sha-<release commit> ──deploy.yml──▶ staging
                         └─▶ release: wait for that build ──▶ X.Y.Z = same digest ──deploy.yml──▶ production
```

## 1. The pieces

**[step 1–5]** One short paragraph each: what it is, where it lives, what it may do.

- **App repo** (e.g. `kthaisociety/onboarding-service`): the code, `CHANGELOG.md`, the version
  (release-please's manifest), and three small workflow files that call `kthaisociety/workflows`.
- **`kthaisociety/workflows`**: the reusable workflows. `semantic-pr`, `build`, `release`. Public, and
  must stay public: the public app repos can't call workflows from a private repo.
- **GHCR** (`ghcr.io/kthaisociety/<project>`): the images. Public (made so by hand after the first
  push, since GHCR creates packages private); each package writable only by its
  own repo.
- **`kthaisociety/deployments`**: per project, `project.yaml` (config, secret names) and `release.yaml`
  (the exact image per environment), and `deploy.yml`.
- **OpenBao** (`bao.kthais.com`): secret values, at `secret/<project>/<environment>`.
- **Dokploy**: runs the images. Never builds, never decides what runs.
- **Bots**: `kthais-release`, `kthais-dispatch`, `kthais-deploy` (GitHub Apps), `Deployments CI` (Dokploy user) (see
  [bot-accounts.md](bot-accounts.md)).

## 2. Adding a new app

A checklist, in order, with who does each step and what "done" looks like.

### 2.1 In the app repo **[step 2]**
- Dockerfile (or whatever builds an image); the app reads all config from env.
- `.github/workflows/`: `pr.yml` (semantic title), `build.yml`, `release.yml`, each a few lines calling
  `kthaisociety/workflows@<tag>`.
- `release-please-config.json` and `.release-please-manifest.json` (start at `0.1.0` or the current version).
- `CODEOWNERS`: who approves releases.
- Ruleset on `main`: PRs only, squash only, signed commits, required checks (title, tests); release PR
  requires a code owner.
- **The repo must be public** (public by design; also, the org is on GitHub Free, where rulesets and org
  secrets don't work for private repos).
- **The callers start without deploying.** `build.yml` and `release.yml` don't ask `deployments` for
  deploys yet (the project doesn't exist there); that's switched on in 2.5.
- **After the first build, make the image public** (GHCR creates every new package private): org →
  Packages → `<repo>` → Package settings → Danger Zone → Change visibility → Public. Check it: `docker
  pull ghcr.io/kthaisociety/<repo>:sha-<7>` works logged out. Dokploy pulls with no credentials, so
  until this is done no deploy of the app can work.
- **Add the repo to each GitHub App's scope, and to its secrets.** Nothing is "all repositories", on
  purpose: a secret is readable by every workflow in every repo it's visible to, and an App's key works
  on every repo it's installed on.
  - `kthais-release`: org → Settings → GitHub Apps → `kthais-release` → Configure → add the repo under
    "Only select repositories". Then add the repo to the org secrets `RELEASE_APP_CLIENT_ID` and
    `RELEASE_APP_PRIVATE_KEY` (org → Settings → Secrets and variables → Actions → each secret →
    repository access), or:
    ```sh
    gh secret set RELEASE_APP_CLIENT_ID   --org kthaisociety --visibility selected --repos <repo-a>,<repo-b>,... --body '<client id>'
    gh secret set RELEASE_APP_PRIVATE_KEY --org kthaisociety --visibility selected --repos <repo-a>,<repo-b>,... < key.pem
    ```
    (`--repos` replaces the whole list: name every repo, not only the new one.)
  - `kthais-dispatch`: it stays installed on `deployments` only; add the new repo to its org secrets'
    repository access (`DISPATCH_APP_CLIENT_ID`, `DISPATCH_APP_PRIVATE_KEY`) the same way.
  - `kthais-deploy`: nothing. It lives in `deployments` only.
- **Ruleset on `main`** (copy onboarding-service's): PRs only, squash only, signed commits, linear
  history, all conversations resolved, required checks (title, tests, `Greptile Review`).

### 2.2 In `infrastructure`, then `deployments` **[step 4]**
- `infrastructure` PR first: the project, its environments and shared secrets in `terraform/openbao`'s
  project list. That writes its `dokploy-project-<project>-<env>` policies and empty secret paths.
  Policies live here, not in `deployments`, because their contents decide what a token can read.
- `projects/<project>/project.yaml`: image name, port, domain (if any), volumes, non-secret env and
  secret names per environment.
- PR, merge: creates the Dokploy project with `staging` and `production`, a vault provider per
  environment, the empty secret paths, the apps (not deployed: no image yet).

### 2.3 Secrets **[step 4]**
- In the OpenBao UI or CLI: `secret/<project>/staging` and `secret/<project>/production`, every name from
  `project.yaml`. `put` once, `patch` after; values through the clipboard, never as arguments.
- Decide what staging's secrets are: real-but-separate credentials, or inert ones (onboarding-service).

### 2.4 DNS, if the app has a domain **[step 6]**
- `dnscontrol` PR for each host (staging and production).

### 2.5 First deploy **[step 5]**
Needs 2.1's public image, 2.2 and 2.3.
- In the app repo, switch on deploy requests in `build.yml` (staging) and `release.yml` (production)
  (one input each), and merge that. Its build deploys to staging.
- First release: merge the release PR. Production gets its first image.
- If a deploy fails with "pull access denied" / "manifest unknown": the image isn't public. Make it
  public, then re-run the failed `build` run's failed jobs; it requests the deploy again.

## 3. Day to day

### 3.1 A change, to staging **[step 5]**
What runs, in order, and what each check proves: PR checks → squash merge → `build` (test, image
`sha-<commit>`, push) → `deploy.yml` (digest lookup, bot PR on `release.yaml`, `bot-scope`, merge,
apply) → staging redeploys → `build` goes green.

### 3.2 A release, to production **[step 5]**
Reviewing the release PR (version, changelog) → merge by a code owner → tag and GitHub Release →
release commit built and on staging → `X.Y.Z` added to that digest → `deploy.yml` (Release exists,
digest matches) → production redeploys → `release` goes green.

### 3.3 Changing config or secrets **[step 4]**
- Non-secret env, volumes, domains: a PR to `project.yaml`.
- Secret values: OpenBao, then a redeploy (a changed secret takes effect only on the next deploy). How
  to redeploy without a new image.

## 4. Rolling back **[step 5]**
- Production: revert the `release.yaml` commit in `deployments` (the previous image comes back), or
  release a fix. What not to do (re-tagging, editing in the Dokploy UI).
- Staging: the next merge replaces it; or revert as above.

## 5. When something fails **[step 5–7]**
A table: symptom → which run to open → likely cause → fix. At least:
- Title check fails on a PR.
- `build` fails (tests, image push).
- Release PR doesn't appear or has no checks (`kthais-release`: installed on the repo? secrets visible to it?).
- `deploy.yml` rejects the request (unknown project/environment, tag missing, digest mismatch).
- Bot PR fails `bot-scope` or other checks.
- Apply fails: vault reference doesn't resolve (missing key), image pull denied (GHCR credential),
  deploy timeout, Dokploy API key.
- App deployed but unhealthy.
- OpenBao provider token expired (weekly apply missed).

## 6. Reference **[step 7]**
- Every file an app repo has, and every file `deployments` has for it, with an example.
- Every workflow, its trigger, and the permissions it runs with.
- Image tags: `sha-<short>` (every build), `X.Y.Z` (releases); always pinned by digest in `release.yaml`.
- Secret reference format: `${{vault.<project>-<env>.<project>/<env>:KEY}}`, written by `modules/project`.
