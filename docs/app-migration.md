# Migrating an app from the Dokploy UI to the delivery pipeline

_2026-10-03, updated 2026-10-18 for domains, databases and staging-only apps. Generalized from onboarding-service's migration
([onboarding-service-migration.md](onboarding-service-migration.md)), the first app moved. How the
pipeline works once an app is on it: [app-delivery.md](app-delivery.md). Why it's built this way:
[delivery-plan.md](delivery-plan.md). Every bot and credential: [bot-accounts.md](bot-accounts.md)._

An app "on Dokploy" today is a project someone built in the Dokploy UI: Dokploy builds it from GitHub on
every push, its env vars (secrets included) are typed into the UI, maybe with a database next to it. After
the migration:

- the app's own repo **tests, builds and releases** it (GitHub Actions, images on GHCR);
- `kthaisociety/deployments` **declares and deploys** it (OpenTofu): a new Dokploy project with `staging`
  and `production`, built from code;
- its **secrets live in OpenBao**, referenced from Dokploy, never typed into it;
- its **data is copied** from the old app at a switchover; the old app is kept, stopped, for a week.

It's a rebuild next to the old app, not an import: nothing about the old app changes until the
switchover, and rolling back is pointing back at it.

**Status of the building blocks** (keep this up to date):

| Need | Status |
|---|---|
| App from an image, env, secrets, volumes, staging + production | **built** (onboarding-service) |
| Internal-only app (called by other apps on `dokploy-network`) | **built** |
| Staging only (no production yet) | **built**: production stays an idle placeholder (section 2) |
| Public domain (Traefik route + certificate) | **built** (deployments#14, section 5.3) |
| Postgres, Redis | **in review** (deployments#19, section 5.4) |
| Database outside Dokploy (Neon, Supabase, …) | moves to our Postgres; data copied at the switchover (section 7.2) |
| Database backups | **not yet** (needs a GleSYS backup destination in OpenTofu) |
| Build-time env (Next.js `NEXT_PUBLIC_*`, Vite `VITE_*`) | **not supported**: one image runs in both environments (section 2) |

An app that needs a "not yet" waits for it, or the first such app adds it to `modules/project` (one PR,
reviewed like any other), then migrates.

**Who:** someone with admin on the GitHub org, admin in Dokploy, the `infra-admin` login to OpenBao, and
SSH to the Dokploy host (`sam@synapse.aisociety.se`). **Time:** about two hours spread over a day or two,
plus a 10–30 minute switchover window.

---

## 1. Inventory the old app

Everything the old app has that the new one must have too. Most of it is in the Dokploy UI; secrets must
not be copied anywhere but OpenBao, so read them only when writing them there (section 4).

### 1.1 Read its configuration
In the Dokploy UI (project → app), or with this script, which prints the configuration and env **names**
but never secret values (it uses the Dokploy CLI's own login; run it on your laptop, not through an AI
tool's shell if you'd rather nothing be logged):

```sh
C="$(dirname "$(readlink -f "$(which dokploy)")")/../config.json"
python3 - "$C" "<project name in Dokploy>" <<'EOF'
import json, sys, urllib.request
cfg = json.load(open(sys.argv[1])); url = cfg["url"].rstrip("/"); tok = cfg["token"]; want = sys.argv[2]
get = lambda p: json.load(urllib.request.urlopen(urllib.request.Request(f"{url}/api/{p}", headers={"x-api-key": tok})))
for p in get("project.all"):
    if p["name"] != want: continue
    for e in p.get("environments", []):
        ids = {"postgres": "postgresId", "redis": "redisId", "mysql": "mysqlId", "mariadb": "mariadbId", "mongo": "mongoId"}
        for kind in ("applications", "postgres", "redis", "mysql", "mariadb", "mongo", "compose"):
            for s in e.get(kind) or []:
                extra, name, app_name = "", s.get("name"), s.get("appName")
                if kind in ids:  # databases: the image carries the version
                    d = get(f"{kind}.one?{ids[kind]}={s[ids[kind]]}")
                    name, app_name = d.get("name"), d.get("appName")
                    extra = f" image={d.get('dockerImage')} db={d.get('databaseName')} user={d.get('databaseUser')}"
                print(f"[{e['name']}] {kind}: {name}{extra}" + (f" appName={app_name}" if app_name else ""))
        for a in e.get("applications") or []:
            d = get(f"application.one?applicationId={a['applicationId']}")
            print("  app:", d.get("name"), "appName (internal host name):", d.get("appName"))
            print("  source:", d.get("sourceType"), d.get("owner"), d.get("repository"), d.get("branch"),
                  "| build:", d.get("buildType"), d.get("dockerfile"), "| autoDeploy:", d.get("autoDeploy"))
            for line in (d.get("env") or "").splitlines():
                if "=" in line and not line.lstrip().startswith("#"):
                    k, v = line.split("=", 1)
                    print(f"  env {k.strip()} = <{len(v)} chars>")
            print("  mounts:", [(m.get("type"), m.get("volumeName") or m.get("hostPath"), m.get("mountPath")) for m in d.get("mounts") or []])
            print("  domains:", [(x.get("host"), x.get("port"), x.get("https"), x.get("path")) for x in d.get("domains") or []])
            print("  volume backups:", [(b.get("volumeName"), b.get("cronExpression")) for b in d.get("volumeBackups") or []])
EOF
```

### 1.2 Fill in this checklist
| | Write down | onboarding-service had |
|---|---|---|
| Repo, branch, how it's built | `owner/repo`, branch, Dockerfile path | `kthaisociety/onboarding-service`, `main`, `Dockerfile` |
| Port it listens on | from the Dockerfile / config | 8000 |
| Env vars: **not secret** | name and value (go into `project.yaml`) | `BACKEND_URL`, `PORTAL_BASE_URL`, … |
| Env vars: **secret** | name only (values go to OpenBao) | `MATTERMOST_BOT_TOKEN`, … |
| Shared secrets | a value another app also has (same name, same value) | `ONBOARDING_SERVICE_SECRET` (with landingpage-backend) |
| Volumes | mount path, volume name, what's in it | `/data` → `onboarding-service-data` (SQLite) |
| Databases | Postgres/Redis/… services in the project: names, image (version), database and user (the script prints them). Or an external one (Neon, Supabase): its provider and Postgres version, from the connection setting's name | none |
| Domains | hosts, port, path | none |
| Who calls it | other apps' env holding its internal name or domain | backend + frontend `ONBOARDING_SERVICE_URL` |
| What it calls | URLs in its own env (other apps, Mattermost, …) | backend, Mattermost, Google |
| Backups, schedules | Dokploy backups, cron jobs | none |
| Background work | does it do anything on its own (jobs, timers, consumers)? | none: only acts when called |

The last row matters for the switchover: an app with background work must never run twice against the
same data (old and new at once). An app that only acts when called can run side by side while idle.

### 1.3 Find who calls it
Search every app's env for its internal name (`<appName>`) and its domains: in Dokploy, each project's
Environment tab, or the script above per project. Those env vars change at the switchover (section 7).

---

## 2. Decide

- **Production, or staging only.** An app with no real users yet (only a dev version today) moves to
  **staging only**: `deployments` still creates production, but it stays an idle placeholder until the
  app's first release. Its switchover (section 7) happens on staging.
- **Staging's secrets.** Real but separate credentials (a test Google account, a staging API key), or
  **inert** ones when the app can act on real accounts and nothing safe exists (onboarding-service:
  a service-account JSON with no real key, a dummy bot token). Never production's values.
- **Build-time configuration.** The same image runs in staging and production, so everything that
  differs must come from env **at runtime**. Frameworks that bake env into the bundle (Next.js
  `NEXT_PUBLIC_*`, Vite `VITE_*`) need those values to be identical in both environments, or read at
  runtime instead (a `/config` endpoint, `window.__ENV__` injected at start, or server-side rendering).
  Fix that in the app first.
- **Domains.** Production keeps its domain, but it moves to the new app only at the switchover (5.3,
  7.5). Staging gets its own host (`<name>-staging.kthais.com`), or none if it's tested internally. A
  staging-only app that keeps its old host (e.g. a `-dev` name) moves it the same way as production's;
  a new `-staging` host avoids that.
- **Version.** The first release: `1.0.0`, or the version the app already uses.
- **Switchover window.** When the app is least used; long enough for the data copy.

---

## 3. The app repo

### 3.1 Public, and clean
- The repo must be **public** (public by design; on GitHub Free, rulesets and org secrets don't work for
  private repos). Before making a private repo public, scan its **whole history** for secrets: making it
  public publishes every old commit.
  ```sh
  brew install gitleaks
  gitleaks git . --log-opts="--all" --redact --no-banner
  ```
  A real finding means: rotate that credential first, then go public.
- Config only from env at runtime (section 2). A `Dockerfile` (or anything `docker build` builds), one
  port, a health endpoint if possible.

### 3.2 Workflows
Copy onboarding-service's three workflow files and adapt the test job (language, commands). All the logic
lives in `kthaisociety/workflows`; these only call it. Pin the current release of `kthaisociety/workflows`
(`v0.2.0` at the time of writing).

`.github/workflows/pr.yml`: on every PR, the title check and the tests (both become required checks).
```yaml
name: pr
on:
  pull_request:
    types: [opened, edited, synchronize, reopened]
permissions: {}
jobs:
  title:
    uses: kthaisociety/workflows/.github/workflows/semantic-pr.yml@v0.2.0
    permissions:
      pull-requests: read
  test:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@<sha> # v7.0.1   (copy the pinned SHA from onboarding-service)
        with:
          persist-credentials: false
      # language setup and tests, e.g. for Go:
      - uses: actions/setup-go@<sha> # v7.0.0
        with:
          go-version-file: go.mod
      - run: go vet ./...
      - run: go test -race ./...
```

`.github/workflows/build.yml`: on every push to `main`, tests, the image, and (once the app exists in
`deployments`, section 6) the staging deploy. Start **without** the `deploy-staging` job.
```yaml
name: build
on:
  push:
    branches: [main]
permissions: {}
jobs:
  test:
    # the same test job as in pr.yml
  build:
    needs: test
    uses: kthaisociety/workflows/.github/workflows/build.yml@v0.2.0
    permissions:
      contents: read
      packages: write
  # added in section 6.3:
  # deploy-staging:
  #   needs: build
  #   uses: kthaisociety/workflows/.github/workflows/request-deploy.yml@v0.2.0
  #   with:
  #     environment: staging
  #     tag: ${{ needs.build.outputs.tag }}
  #   secrets:
  #     dispatch-app-client-id: ${{ secrets.DISPATCH_APP_CLIENT_ID }}
  #     dispatch-app-private-key: ${{ secrets.DISPATCH_APP_PRIVATE_KEY }}
```
If the project name in `deployments` differs from the repo name, pass `project: <name>` to
`request-deploy.yml`.

`.github/workflows/release.yml`: its own file (it waits for `build.yml`'s run of the release commit,
which can never finish if both are in one run).
```yaml
name: release
on:
  push:
    branches: [main]
permissions: {}
jobs:
  release:
    uses: kthaisociety/workflows/.github/workflows/release.yml@v0.2.0
    with:
      build-workflow: build.yml
    permissions:
      contents: read
      packages: write
      actions: read
    secrets:
      release-app-client-id: ${{ secrets.RELEASE_APP_CLIENT_ID }}
      release-app-private-key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
  # added at the switchover (section 7.6):
  # deploy-production:
  #   needs: release
  #   if: needs.release.outputs.release-created == 'true'
  #   uses: kthaisociety/workflows/.github/workflows/request-deploy.yml@v0.2.0
  #   with:
  #     environment: production
  #     tag: ${{ needs.release.outputs.version }}
  #   secrets: (as in build.yml)
```

### 3.3 Release configuration
`release-please-config.json`:
```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "bootstrap-sha": "<the commit on main just before this PR>",
  "packages": {
    ".": {
      "release-type": "go",
      "package-name": "<repo name>",
      "changelog-path": "CHANGELOG.md",
      "include-component-in-tag": false
    }
  }
}
```
- `release-type`: `go`, `node`, `python`, … (also bumps that language's version file), or `simple`.
- `include-component-in-tag: false` is required: releases must be tagged `vX.Y.Z`, which is what
  `deployments`' production check looks for.
- `bootstrap-sha`: so the first changelog starts at the adoption, not at the repo's first commit.

`.release-please-manifest.json`: `{ ".": "0.0.0" }` (or the current version, if the app has one and
its tag exists as `vX.Y.Z`).

### 3.4 Code owners
`.github/CODEOWNERS`: the people who approve releases, e.g. `* @sammosios`. Keep it to the people who
actually review: GitHub requests a review from, and emails, every code owner on every PR, including the
release PR. A team works but gets every request; it needs write access to the repo.

### 3.5 Repo settings and ruleset
```sh
R=kthaisociety/<repo>
gh api -X PATCH repos/$R -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=COMMIT_MESSAGES
```
Squash commits must take the PR title, so a one-commit PR can't skip the title check. Then a ruleset on
`main` (after the first PR has run, so the check names exist): no deletion or force-push, linear history,
signed commits, PRs only, squash only, conversations resolved, code-owner review, required checks
`title / PR title is a Conventional Commit`, `test` and `Greptile Review`; org admins may bypass. Copy
`kthaisociety/deployments`' ruleset JSON (`gh api repos/kthaisociety/deployments/rulesets`) and adjust
the check names, or ask an infra admin.

Never use GitHub's "Rebase" or "Update branch" buttons on these repos: the first produces unsigned
commits, the second a merge commit; both block the merge. Rebase locally and force-push instead.

### 3.6 The bots' scope
Nothing is scoped to "all repositories", on purpose ([bot-accounts.md](bot-accounts.md)). For the new repo:
- **`kthais-release`:** org → Settings → GitHub Apps → `kthais-release` → Configure → add the repo.
- **Its secrets:** add the repo to `RELEASE_APP_CLIENT_ID`, `RELEASE_APP_PRIVATE_KEY`,
  `DISPATCH_APP_CLIENT_ID` and `DISPATCH_APP_PRIVATE_KEY` (org → Settings → Secrets and variables →
  Actions → each secret → Repository access). With `gh`, `--repos` replaces the whole list, so name every
  app repo:
  ```sh
  gh secret set DISPATCH_APP_CLIENT_ID --org kthaisociety --visibility selected --repos onboarding-service,<new repo> --body '<client id>'
  ```
  The private keys aren't stored anywhere else: setting the secret's repository list in the UI keeps
  the value. With `gh`, setting a key needs the key (generate a new one on the App's page, then delete
  the old).
- **`kthais-dispatch`** stays installed on `deployments` only. **`kthais-deploy`**: nothing.

### 3.7 The first image
Merge the workflows PR (squash). `build` pushes `ghcr.io/kthaisociety/<repo>:sha-<7>`. Check it's public,
logged out:
```sh
docker logout ghcr.io; docker pull ghcr.io/kthaisociety/<repo>:sha-<7>
```
If denied: org → Packages → `<repo>` → Package settings → Change visibility → Public.

---

## 4. Its OpenBao side and secrets

### 4.1 `infrastructure`: one line
In `terraform/openbao/projects.yaml`, PR, merge (it applies):
```yaml
my-app: {}                                  # staging and production
```
That creates, per environment, the policy `dokploy-project-my-app-<env>` and the empty path
`secret/my-app/<env>`, and the policy also reads the shared store `secret/shared/<env>`. Policies live
here, not in `deployments`, because their contents decide what a token can read. Needed again only for a
new environment.

### 4.2 The secrets
From a laptop (`brew install openbao`), or the UI at `https://bao.kthais.com/ui` (Google sign-in):
```sh
export BAO_ADDR=https://bao.kthais.com
bao login -method=oidc role=infra-admin
```
**Every value is new.** Anything that was in Dokploy counts as exposed: nobody controlled who saw it.
So never copy a value from the old app. For each secret name from the inventory, issue a new one where
it comes from (a new API key, bot token or OAuth client secret on the provider's page), and write it
**through the clipboard** (never typed into a command line, never pasted into chat):
```sh
printf '%s' "$(pbpaste)" | bao kv put   -mount=secret my-app/production FIRST_KEY=-
printf '%s' "$(pbpaste)" | bao kv patch -mount=secret my-app/production SECOND_KEY=-
pbcopy < /dev/null
```
A value the app itself defines (a signing key, a random token) is generated straight into OpenBao:
```sh
openssl rand -base64 32 | tr -d '\n' | bao kv patch -mount=secret my-app/production SESSION_SECRET=-
```
- `put` for the first key on an empty path, `patch` for every key after it (a second `put` replaces
  the whole secret).
- The old app keeps running on the old values until the switchover. Revoke them at the source in 7.8.
- A new value for a secret another app also holds (a shared secret, a key it verifies) must reach that
  app too, at the switchover. Note it in 1.3's list of callers.
- Database credentials aren't written here: the pipeline creates them (5.4).
- `printf '%s' "$(pbpaste)"` drops a trailing newline and keeps internal ones (PEM keys stay intact).
- Shared secrets go to `secret/shared/<env>`, once, not per app. Every project can read them.
- Then staging's, at `my-app/staging` (section 2): never production's values.
- Check by length, not value:
  ```sh
  bao kv get -mount=secret -format=json my-app/production | jq '.data.data | map_values(length)'
  ```
- A path shows "404" before its first write: it exists as metadata only. Normal.

---

## 5. `deployments`: the project

### 5.1 The files
One PR in `kthaisociety/deployments`:

`projects/my-app/project.yaml`:
```yaml
repo: kthaisociety/my-app        # the image is ghcr.io/<repo>
defaults:                        # every environment, unless it overrides
  env:                           # not secret, as-is
    SOME_URL: https://example.org
  secrets:                       # names only; values in OpenBao at secret/my-app/<env>
    - API_TOKEN
    - DATABASE_URL               # written by the pipeline, from databases (5.4)
  shared:                        # names only; values in OpenBao at secret/shared/<env>
    - ONBOARDING_SERVICE_SECRET
  databases:                     # each environment gets its own (5.4)
    postgres: {}
  volumes:                       # mount path → volume name (becomes my-app-<env>-<name>)
    /data: data
environments:
  staging:                       # takes only env and domains
    env:
      SOME_URL: https://staging.example.org   # overrides
    domains:                     # 5.3
      my-app-staging.kthais.com: {port: 8000}
  production: {}                 # its domain is added at the switchover (7.5)
```
Every key is described in `deployments`' `docs/project-yaml.md`; `docs/project.template.yaml` is a
starting point.

`projects/my-app/release.yaml`: every environment `null` (check requires it for a new project):
```yaml
staging: null
production: null
```

`.github/workflows/deploy.yml`: add `my-app` to the `project` input's `options` (the dropdown;
`check` fails until it's there).

### 5.2 Merge
`check` must pass (it also fails, with the exact line, if `infrastructure`'s `projects.yaml` doesn't list
the project yet). A reviewer approves the `plan` run; read it: per environment a provider token, a vault
provider, an app and its mounts, its databases and their credentials in OpenBao, staging's domain, plus
the project and `staging`. Merge: it applies. In Dokploy: project
`my-app`, `staging` and `production`, an idle app in each (placeholder image, not deployed), both providers
under Settings → Secrets.

### 5.3 Domains
`domains:` under an environment in `project.yaml`, keyed by host, each with the container `port`
(deployments#14). `modules/project` creates the Dokploy domain: Traefik route and Let's Encrypt
certificate. `check` rejects a host declared twice in `deployments`.
- **DNS** is a `dnscontrol` PR per host, pointing at the Dokploy host. Merge staging's before its first
  deploy, so the certificate can be issued. Production's usually exists already (it's the old app's).
- **Staging's domain goes in this PR. Production's doesn't.** A merge applies right away, and the old app
  still serves that host. Two Traefik routers with the same `Host()` rule have equal priority, and
  which one serves a request isn't something to rely on; it can change on a reload. `check` can't catch
  it either: the old app isn't in `deployments`. So production's domain is a separate PR, prepared and
  approved before the switchover and merged during it, right after the domain is removed from the old
  app (section 7.5). The same applies to a staging-only app that keeps its old host.
- To try production in a browser before the switchover, give it a temporary host
  (`my-app-next.kthais.com`: DNS plus a domain under `production`), and remove it after.

### 5.4 Postgres and Redis **[deployments#19, in review]**
Until #19 is merged, an app with a database waits.
- `databases:` under `defaults` (`postgres: {}`, `redis: {}`): each environment gets its own instance,
  on its own volume, `postgres:17-alpine` and `redis:7-alpine` unless `image:` says otherwise. Defaults
  only: the code relies on it, so a staging-only app's production gets one too, idle.
- **The credentials are generated by OpenTofu**, so no person writes or sees them, and written to OpenBao
  at `secret/<project>/<env>/database/<engine>` by `deployments`' CI. People can only read that path.
- **The app gets a setting only when its name is listed in `secrets`**: `PGHOST`, `PGPORT`, `PGUSER`,
  `PGPASSWORD`, `PGDATABASE`, `DATABASE_URL` for Postgres, `REDIS_HOST`, `REDIS_PORT`,
  `REDIS_PASSWORD`, `REDIS_URL` for Redis. `check` fails on an engine with none of its names listed.
- The database and user are the project name with `_` for `-` (`my_app`).
- **Backups:** not yet (IT-18), needs a GleSYS destination in OpenTofu.
- If the app's current database has to stay a while longer (agree with an infra admin first): leave
  `databases` out, change the old database's password, put its connection settings in OpenBao as
  ordinary secrets, and migrate the database later.

---

## 6. Staging

### 6.1 First deploy
Actions in `kthaisociety/deployments` → **deploy** → Run workflow: project `my-app`, environment
`staging`, tag `sha-<7>` (from the app's `build` run summary). One run: validate, commit the line, apply,
**Deployed**. The app switches from the placeholder to the image and deploys, volumes attached.

### 6.2 Check it
- Dokploy: the deploy log has no unresolved `${{vault…}}` reference (a missing key fails the deploy:
  write it in OpenBao, deploy again).
- The app log looks right; with inert secrets, expect failures exactly where they're inert.
- It answers: `sudo docker run --rm --network dokploy-network alpine wget -qO- http://<app name>:<port>/health`
  (the app name is in Dokploy, `my-app-staging-<6 random>`).

### 6.3 Automatic staging deploys
Add the `deploy-staging` job to `build.yml` (section 3.2), merge. From now on every merge to `main` is on
staging within minutes, and `build` is green only once it runs there.

### 6.4 First release
Squash-merge any PR with this last in the commit message (with other trailers, in the same last
paragraph):
```
Release-As: 1.0.0
```
release-please opens "release 1.0.0" with `CHANGELOG.md`. Merge it (a code owner): tag `v1.0.0`, its
GitHub Release, and, once the release commit's build and staging deploy passed, the image tag `1.0.0`.
Don't delete release tags: release-please finds the previous release by its tag, and would propose the
same version again.

A staging-only app skips this until it's ready for production.

---

## 7. Data migration and switchover

Before: production's secrets written (4.2), the release built (6.4), the steps below read through, the
rollback understood, and a time when the app is least used. Each step: check before the next.

**A staging-only app** does this whole section on **staging**: copy into staging's volumes and database,
skip 7.3 (staging already runs the latest build; redeploy its current `sha-<7>` after the copy if the app
must start on the copied data), and skip 7.6.

### 7.1 Freeze the old app
Dokploy → old project → app: **Auto Deploy off** (otherwise a push to the repo rebuilds and restarts
it), then **Stop**. From here until 7.5 the app is down. Stop its database too only after its dump (7.2).

### 7.2 Copy the data

**Files on a volume** (SQLite, uploads), on the host:
```sh
OLD=<old volume>; NEW=my-app-production-<name>; UID_=<uid the app runs as, from its Dockerfile>
sudo docker volume inspect "$OLD" --format '{{.Name}}' || { echo "no source volume: stop"; exit 1; }
sudo docker run --rm -v "$OLD":/from:ro -v "$NEW":/to alpine sh -c "set -e
  [ -n \"\$(ls -A /from)\" ] || { echo 'source is empty: stop'; exit 1; }
  [ -z \"\$(ls -A /to)\" ]   || { echo 'destination is not empty: stop (see below)'; exit 1; }
  cp -a /from/. /to/
  diff -r /from /to
  chown -R $UID_:$UID_ /to
  ls -lnR /to"
```
- **The source must exist by that exact name** (`docker volume inspect` above): `docker run -v` would
  otherwise create it empty, and the copy would "succeed" with nothing in it.
- **The destination must be empty**: `cp -a` only overwrites files with the same name, so anything
  already there (a database the new app created, an old SQLite journal) would stay and mix with the
  copy. It is empty if the new production app was never deployed. If it was: stop it in Dokploy, empty
  the volume (`sudo docker run --rm -v "$NEW":/to alpine find /to -mindepth 1 -delete`), copy, then
  deploy it again.
- **`diff -r` must print nothing**: the whole tree arrived, file by file.
- **The `chown` matters**: the app runs as a non-root user, and SQLite needs to write in the directory
  itself (journal files).

**Postgres in the old Dokploy project**, on the host:
```sh
OLD_DB=$(sudo docker ps -q --filter name=<old postgres appName>)
NEW_DB=$(sudo docker ps -q --filter name=my-app-production-postgres)   # its database and user: my_app
# a custom-format dump from the old database, while the old app is stopped
sudo docker exec "$OLD_DB" pg_dump -U <old user> -d <old db> -Fc -f /tmp/app.dump
sudo docker cp "$OLD_DB":/tmp/app.dump /tmp/app.dump
sudo docker cp /tmp/app.dump "$NEW_DB":/tmp/app.dump
sudo docker exec "$NEW_DB" pg_restore -U <new user> -d <new db> --no-owner --no-privileges --exit-on-error /tmp/app.dump
# check: row counts of the main tables match on both sides
sudo docker exec "$OLD_DB" psql -U <old user> -d <old db> -c "select count(*) from <table>"
sudo docker exec "$NEW_DB" psql -U <new user> -d <new db> -c "select count(*) from <table>"
sudo rm /tmp/app.dump; sudo docker exec "$OLD_DB" rm /tmp/app.dump; sudo docker exec "$NEW_DB" rm /tmp/app.dump
```
- Restore into an empty database; the new app's migrations should run after, not before, unless the app
  requires its schema first (then restore data only: `--data-only`).
- Same or newer Postgres major version on the new side (ours is 17). `pg_dump` from the newer version
  if they differ.
- The dump contains everything in the database: delete it from the host when done.

**An external Postgres (Neon, Supabase, …)**, on the host. **[untested]** The dump runs in a throwaway
`postgres:17-alpine` container, so its `pg_dump` matches our version; the source must be 17 or older.
Use the provider's **direct** connection string, not a pooled one (on Neon, the host without `-pooler`):
`pg_dump` needs a session the pooler doesn't give it.
```sh
read -rs SRC_URL      # paste the connection string; it isn't echoed or kept in history
printf '%s\n' "$SRC_URL" | sudo docker run --rm -i -v /tmp:/out postgres:17-alpine \
  sh -c 'read -r SRC_URL; pg_dump "$SRC_URL" -Fc --no-owner --no-privileges -f /out/app.dump'
NEW_DB=$(sudo docker ps -q --filter name=my-app-production-postgres)
sudo docker cp /tmp/app.dump "$NEW_DB":/tmp/app.dump
sudo docker exec "$NEW_DB" pg_restore -U my_app -d my_app --no-owner --no-privileges --exit-on-error /tmp/app.dump
```
Compare row counts as above; for the old side, pipe `$SRC_URL` into the same throwaway image and run
`psql "$SRC_URL" -c "select count(*) from <table>"`. Then `unset SRC_URL` and delete the dump from the
host and the container. Extensions the provider installs (e.g. Neon's
`neon` schema objects) can make `--exit-on-error` stop: restore again without it and read every error.
Keep the external database until 7.8: it's the rollback.

**Redis:** usually a cache or a queue that refills: start empty. If it holds data that must survive
(sessions you can't lose, persistent queues): `redis-cli SAVE` in the old one, then copy its volume's
`dump.rdb` like a volume above, before the new Redis starts.

**Object storage** (GleSYS, S3): nothing to copy; the new app uses the same buckets through its secrets.

### 7.3 Deploy production
Actions → **deploy** → project `my-app`, environment `production`, tag `1.0.0`. It checks the GitHub
Release `v1.0.0` exists and that `1.0.0` is exactly the release commit's build, commits, applies:
**Deployed**.

### 7.4 Check production
- The deploy log, the app log (real secrets now: every integration should work), `/health`.
- The data is there: a record you know exists, a count that matches.

### 7.5 Switch the traffic
- **Internal apps** (called by other apps): in each caller's Environment (from 1.3), point the URL at
  `http://<new production app name>:<port>`, save, redeploy that caller. If the caller is itself managed
  in `deployments`, change it in its `project.yaml` instead (a PR).
- **Public apps:** remove the domain from the **old** app in the Dokploy UI first, then merge the
  `deployments` PR that adds it under `production` (prepared and approved before the window, 5.3). The
  merge applies. Never both at once (5.3). DNS doesn't change (same host). Traefik should reuse the
  certificate it already has for that name **[untested]**; if the browser shows a certificate error,
  give it a minute for Let's Encrypt.
- Check end to end through a real user flow (onboarding-service: the admin's records list showed the old
  records).

### 7.6 Automatic production deploys
Add the `deploy-production` job to the app's `release.yml` (section 3.2), merge. From now on merging a
release PR deploys that release to production.

### Rollback (until 7.8)
Point the callers back at the old app and redeploy them, or revert the domain PR and add the domain
back to the old app (in that order), then start the old app. Data written to
the new app since 7.5 isn't in the old one: copy it back the same way, or accept the loss if nothing was
written.

### 7.7 Tell people
The app's maintainers: config changes are PRs to `deployments` (`project.yaml`), secrets are in OpenBao,
deploys happen by merging (staging) and releasing (production), and the Dokploy UI is read-only for it
(edits are overwritten by the next apply).

### 7.8 A week later
Delete the old Dokploy project, then its volumes and databases on the host (`sudo docker volume rm
<old volume>`), after checking the new app ran fine all week. **Except** if the new app still uses a
database in the old project (the exception in 5.4): then keep that project and database until the
database itself has been migrated and verified, and delete only the old app in it. Delete an external
database (Neon, …) at its provider. Revoke every old secret where it was issued (4.2): API keys, bot
tokens, OAuth client secrets, the external database's credentials. Update the status table at the top of
this guide if the app needed something new.

---

## 8. Checklist

```
Inventory
[ ] 1.1–1.3  config, env names, secrets, volumes, databases, domains, callers, background work
[ ] 2        production or staging only, staging secrets, build-time env, domains, version, window
App repo
[ ] 3.1      public, history scanned, runtime config only
[ ] 3.2–3.4  pr.yml, build.yml, release.yml, release-please config (include-component-in-tag false), CODEOWNERS
[ ] 3.5      squash-only + PR_TITLE settings; ruleset after the first PR
[ ] 3.6      kthais-release installed; repo added to RELEASE_APP_* and DISPATCH_APP_* secrets
[ ] 3.7      first image pushed, pulls logged out
infrastructure + OpenBao
[ ] 4.1      projects.yaml line, merged and applied
[ ] 4.2      new production and staging secrets written (none copied), checked by length
deployments
[ ] 5.1–5.2  project.yaml, release.yaml (nulls), dropdown option; merged; idle apps visible
[ ] 5.3      staging's DNS + domain; production's domain PR prepared, not merged
[ ] 5.4      databases + their names in secrets (after deployments#19)
Staging
[ ] 6.1–6.2  deployed by hand, checked
[ ] 6.3      deploy-staging job
[ ] 6.4      first release
Switchover
[ ] 7.1      old app: auto-deploy off, stopped
[ ] 7.2      volumes and database copied into an empty destination; diff -r / row counts match
[ ] 7.3–7.4  production deployed and checked
[ ] 7.5      callers switched / domain removed from old app, then PR merged; end-to-end check
[ ] 7.6      deploy-production job
[ ] 7.7      maintainers told
[ ] 7.8      a week later: old project, data and external database deleted; old secrets revoked
```
