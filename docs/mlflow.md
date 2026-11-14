# MLflow

Experiment tracking and model registry for the research team (IT-36), at `https://mlflow.kthais.com`.

| | |
|---|---|
| Runs, metrics, params | Postgres in MLflow's compose, backed up daily ([database-backups.md](database-backups.md)) |
| Artifacts (files, models) | GleSYS instance and bucket `kthais-mlflow-production`, through the server. **Not backed up** |
| Code | [`terraform/dokploy/mlflow.tf`](../terraform/dokploy/mlflow.tf), `mlflow` in [`terraform/openbao/projects.yaml`](../terraform/openbao/projects.yaml) |

It runs here as a Dokploy compose, like OpenBao, not through `kthaisociety/deployments`: we don't build or
release MLflow. Production only.

**No sign-in.** Anyone who can reach the address can read, write and delete runs and artifacts. Never log
credentials or data that mustn't be public. A sign-in comes later.

## For researchers

```sh
pip install mlflow
export MLFLOW_TRACKING_URI=https://mlflow.kthais.com
```

```python
import mlflow

mlflow.set_experiment("my-experiment")
with mlflow.start_run():
    mlflow.log_param("lr", 0.001)
    mlflow.log_metric("loss", 0.42)
    mlflow.log_artifact("model.pt")
```

## Setting it up

1. **`dnscontrol`**: `mlflow` pointing at the Synapse host, like `bao`. Merge it first, so Let's Encrypt
   can issue the certificate.
2. **This repo**: merge the PR. The apply runs glesys (instance, bucket, credential), then openbao
   (`secret/mlflow/production/storage`, the `mlflow-production` policy and token), then dokploy (the
   project, vault provider, compose and backup).
3. Check:
   - Dokploy → `mlflow` → the compose's logs: `postgres` ready, then `mlflow` creating its tables and
     starting.
   - `https://mlflow.kthais.com` shows the UI; `http://` redirects.
   - The snippet above, from a laptop: the run and its artifact show in the UI, and the artifact is in the
     bucket.
   - The compose → Backups → **Run Manual Backup**: a dump arrives in
     `kthais-database-backups/<app_name>_postgres/`.

## Upgrading

The images are pinned in `terraform/dokploy/mlflow.tf`. MLflow migrates its database on start, and rolling
the image back doesn't undo that. So, for an MLflow bump:

1. The compose → Backups → **Run Manual Backup**, and check the dump arrived.
2. Merge the bump. The logs show the migration, then the server.
3. If it fails: restore that dump (below) and go back to the previous image.

Postgres follows `17-alpine`. A new major version needs a dump and restore, not a bump.

## Restoring the database

As in [database-backups.md](database-backups.md#without-dokploy-disaster-recovery-or-into-another-database),
with MLflow's names: the database and user are both `mlflow`. `<app_name>` is the compose's App Name
(Dokploy → the compose → General). Stop `mlflow` first, so nothing writes:

```sh
sudo docker stop $(sudo docker ps -q --filter label=com.docker.compose.project=<app_name> --filter label=com.docker.compose.service=mlflow)
DB=$(sudo docker ps -q --filter label=com.docker.compose.project=<app_name> --filter label=com.docker.compose.service=postgres)
sudo docker cp /tmp/app.sql "$DB":/tmp/app.dump
sudo docker exec "$DB" pg_restore -U mlflow -d mlflow --no-owner --no-privileges \
  --clean --if-exists --single-transaction /tmp/app.dump
```

Then Deploy the compose again.

## Things to know

- **Deleting or replacing the compose deletes the database.** Dokploy removes a compose's volumes with it.
  `prevent_destroy` makes the plan refuse; never work around it without a fresh dump.
- **Postgres has no password.** It's on the compose's own network only, where just `mlflow` can reach it.
  Keep it off `dokploy-network`.
- **Artifacts are never expired.** Deleting a run in MLflow only marks it deleted; `mlflow gc` removes it
  and its artifacts.
- **Changing the bucket's credential needs a Deploy** of the compose: Dokploy reads OpenBao only when it
  deploys.
