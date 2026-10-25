# Database backups

Every production Postgres that `kthaisociety/deployments` creates (`databases: {postgres: {}}` in a
`project.yaml`) is backed up by Dokploy every five days to GleSYS object storage. Nothing to do per
project: the project gets its backup with its database. This page is what's backed up, where, and how
to restore.

| | |
|---|---|
| What | Each project's **production** Postgres: `pg_dump -Fc`, gzipped by Dokploy |
| Not | Staging; Redis; Postgres outside the pipeline (the website's has its own, in `website-psql-backups`) |
| When | Every fifth day at 00:00 UTC (Dokploy's clock): the 1st, 6th, 11th, 16th, 21st, 26th and 31st of each month (`0 0 */5 * *`), unless the project sets its own `schedule` |
| Kept | The last 30 dumps of each database (about five months), unless the project sets its own `keep` |
| Where | GleSYS instance `database-backups`, bucket `kthais-database-backups`, `<app_name>/<timestamp>.sql.gz` |

A project changes when and how many in its `project.yaml`, under `databases.postgres.backups`
(`deployments`' `docs/project-yaml.md`). It can't turn backups off.

`<app_name>` is the database's internal name in Dokploy, e.g. `lucid-production-postgres-ioh0hk`: its
**Internal Host** (General tab, Internal Credentials), or `deployments`' tofu output
`projects.<project>.apps.production.postgres`. The file is
`pg_dump`'s custom format, gzipped: `gunzip` gives a file for `pg_restore`, not plain SQL.

## How it's built

| Where | What |
|---|---|
| `terraform/glesys/main.tf` | The `database-backups` instance and the credential Dokploy uses |
| `terraform/dokploy/core.tf` | Dokploy's destination `database-backups`: the bucket, with that credential |
| `deployments`: `terraform/modules/project/databases.tf` | Per production Postgres, a backup to the destination it looks up by name, with the default schedule and retention, or the project's |

The bucket is made by hand: buckets aren't in the GleSYS API, and rclone (which Dokploy uploads with)
is told not to create one. On a new instance, make it before the first backup runs: GleSYS UI → Object
Storage → `database-backups` → create bucket `kthais-database-backups`.

After `terraform/dokploy` creates or changes the destination, test it in Dokploy: Settings → S3
Destinations → `database-backups` → **Test Connection**. Not in OpenTofu: the provider can test it at
apply (`verify_connection`), but a failed test's message contains the rclone command, secret key
included, and CI would print it to this public repo's Actions log.

Dokploy sends no notification when a backup fails yet (no notification channel is set up in Dokploy).
Check the Backups tab after a change.

## Check that they run

In Dokploy: the project → **production** → its Postgres → **Backups**. The backup is listed with its
schedule; **Run Manual Backup** takes one now. The dumps themselves: below,
`s3 lsf`.

## Restore

Pick the dump first: they're named by time (UTC), newest last. A restore replaces what the dump holds:
every table in it is dropped and recreated from it. **Stop the app first** (Dokploy: the app →
production → **Stop**), so nothing writes while it runs, and **Deploy** it again after.

### With Dokploy (the database still exists there)

The project → **production** → its Postgres → **Backups** → **Restore Backup**:
- Destination: `database-backups`.
- **Search Backup Files**: the database's `<app_name>`, then pick the dump.
- Database name: the project name with `_` for `-` (`my_app`).

Dokploy streams the dump from GleSYS into `pg_restore --clean --if-exists` in the database's container.

### Without Dokploy (disaster recovery, or into another database)

On the host. First a GleSYS credential for the `database-backups` instance: in the GleSYS UI, make a
temporary one on that instance (delete it when done), or read Dokploy's from Settings → S3 Destinations
while Dokploy still runs. The helper runs rclone (the version in Dokploy's own image) in a throwaway
container, reading the key from stdin so it's never in a command line or the shell history:

```sh
read -r  S3_KEY       # the credential's access key
read -rs S3_SECRET    # its secret key, not echoed
s3() {
  printf '%s\n%s\n' "$S3_KEY" "$S3_SECRET" | sudo docker run --rm -i -v /tmp:/out --entrypoint sh \
    rclone/rclone:1.75.1 -c '
      read -r RCLONE_S3_ACCESS_KEY_ID; read -r RCLONE_S3_SECRET_ACCESS_KEY
      export RCLONE_S3_ACCESS_KEY_ID RCLONE_S3_SECRET_ACCESS_KEY RCLONE_S3_PROVIDER=Other \
        RCLONE_S3_ENDPOINT=https://objects.dc-sto1.glesys.net RCLONE_S3_REGION=us-east-1 \
        RCLONE_S3_FORCE_PATH_STYLE=true
      rclone --config /dev/null "$@"' s3 "$@"
}
s3 lsf :s3:kthais-database-backups/                 # one folder per database, its <app_name>
s3 lsf :s3:kthais-database-backups/<app_name>/      # its dumps, newest last
s3 copyto :s3:kthais-database-backups/<app_name>/<timestamp>.sql.gz /out/app.sql.gz
sudo gunzip /tmp/app.sql.gz                         # now /tmp/app.sql, for pg_restore
```

Into the project's Postgres (a new one after a rebuild is empty: restore before the app first starts,
so its migrations don't run against an empty schema first):

```sh
DB=$(sudo docker ps -q --filter name=<project>-production-postgres)   # its database and user: my_app
sudo docker cp /tmp/app.sql "$DB":/tmp/app.dump
sudo docker exec "$DB" pg_restore -U my_app -d my_app --no-owner --no-privileges \
  --clean --if-exists --single-transaction /tmp/app.dump
# check: the main tables' row counts are what you expect
sudo docker exec "$DB" psql -U my_app -d my_app -c "select count(*) from <table>"
sudo rm /tmp/app.sql; sudo docker exec "$DB" rm /tmp/app.dump
unset S3_KEY S3_SECRET
```

- **`--single-transaction`**: a failed restore rolls back entirely, leaving the database as it was.
- **To look before replacing**, restore into a side database instead, and drop it after:
  `sudo docker exec "$DB" createdb -U my_app my_app_restore`, then the same `pg_restore` with
  `-d my_app_restore`.
- The dump contains everything in the database: delete it from the host when done.

## Things to know

- A Postgres that Dokploy recreates gets a new `<app_name>`, so its dumps start a new folder. The old
  folder isn't pruned any more: delete it by hand once it's no longer needed.
- Removing a project's Postgres in `deployments` is refused by the plan (`prevent_destroy`), so its
  backups don't stop by accident.
- One project's schedule or retention: its `project.yaml`. The defaults for every project:
  `databases.tf` in `deployments`.

**Tested** on 2026-10-25, against a local copy of the platform (rclone's S3 server standing in for
GleSYS): Test Connection, a scheduled run and a manual one, retention, a restore with Dokploy after
dropping a table, and the manual restore into a new, empty Postgres. Both restores gave back every row.
