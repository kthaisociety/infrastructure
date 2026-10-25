# Migrating an app from the Dokploy UI to the delivery pipeline

_2026-10-03, rewritten 2026-10-25 now that the pipeline is operational (onboarding-service and Lucid run
on it). How the pipeline works: [app-delivery.md](app-delivery.md). Why it's built this way:
[delivery-plan.md](delivery-plan.md). Every bot and credential: [bot-accounts.md](bot-accounts.md)._

An app "on Dokploy" today is a project someone built in the Dokploy UI: Dokploy builds it from GitHub on
every push, its env vars (secrets included) are typed into the UI, maybe with a database next to it. After
the migration:

- the app's own repo **tests, builds and releases** it (GitHub Actions, images on GHCR);
- `kthaisociety/deployments` **declares and deploys** it: a new Dokploy project with `staging` and
  `production`, built from code;
- its **secrets live in OpenBao**, new values, referenced from Dokploy, never typed into it;
- its **data is copied** from the old app at a switchover; the old app is kept, stopped, for a week.

It's a rebuild next to the old app, not an import: nothing about the old app changes until the
switchover, and rolling back is pointing back at it.

**The pipeline doesn't do yet:** database backups (IT-18), object storage per project (IT-39), build
arguments, build-time env (section 2). An app that needs one waits for it, or the first such app adds it
to `deployments`' `modules/project` (one PR, reviewed like any other), then migrates.

**Who:** someone with admin on the GitHub org, admin in Dokploy, the `infra-admin` login to OpenBao, and
SSH to the Dokploy host. Anyone can do the inventory and prepare the PRs; pair with an infra admin for the
rest. **Time:** a few hours for staging, plus a 10–30 minute switchover window.

**Steps in order:** inventory → decide → `infrastructure` → `deployments` → secrets → app repo → staging →
first release (production runs, unreachable) → switchover (data and traffic) → clean up. Each step ends with a check; don't start the next one before it passes.

---

## 1. Inventory: everything the old app has

The most important step. Everything the new app needs must be known before the first PR: a missing env
var shows up only as an app that deploys fine and then doesn't work, and the Dokploy logs rarely say why.
Write the result down where the team can see it (the migration's Linear issue).

### 1.1 Read the old app's configuration
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

### 1.2 Check it against the app itself
What Dokploy holds can be incomplete or stale. Compare it with the app's `.env.example`, its config
code and its README, and ask its maintainers. Every setting the app reads must end up in one of
`env`, `secrets` or `shared` in `project.yaml`.

### 1.3 Fill in this checklist
| | Write down | Example |
|---|---|---|
| Repo, branch, how it's built | `owner/repo`, the branch Dokploy deploys, Dockerfile path | `kthaisociety/onboarding-service`, `main`, `Dockerfile` |
| Port it listens on | from the Dockerfile / config | 8000 |
| Env vars: **not secret** | name and value (go into `project.yaml`) | `PUBLIC_URL`, `BACKEND_URL` |
| Env vars: **secret** | name only, and where each value is issued (values go to OpenBao, new) | `MATTERMOST_BOT_TOKEN` (Mattermost), `OIDC_CLIENT_SECRET` (Google Cloud) |
| Shared secrets | a value another app also has (same name, same value) | `ONBOARDING_SERVICE_SECRET` (with landingpage-backend) |
| Build-time env | `NEXT_PUBLIC_*`, `VITE_*` or anything else baked into the image | none |
| Volumes | mount path, volume name, what's in it | `/data` → `onboarding-service-data` (SQLite) |
| Databases | Postgres/Redis/… in the project: name, image (version), database, user (the script prints them). Or external (Neon, Supabase): provider and Postgres version | Lucid: Postgres and Redis |
| Domains | hosts, port, path | `lucid.kthais.com`, 8000 |
| Sign-in | OAuth clients and their redirect URIs (the new hosts must be added) | Lucid: Google, `dev-client` / `production-client` |
| Who calls it | other apps' env holding its internal name or domain | backend + frontend `ONBOARDING_SERVICE_URL` |
| What it calls | URLs in its own env (other apps, Mattermost, …), and allow-lists that name its host or IP | backend, Mattermost, Google |
| One-off commands | what must run once after a fresh deploy (first admin, seed data), and how in the container | Lucid: `./lucid appoint-admin <email>` |
| Backups, schedules | Dokploy backups, cron jobs | none |
| Background work | does it act on its own (jobs, timers, consumers, bot polling, emails)? | none: only acts when called |
| Branches | is anything unmerged on other branches (a `dev` branch Dokploy deploys)? | none |

Background work decides when production may run (6.5): such an app must never run twice with the same
accounts or data (old and new at once). An app that only acts when called can run side by side: with no
domain and no callers, nothing reaches it.

### 1.4 Find who calls it
Search every app's env for the old app's internal name (`appName`) and its domains: in Dokploy, each
project's Environment tab, or the script above per project. Those env vars change at the switchover.

**Done when** every row has an answer, and every setting the app reads has a name in the list.

---

## 2. Decide

- **Production, or staging only.** An app with no real users yet moves to **staging only**: production
  still exists, an idle placeholder, until the app's first release. Its switchover happens on staging.
- **Staging's secrets.** Real but separate credentials (a test account, a staging API key, the dev OAuth
  client), or **inert** ones when the app can act on real accounts and nothing safe exists. Never
  production's values.
- **Build-time configuration.** The same image runs in staging and production, so everything that differs
  must come from env **at runtime**. Values baked into the bundle (`NEXT_PUBLIC_*`, `VITE_*`) must be the
  same in both, or be read at runtime instead (a `/config` endpoint, `window.__ENV__` injected at start,
  server-side rendering). Fix that in the app first.
- **Domains.** Production keeps its host; it moves to the new app only at the switchover. Staging gets
  `<name>-staging.kthais.com`, or none if it's tested internally.
- **Branches.** The pipeline deploys `main` only. Merge what's worth keeping from other branches (a `dev`
  branch) into `main` before the migration; delete them after the switchover.
- **Version.** The first release: `1.0.0`, or the version the app already uses.
- **Switchover window.** When the app is least used; long enough for the data copy.

---

## 3. `infrastructure`: the OpenBao side

In `terraform/openbao/projects.yaml`, one line, PR, merge (it applies):
```yaml
my-app: {}                                  # staging and production
```
That creates, per environment, the policy `dokploy-project-my-app-<env>` and the empty path
`secret/my-app/<env>`; the policy also reads the shared store `secret/shared/<env>`.

**First**, before the `deployments` PR: its `check` fails until this line is merged.

**Done when** the `tofu` run on `main` applied, and `secret/my-app/staging` and `.../production` show in
OpenBao (as "404" before their first write: they exist as metadata only. Normal).

---

## 4. `deployments`: the project

### 4.1 The PR
One PR in `kthaisociety/deployments`, with three changes.

`projects/my-app/project.yaml`, from the inventory. Lucid's (`projects/lucid/project.yaml`) is a complete
example; every key is described in `docs/project-yaml.md`.
```yaml
repo: kthaisociety/my-app        # the image is ghcr.io/<repo>
defaults:                        # every environment, unless it overrides
  env:                           # not secret, as-is
    SOME_URL: https://example.org
  secrets:                       # names only; values in OpenBao at secret/my-app/<env>
    - API_TOKEN
    - DATABASE_URL               # from databases: listed here, or the app doesn't get it
  shared:                        # names only; values in OpenBao at secret/shared/<env>
    - ONBOARDING_SERVICE_SECRET
  databases:                     # each environment gets its own
    postgres: {}
environments:
  staging:                       # takes only env and domains
    env:
      PUBLIC_URL: https://my-app-staging.kthais.com
    domains:
      my-app-staging.kthais.com: {port: 8000}
  production:
    env:
      PUBLIC_URL: https://my-app.kthais.com
    # no domains yet: production's host moves at the switchover (7.4)
```
- **Every secret name from the inventory**, including ones the old app was missing.
- **Databases:** `postgres: {}`, `redis: {}` (versions 17 and 7 unless `image:` says otherwise). The
  pipeline generates their credentials into OpenBao; nobody writes them. The app gets `DATABASE_URL`,
  `PGHOST`, `REDIS_URL`, … only for the names listed in `secrets` (`docs/project-yaml.md` lists them per
  engine). The database and user are the project name with `_` for `-` (`my_app`).
- **Volumes** (`volumes: { /data: data }`): only if the app keeps files; avoid.
- **Production's real domain is not in this PR**: the old app still serves that host, and two Traefik
  routes for one host is undefined behaviour. Open it now as a separate PR, get it approved, and merge it
  during the switchover (7.4). It also removes the temporary host (6.5).

`projects/my-app/release.yaml`: every environment `null` (check requires it for a new project):
```yaml
staging: null
production: null
```

`.github/workflows/deploy.yml`: add `my-app` to the `project` input's `options`.

### 4.2 Merge
`check` must pass. A reviewer approves the `plan` run; read it: per environment a provider token, a vault
provider, an app, its databases and their credentials, staging's domain. Merge: it applies.

**Done when** Dokploy has a project `my-app` with `staging` and `production`, an idle app in each
(placeholder image, not deployed), the databases running, and both vault providers under Settings →
Secrets.

### 4.3 DNS
A `dnscontrol` PR for the staging host, pointing at the Dokploy host, merged before the first staging
deploy (Let's Encrypt needs it to issue the certificate). Production's host usually exists already (it's
the old app's).

---

## 5. Secrets in OpenBao

From a laptop (`brew install openbao`), or the UI at `https://bao.kthais.com/ui` (Google sign-in):
```sh
export BAO_ADDR=https://bao.kthais.com
bao login -method=oidc role=infra-admin
```
**Every value is new.** Anything that was in Dokploy counts as exposed: nobody controlled who saw it. For
each secret name, issue a new value where it comes from (a new API key, bot token or OAuth client secret),
and write it **through the clipboard** (never typed into a command line, never pasted into chat):
```sh
printf '%s' "$(pbpaste)" | bao kv put   -mount=secret my-app/staging FIRST_KEY=-
printf '%s' "$(pbpaste)" | bao kv patch -mount=secret my-app/staging SECOND_KEY=-
pbcopy < /dev/null
```
A value the app itself defines (a signing key, a random token) is generated straight into OpenBao:
```sh
openssl rand -base64 32 | tr -d '\n' | bao kv patch -mount=secret my-app/staging SESSION_SECRET=-
```
- `put` for the first key on an empty path, `patch` for every key after it (a second `put` replaces the
  whole secret).
- Staging's now, production's before the first release (6.5). Never the same values (section 2).
- OAuth clients: add the new hosts' redirect URIs to the client before writing its ID and secret.
- Shared secrets go to `secret/shared/<env>`, once, not per app. Every project can read them, and a new
  value must also reach the other apps holding it, at the switchover.
- Database credentials aren't written here: the pipeline wrote them in 4.2.
- The old app keeps running on the old values until the switchover; they're revoked in section 8.

**Done when** every name in `secrets` has a value at `my-app/staging`, checked by length, not value:
```sh
bao kv get -mount=secret -format=json my-app/staging | jq '.data.data | map_values(length)'
```

---

## 6. The app repo, and staging

### 6.1 Public, and clean
The repo must be **public** (on GitHub Free, rulesets and org secrets don't work for private repos).
Before making a private repo public, scan its **whole history** for secrets: making it public publishes
every old commit.
```sh
brew install gitleaks
gitleaks git . --log-opts="--all" --redact --no-banner
```
A real finding means: rotate that credential first, then go public. Config only from env at runtime
(section 2); a `Dockerfile`, one port, a health endpoint if possible.

### 6.2 The bots, before the first workflow runs
Nothing is scoped to "all repositories", on purpose ([bot-accounts.md](bot-accounts.md)). Without these,
the first build fails with a client-id error:
- **`kthais-release`:** org → Settings → GitHub Apps → `kthais-release` → Configure → add the repo.
- **Org secrets:** add the repo to `RELEASE_APP_CLIENT_ID`, `RELEASE_APP_PRIVATE_KEY`,
  `DISPATCH_APP_CLIENT_ID` and `DISPATCH_APP_PRIVATE_KEY` (org → Settings → Secrets and variables →
  Actions → each secret → Repository access). Use the UI: it keeps the value. `gh secret set --repos`
  replaces the whole repository list and needs the value again.

### 6.3 One PR: workflows, release config, code owners
Copy from an app already on the pipeline: `kthaisociety/lucid` (Go API with a Node frontend) or
`kthaisociety/onboarding-service` (Go). All the logic lives in `kthaisociety/workflows` (`v0.2.0`); these
only call it.
- `.github/workflows/pr.yml`: the PR title check and the tests. Adapt the test job to the app.
- `.github/workflows/build.yml`: on `main`, tests, the image, then `deploy-staging`.
- `.github/workflows/release.yml`: release-please, then `deploy-production` when a release is created.
  Its own file: it waits for `build.yml`'s run of the release commit, which can never finish if both are
  in one run.
- If the project name in `deployments` differs from the repo name, pass `project: <name>` to
  `request-deploy.yml`.
- `release-please-config.json`, as in the app you copy from. `release-type`: `go`, `node`, `python`, …
  or `simple`. `include-component-in-tag: false` is required (releases must be tagged `vX.Y.Z`).
  `bootstrap-sha`: the commit on `main` just before this PR, so the first changelog starts there.
- `.release-please-manifest.json`: `{ ".": "0.0.0" }`, or the current version if its `vX.Y.Z` tag exists.
- `.github/CODEOWNERS`: the people who approve releases. Keep it to the people who actually review: every
  code owner is asked to review every PR.

Then the repo settings:
```sh
R=kthaisociety/<repo>
gh api -X PATCH repos/$R -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=COMMIT_MESSAGES
```
Squash-merge the PR. After it, add the ruleset on `main` (now that the check names exist): copy
`kthaisociety/lucid`'s (`gh api repos/kthaisociety/lucid/rulesets`), or ask an infra admin. Never use
GitHub's "Rebase" or "Update branch" buttons on these repos (unsigned commits, merge commits): rebase
locally and force-push instead.

**Done when** the merge's `build` run is green: it pushed `ghcr.io/kthaisociety/<repo>:sha-<7>`, and
`deploy-staging` deployed it (`release.yaml`'s `staging:` line now names it). Check the image is public,
logged out:
```sh
docker logout ghcr.io; docker pull ghcr.io/kthaisociety/<repo>:sha-<7>
```
If denied: org → Packages → `<repo>` → Package settings → Change visibility → Public, then re-run `build`.

### 6.4 Check staging
- Dokploy: the deploy log has no unresolved `${{vault…}}` reference (a missing key fails the deploy:
  write it, redeploy with the app's **Deploy** button).
- The app log looks right; with inert secrets, expect failures exactly where they're inert.
- Run the one-off commands from the inventory in the app's terminal in Dokploy. The container has the
  built binaries, not the toolchain: `go run` or `npm run` usually doesn't work there.
- Go through a real user flow on the staging host, sign-in included.

From now on every merge to `main` is on staging within minutes.

### 6.5 First release, to production
Production's secrets first (section 5). Then squash-merge any PR with this as the last line of its commit
message:
```
Release-As: 1.0.0
```
release-please opens "release 1.0.0" with `CHANGELOG.md`. A code owner merges it: `release` tags
`v1.0.0`, waits for the release commit's build and staging deploy, tags the image `1.0.0`, and
`deploy-production` deploys it. Don't delete release tags: release-please finds the previous release by
its tag.

Production now runs, with real secrets, but users don't reach it: the real domain still points at the old
app. Give it a **temporary host** to test it like staging: `my-app-next.kthais.com`, a `dnscontrol` record
plus a domain under `production` in `project.yaml` (a PR; merge the DNS first). Then check the deploy log,
the app log (every integration should work), and a real user flow on the temporary host. Sign-in needs
the temporary host's redirect URI on the OAuth client too.

**An app with background work** (1.3) must not run next to the old one: **Stop** production in Dokploy
right after this check, and leave it stopped until the switchover.

Skip this section for a staging-only app.

---

## 7. Switchover

The new app is already running on production (6.5). The switchover moves the data and the traffic.

Before: production released and checked (6.5), the steps below read through, the rollback understood, a
window when the app is least used, and production's domain PR prepared and approved (not merged).

**A staging-only app** does this section on **staging**: copy into staging's database and volumes, and
leave production alone. No merges to `main` until it's done: each one redeploys staging.

### 7.1 Stop both apps
- **Old app:** Dokploy → old project → app: **Auto Deploy off** (otherwise a push rebuilds and restarts
  it), then **Stop**. From here until 7.4 the app is down. Stop its database only after its dump (7.2).
- **New app:** Dokploy → `my-app` → `production` → app: **Stop** (if it isn't already). Its database
  keeps running.

### 7.2 Copy the data
The new app has already run against its database and volumes (migrations, maybe first records), so
**empty them first**, then copy.

Empty the new database **[untested]**:
```sh
NEW_DB=$(sudo docker ps -q --filter name=my-app-production-postgres)
sudo docker exec "$NEW_DB" psql -U my_app -d my_app -c 'drop schema public cascade; create schema public;'
```
Empty a new volume: `sudo docker run --rm -v my-app-production-<name>:/to alpine find /to -mindepth 1 -delete`.

**Postgres in the old Dokploy project**, on the host:
```sh
OLD_DB=$(sudo docker ps -q --filter name=<old postgres appName>)
NEW_DB=$(sudo docker ps -q --filter name=my-app-production-postgres)   # its database and user: my_app
sudo docker exec "$OLD_DB" pg_dump -U <old user> -d <old db> -Fc -f /tmp/app.dump
sudo docker cp "$OLD_DB":/tmp/app.dump /tmp/app.dump
sudo docker cp /tmp/app.dump "$NEW_DB":/tmp/app.dump
sudo docker exec "$NEW_DB" pg_restore -U my_app -d my_app --no-owner --no-privileges --single-transaction /tmp/app.dump
# check: row counts of the main tables match on both sides
sudo docker exec "$OLD_DB" psql -U <old user> -d <old db> -c "select count(*) from <table>"
sudo docker exec "$NEW_DB" psql -U my_app -d my_app -c "select count(*) from <table>"
sudo rm /tmp/app.dump; sudo docker exec "$OLD_DB" rm /tmp/app.dump; sudo docker exec "$NEW_DB" rm /tmp/app.dump
```
- **Restore into an empty database** (emptied above). The app's migrations run after, when it starts,
  and find the schema already there.
- `--single-transaction`: a failed restore rolls back entirely, so the same command can run again once
  the cause is fixed.
- Same or newer Postgres major version on the new side (17). The dump holds everything: delete it when
  done.

**An external Postgres (Neon, Supabase, …)** **[untested]**: dump with a throwaway `postgres:17-alpine`
container, so its `pg_dump` matches our version (the source must be 17 or older). Use the provider's
**direct** connection string, not a pooled one (on Neon, the host without `-pooler`).
```sh
read -rs SRC_URL      # paste the connection string; it isn't echoed or kept in history
printf '%s\n' "$SRC_URL" | sudo docker run --rm -i -v /tmp:/out postgres:17-alpine \
  sh -c 'read -r SRC_URL; pg_dump "$SRC_URL" -Fc --no-owner --no-privileges -f /out/app.dump'
NEW_DB=$(sudo docker ps -q --filter name=my-app-production-postgres)
sudo docker cp /tmp/app.dump "$NEW_DB":/tmp/app.dump
sudo docker exec "$NEW_DB" pg_restore -U my_app -d my_app --no-owner --no-privileges --single-transaction /tmp/app.dump
```
Compare row counts as above (pipe `$SRC_URL` into the same throwaway image and run `psql "$SRC_URL"`).
Then `unset SRC_URL` and delete the dump. If objects the provider installs (Neon's `neon` schema) make the
restore fail, leave them out:
```sh
sudo docker exec "$NEW_DB" pg_restore -l /tmp/app.dump > /tmp/app.list
# delete the provider's lines from /tmp/app.list, keep everything else
sudo docker cp /tmp/app.list "$NEW_DB":/tmp/app.list
sudo docker exec "$NEW_DB" pg_restore -U my_app -d my_app --no-owner --no-privileges --single-transaction -L /tmp/app.list /tmp/app.dump
```
Keep the external database until section 8: it's the rollback.

**Files on a volume** (SQLite, uploads), on the host:
```sh
OLD=<old volume>; NEW=my-app-production-<name>; UID_=<uid the app runs as, from its Dockerfile>
sudo docker volume inspect "$OLD" --format '{{.Name}}' || { echo "no source volume: stop"; exit 1; }
sudo docker run --rm -v "$OLD":/from:ro -v "$NEW":/to alpine sh -c "set -e
  [ -n \"\$(ls -A /from)\" ] || { echo 'source is empty: stop'; exit 1; }
  [ -z \"\$(ls -A /to)\" ]   || { echo 'destination is not empty: stop'; exit 1; }
  cp -a /from/. /to/
  diff -r /from /to
  chown -R $UID_:$UID_ /to
  ls -lnR /to"
```
The source must exist by that exact name (`docker run -v` would create it empty), the destination must be
empty (emptied above), `diff -r` must print nothing, and the `chown` lets the non-root app write there.

**Redis:** usually a cache or queue that refills: start empty. If it holds data that must survive,
`redis-cli SAVE` in the old one and copy its `dump.rdb` like a volume, before the new Redis starts.

### 7.3 Start the new app
Dokploy → the new app → **Deploy** (it starts the same image; nothing in `deployments` changes).

Check: the app log (migrations ran cleanly on the copied data), the data (a record you know exists, a
count that matches), and the one-off commands the copied data doesn't already cover (never seed data on
production).

### 7.4 Switch the traffic
- **Public apps:** remove the domain from the **old** app in the Dokploy UI first, then merge the
  domain PR (it applies). Never both at once. DNS doesn't change (same host). If the browser shows a
  certificate error, give Let's Encrypt a minute.
- **Internal apps:** in each caller from 1.4, point its URL at `http://<new production app name>:<port>`
  (Dokploy shows `my-app-production-<6 random>`), redeploy it. A caller managed in `deployments` changes
  in its `project.yaml` (a PR).
- New values of shared secrets reach the other apps holding them now.
- Check end to end through a real user flow.

### Rollback (until section 8)
Point the callers back at the old app, or revert the domain PR and add the domain back to the old app (in
that order), then start the old app. Data written to the new app since 7.4 isn't in the old one: copy it
back the same way, or accept the loss if nothing was written.

---

## 8. After

**The same day:** tell the app's maintainers how it works now. Config changes are PRs to `project.yaml`
in `deployments`; secrets are in OpenBao; merging to `main` deploys staging, merging the release PR
deploys production; the Dokploy UI is read-only for this app (the next apply overwrites edits). Delete
branches the pipeline doesn't deploy (`dev`).

**A week later**, after checking the new app ran fine all week:
- Remove the temporary host's DNS record (its Dokploy domain went with the domain PR).
- Delete the old Dokploy project, then its volumes and databases on the host
  (`sudo docker volume rm <old volume>`), and an external database at its provider.
- Revoke every old secret where it was issued: API keys, bot tokens, OAuth client secrets, the external
  database's credentials.
- Update this guide if the app needed something new.

---

## 9. Checklist

```
[ ] 1    inventory: config, env names, secrets and where they're issued, build-time env, volumes,
         databases, domains, sign-in, callers, one-off commands, background work, branches
[ ] 2    production or staging only, staging secrets, build-time env fixed, domains, version, window
[ ] 3    infrastructure: projects.yaml line merged and applied
[ ] 4    deployments: project.yaml (every secret name), release.yaml (nulls), deploy.yml option;
         merged, idle apps and databases in Dokploy; staging DNS
[ ] 5    new staging secrets in OpenBao (none copied), checked by length
[ ] 6.1  repo public, history scanned
[ ] 6.2  kthais-release installed; repo added to RELEASE_APP_* and DISPATCH_APP_* secrets
[ ] 6.3  workflows, release-please, CODEOWNERS, repo settings; merged: image public, staging deployed;
         ruleset
[ ] 6.4  staging checked, one-off commands run
[ ] 6.5  production secrets; first release; checked on a temporary host (stopped if background work)
[ ] 7    real domain PR approved, not merged
[ ] 7.1  old app: auto-deploy off, stopped; new app stopped
[ ] 7.2  new database and volumes emptied; data copied; row counts / diff match
[ ] 7.3  new app started, data checked
[ ] 7.4  domain moved / callers switched; end-to-end check
[ ] 8    maintainers told; a week later: old project and data deleted, old secrets revoked
```
