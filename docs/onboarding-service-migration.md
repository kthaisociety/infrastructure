# Moving onboarding-service to OpenTofu

The first project rebuilt by `terraform/dokploy` instead of the Dokploy UI (plan, "Existing projects are
rebuilt, not imported"). A new Dokploy project runs next to the old one; the SQLite database is copied
over; the two callers are pointed at the new app; the old one is stopped, then deleted a week later.

## What exists today (read 2026-10-02)

| | Old (UI-managed) |
|---|---|
| Dokploy project / app | `onboarding` / `service`, internal name `onboarding-service-4djevd` |
| Source | GitHub App, `kthaisociety/onboarding-service`, branch `main`, Dockerfile, auto-deploy on push |
| Data | volume `onboarding-service-data` on `/data` (SQLite), no volume backup |
| Domain | none; internal only |
| Callers | `kthais-backend` and `kthais-frontend`: `ONBOARDING_SERVICE_URL=http://onboarding-service-4djevd:8000` |
| Secrets | `MATTERMOST_BOT_TOKEN`, `GOOGLE_ADMIN_SERVICE_ACCOUNT_JSON` (base64, env var), `ONBOARDING_SERVICE_SECRET` |

Nothing writes to the database between recruitment rounds, so the copy needs no write freeze. It holds
the onboarding history and the admin-edited email settings (intro texts, contract, bylaws and Luma
URLs), which is why it's copied rather than started fresh.

## What the PR builds

From `terraform/projects/onboarding-service/project.yaml`, through `modules/project`:

- Dokploy project `onboarding-service`, environment `production`.
- Vault provider `onboarding-service-production`, assigned to that environment only, with the token from
  `terraform/openbao`. `verify_connection` fails the apply if Dokploy can't reach OpenBao with it.
- App `onboarding-service`, internal name `onboarding-service-production-<6 random characters>`
  (Dokploy picks the suffix; the `projects` output at the end of `dokploy-apply`'s log, or the app's page, shows it). Same source and build
  as the old one, auto-deploy on push, no `.env` file in the build context.
- Env: the non-secret values as they are, plus references:

  ```
  MATTERMOST_BOT_TOKEN=${{vault.onboarding-service-production.onboarding-service/production:MATTERMOST_BOT_TOKEN}}
  GOOGLE_ADMIN_SERVICE_ACCOUNT_JSON=${{vault.onboarding-service-production.onboarding-service/production:GOOGLE_ADMIN_SERVICE_ACCOUNT_JSON}}
  ONBOARDING_SERVICE_SECRET=${{vault.onboarding-service-production.shared/onboarding-service-secret/production:ONBOARDING_SERVICE_SECRET}}
  ```

- Volume `onboarding-service-production-data` on `/data`.
- **Not deployed** (`deploy: false`): an app deploys on create, before its volume can be attached, so the
  first deploy is by hand once the volume holds the database.
- The `infrastructure-production` vault provider too (for the snapshot compose, runbook E2).

## Steps

### 1. Secrets in OpenBao (done 2026-10-02)

From a laptop, after `bao login -method=oidc role=infra-admin` with `BAO_ADDR=https://bao.kthais.com`.
Values come from the old app's Environment tab, through the clipboard: a paste into the terminal is cut
at 1024 characters, and the service account JSON is 3212.

```sh
pbpaste | tr -d '\n' | bao kv put   -mount=secret onboarding-service/production MATTERMOST_BOT_TOKEN=-
pbpaste | tr -d '\n' | bao kv patch -mount=secret onboarding-service/production GOOGLE_ADMIN_SERVICE_ACCOUNT_JSON=-
pbpaste | tr -d '\n' | bao kv put   -mount=secret shared/onboarding-service-secret/production ONBOARDING_SERVICE_SECRET=-
pbcopy < /dev/null
```

`put` on an empty path, `patch` for every further key on it: a second `put` replaces the whole secret.
`tr -d '\n'` matters: the app base64-decodes the service account JSON, and a trailing newline breaks
that. Check by length, not value:

```sh
bao kv get -mount=secret -format=json onboarding-service/production | jq '.data.data | map_values(length)'
# {"GOOGLE_ADMIN_SERVICE_ACCOUNT_JSON": 3212, "MATTERMOST_BOT_TOKEN": 26}
bao kv get -mount=secret -format=json shared/onboarding-service-secret/production | jq '.data.data | map_values(length)'
# {"ONBOARDING_SERVICE_SECRET": 44}
```

### 2. Merge the PR

`dokploy-apply` creates the project, the vault provider (connection verified), the app and its mount.
Note the new app's internal name from the `projects` output in `dokploy-apply`'s log, or its page in Dokploy. Below it's
`<NEW>`.

### 3. Copy the database into the new volume

On the host. The old app keeps running; nothing writes to it.

```sh
sudo docker volume ls | grep onboarding-service        # onboarding-service-data exists
sudo docker run --rm \
  -v onboarding-service-data:/from:ro \
  -v onboarding-service-production-data:/to \
  alpine sh -c 'cp -a /from/. /to/ && chown -R 10001:10001 /to && ls -ln /to'
```

This creates `onboarding-service-production-data`, which the new app's mount then uses. The `chown`
matters: the app runs as uid 10001 (its Dockerfile), and SQLite needs to write in `/data` itself, not
only to the file. `ls -ln` should show `onboarding.db` owned by `10001 10001`.

### 4. Deploy the new app once

Dokploy → project `onboarding-service` → app → **Deploy**. In the deploy and app logs:

- the deploy succeeds, so every `${{vault…}}` reference resolved (a missing key fails the deploy);
- `startup check: Mattermost at https://chat.aisociety.se reachable`;
- `startup check: backend at …/health reachable (200 OK)`;
- `onboarding-service listening on :8000`.

Then from the host:

```sh
sudo docker run --rm --network dokploy-network alpine wget -qO- http://<NEW>:8000/health
# {"service":"onboarding-service","status":"healthy"}
sudo docker volume ls | grep onboarding-service-production-data   # one volume, the one from step 3
```

Nothing calls the new app yet, and it has no background jobs, so it does nothing until step 5.

### 5. Point the callers at it

In the Dokploy UI, in both `kthais-backend` (backend) and `kthais-frontend` (frontend), Environment:

```
ONBOARDING_SERVICE_URL=http://<NEW>:8000
```

Save and redeploy each. Check: the admin page's onboarding records list (frontend → onboarding-service)
shows the old records, so the copied database is in use.

### 6. Stop the old app

Old project `onboarding` → `service`: turn off auto-deploy (otherwise a push still builds it), then
**Stop**. Keep it, and its volume, for a week as the rollback.

### 7. Turn on deploys

PR: `deploy: true` in `project.yaml`. From then on a config change in this repo redeploys the app.
Changing `deploy` itself may not deploy anything; that's fine, nothing needs it then.

### 8. A week later

Delete the old `onboarding` project in Dokploy, then its volume on the host
(`sudo docker volume rm onboarding-service-data`), after checking the new app still runs on its own.

## Rollback

Until step 8: set `ONBOARDING_SERVICE_URL` back to `http://onboarding-service-4djevd:8000` in the backend
and frontend, redeploy them, and start the old app. Anything written to the new database after step 5 is
not in the old one.

## Not covered yet

- **Backups of `/data`.** The old app had none either. A `dokploy_volume_backup` needs the GleSYS backup
  destination in OpenTofu (plan, Phase 6).
- **landingpage-backend** still has its own plain `ONBOARDING_SERVICE_SECRET`. When it moves, it reads
  `shared/onboarding-service-secret/production` instead, and the value stays in one place.
