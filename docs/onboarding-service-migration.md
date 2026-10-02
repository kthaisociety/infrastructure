# Moving onboarding-service to the delivery pipeline

_2026-10-02. The first app moved: rebuilt as a new, OpenTofu-managed Dokploy project from
`kthaisociety/deployments`, running images built by its own repo, next to the old UI-managed app; the
SQLite database is copied over; the two callers are pointed at the new app; the old one is stopped, then
deleted a week later. General steps for any app: [app-delivery.md](app-delivery.md)._

## The old app (read 2026-10-02 through Dokploy's API, secret values not read)

| | |
|---|---|
| Dokploy project / app | `onboarding` / `service`, internal name `onboarding-service-4djevd` |
| Source | Dokploy's GitHub App, `kthaisociety/onboarding-service` `main`, Dockerfile, auto-deploy on push |
| Data | volume `onboarding-service-data` on `/data` (SQLite), no volume backup |
| Domain | none: internal only, port 8000 |
| Callers | `kthais-backend` and `kthais-frontend`: `ONBOARDING_SERVICE_URL=http://onboarding-service-4djevd:8000` |
| Env (not secret) | `BACKEND_URL`, `PORTAL_BASE_URL`, `MATTERMOST_URL`, `GOOGLE_ADMIN_IMPERSONATE_AS`, `GIN_MODE` |
| Secrets | `MATTERMOST_BOT_TOKEN`, `GOOGLE_ADMIN_SERVICE_ACCOUNT_JSON` (base64 env var), `ONBOARDING_SERVICE_SECRET` |

The database holds the onboarding history and the admin-edited email settings (intro texts, contract,
bylaws and Luma URLs), so it's copied rather than started fresh. The service has no background jobs:
it only acts when called, so a second copy that nobody calls does nothing.

## The new app

| | |
|---|---|
| Repo pipeline | onboarding-service#9: `pr.yml` (title, `go vet`, `go test -race`), `build.yml` (`sha-<7>` images), `release.yml` (release-please, `kthais-release`), `CODEOWNERS` `@kthaisociety/it-team` |
| Image | `ghcr.io/kthaisociety/onboarding-service`, public (the repo is public). First image: `sha-3b6e8e5@sha256:d3370c24f6e2051a0ea594e31f7bd36d17565399580ebf184024ceed8869c002` |
| OpenBao side | `infrastructure` `terraform/openbao/projects.yaml`: `onboarding-service` with `shared: [onboarding-service-secret]` (#17) |
| Dokploy side | `deployments` `projects/onboarding-service/` (deployments#1): project `onboarding-service`, `staging` and `production`, vault providers `onboarding-service-<env>` |
| Volumes | `onboarding-service-staging-data`, `onboarding-service-production-data` on `/data` |
| Internal names | `onboarding-service-<env>-<6 random>`, shown in `deployments`' apply output and in Dokploy |

No name clashes with the old app: different project, providers, app names and volumes (checked 2026-10-02).

## Steps

### 1. OpenBao side — done (#17, 2026-10-02)
Policies `dokploy-project-onboarding-service-{staging,production}`, empty paths for both environments and
for the shared secret.

### 2. Secrets — done (2026-10-02)
- **Production:** copied from the old app's env: `MATTERMOST_BOT_TOKEN`, `GOOGLE_ADMIN_SERVICE_ACCOUNT_JSON`
  at `secret/onboarding-service/production`; `ONBOARDING_SERVICE_SECRET` at
  `secret/shared/onboarding-service-secret/production` (shared with landingpage-backend).
- **Staging, inert**, so a second instance can't touch real Google or Mattermost accounts:
  ```sh
  # Fake service account: the JSON shape googleworkspace.NewClient parses at boot (checked by running it,
  # 2026-10-02), with no real key: any call to Google fails.
  python3 -c 'import json,base64; print(base64.b64encode(json.dumps({"type":"service_account","project_id":"kthais-staging-inert","private_key_id":"inert","private_key":"-----BEGIN PRIVATE KEY-----\ninert-not-a-key\n-----END PRIVATE KEY-----\n","client_email":"staging-inert@invalid.example","client_id":"0","token_uri":"https://oauth2.googleapis.com/token"}).encode()).decode(), end="")' \
    | bao kv put -mount=secret onboarding-service/staging GOOGLE_ADMIN_SERVICE_ACCOUNT_JSON=-
  printf 'staging-inert-not-a-token' | bao kv patch -mount=secret onboarding-service/staging MATTERMOST_BOT_TOKEN=-
  # Its own shared secret: staging and production can't call each other.
  printf '%s' "$(openssl rand -base64 32)" | bao kv put -mount=secret shared/onboarding-service-secret/staging ONBOARDING_SERVICE_SECRET=-
  ```
  Lengths after: 404, 25, 44.

### 3. Dokploy side — done (deployments#1, 2026-10-02)
The first apply stopped at the vault providers: the `Deployments CI` user was a member, which can't
create them; made an admin, re-run, done.
Merge: project, environments, provider tokens, vault providers (connection tested), and both apps with
their `/data` mounts, not deployed (placeholder image). Check in Dokploy: project `onboarding-service`
with `staging` and `production`, an app in each (idle), and both providers under Settings → Secrets.

### 4. Staging — done (deployments#2, 2026-10-02)
Deployed by itself on merge (placeholder → image, no Deploy click), pulled from GHCR with no
credentials, references resolved, running. PR to `deployments`:
```yaml
staging: ghcr.io/kthaisociety/onboarding-service:sha-3b6e8e5@sha256:d3370c24f6e2051a0ea594e31f7bd36d17565399580ebf184024ceed8869c002
```
Merge. Check:
- the deploy succeeds (every reference resolved);
- the log: `startup check: backend at …/health reachable`, a Mattermost failure (expected, dummy token),
  `onboarding-service listening on :8000`;
- `sudo docker run --rm --network dokploy-network alpine wget -qO- http://<staging app name>:8000/health`
  → `{"service":"onboarding-service","status":"healthy"}`.

Nothing calls staging: it stays idle.

### 5. First release
Squash-merge a PR in onboarding-service with `Release-As: 1.0.0` in the commit message (onboarding-service
has no README: adding one is a good candidate). A code owner merges the release PR: `v1.0.0`, its GitHub
Release, and `1.0.0` on the release commit's digest.

### 6. Production: copy the database, then deploy
On the host, in this order:
```sh
# 1. Stop the old app (Dokploy → onboarding → service → Stop), so nothing writes while copying. Also turn
#    off its auto-deploy, or a push would start it again.
# 2. Copy the database into the new app's volume, owned by the app's user (uid 10001, its Dockerfile):
# The source must exist by that exact name: `docker run -v` would otherwise create it, empty, and the
# copy would "succeed" with nothing in it.
sudo docker volume inspect onboarding-service-data --format '{{.Name}} {{.Mountpoint}}' || { echo "no source volume: stop"; exit 1; }
sudo docker run --rm \
  -v onboarding-service-data:/from:ro \
  -v onboarding-service-production-data:/to \
  alpine sh -c 'set -e
    test -s /from/onboarding.db || { echo "no onboarding.db in the source: stop"; exit 1; }
    cp -a /from/. /to/
    chown -R 10001:10001 /to
    cmp /from/onboarding.db /to/onboarding.db
    ls -ln /to'
```
It must end listing `onboarding.db` owned by `10001 10001`, with no "stop" and no `cmp` difference.
SQLite needs to write in `/data` itself (journal files), hence the `chown` of the directory, not only the
file. The `docker run` creates `onboarding-service-production-data`, which the new app's mount then uses.

Then a PR to `deployments`:
```yaml
production: ghcr.io/kthaisociety/onboarding-service:1.0.0@sha256:<digest of 1.0.0>
```
Merge: the production app switches to that image and deploys, with the volume (attached since step 3)
holding the copied database. Check its log and `/health` as in
step 4 (Mattermost reachable this time).

### 7. Switch the callers
In the Dokploy UI (both are still UI-managed): `kthais-backend` → backend and `kthais-frontend` → frontend,
Environment:
```
ONBOARDING_SERVICE_URL=http://<production app name>:8000
```
Save, redeploy each. Check: the admin page's onboarding records list shows the old records (the copied
database is in use).

Downtime: from stopping the old app (6.1) to the callers' redeploy (7), a few minutes. Nothing writes in
between recruitment rounds.

### 8. A week later
Delete the old `onboarding` project in Dokploy, then its volume (`sudo docker volume rm
onboarding-service-data`).

## Rollback (until step 8)
Point `ONBOARDING_SERVICE_URL` back to `http://onboarding-service-4djevd:8000` in the backend and frontend,
redeploy them, start the old app. Anything written to the new database after step 7 isn't in the old one.

## Not covered yet
- **Backups of `/data`.** The old app had none either. Needs a GleSYS backup destination and
  `dokploy_volume_backup` support in `modules/project`.
- **landingpage-backend** still has its own plain `ONBOARDING_SERVICE_SECRET`; it reads the shared path
  once it moves.
