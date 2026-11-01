# Database backups

Every production Postgres that `kthaisociety/deployments` creates (`databases: {postgres: {}}` in a
`project.yaml`) is backed up by Dokploy every day to GleSYS object storage. Nothing to do per
project: the project gets its backup with its database. This page is what's backed up, where, and how
to restore.

| | |
|---|---|
| What | Each project's **production** Postgres: `pg_dump -Fc`, gzipped by Dokploy |
| Not | Staging; Redis; Postgres outside the pipeline (the website's has its own, in `website-psql-backups`) |
| When | Every day at 00:00 UTC (Dokploy's clock, `0 0 * * *`), unless the project sets its own `schedule` |
| Kept | The last 30 dumps of each database (a month, at the default schedule), unless the project sets its own `keep` (at least 7) |
| Where | GleSYS instance `database-backups`, bucket `kthais-database-backups`, `<app_name>/<timestamp>.sql.gz` |
| Locked | Each dump for 14 days after it's written (Object Lock, Compliance mode): nobody can delete it before then, us included |

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

### The bucket

Made by hand, once, before the first backup runs: buckets aren't in the GleSYS API, rclone (which
Dokploy uploads with) is told not to create one, and Object Lock can only be turned on when a bucket is
created. It's made with the S3 API, with:

- **Object Lock, Compliance mode, 14 days.** Every dump is locked for 14 days after it's written.
  Nobody can delete it or shorten its lock, not even with a key to the instance, such as the one
  Dokploy holds. So a leaked Dokploy key, or whoever gets the host, can't destroy the last two weeks of
  backups.
- **A lifecycle rule.** Object Lock turns versioning on, so Dokploy's own deletes (`keep`) only hide a
  dump behind a delete marker. The rule removes such a dump once its lock has run out (GleSYS runs
  these rules nightly), the markers left behind, and uploads that never finished.

It needs Docker, and a credential for the `database-backups` instance: in the GleSYS UI, make a
temporary one on that instance, and delete it when done. The key is read from stdin, so it's never on a
command line:

```sh
read -r  S3_KEY       # the credential's access key
read -rs S3_SECRET    # its secret key, not echoed
s3api() {
  printf '%s\n%s\n' "$S3_KEY" "$S3_SECRET" | docker run --rm -i --entrypoint sh \
    amazon/aws-cli:2.38.1 -c '
    read -r AWS_ACCESS_KEY_ID; read -r AWS_SECRET_ACCESS_KEY
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=us-east-1
    aws --endpoint-url https://objects.dc-sto1.glesys.net s3api "$@"' s3api "$@"
}
B=kthais-database-backups
s3api create-bucket --bucket $B --object-lock-enabled-for-bucket
s3api put-object-lock-configuration --bucket $B --object-lock-configuration \
  '{"ObjectLockEnabled": "Enabled", "Rule": {"DefaultRetention": {"Mode": "COMPLIANCE", "Days": 14}}}'
s3api put-bucket-lifecycle-configuration --bucket $B --lifecycle-configuration '{"Rules": [{
  "ID": "dumps-dokploy-deleted", "Status": "Enabled", "Filter": {"Prefix": ""},
  "NoncurrentVersionExpiration": {"NoncurrentDays": 1},
  "Expiration": {"ExpiredObjectDeleteMarker": true},
  "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 1}}]}'
s3api get-object-lock-configuration --bucket $B        # COMPLIANCE, 14 days
s3api get-bucket-lifecycle-configuration --bucket $B   # the rule
unset S3_KEY S3_SECRET
```

The 14 days can be changed later with the same `put-object-lock-configuration`, but only for dumps
written after it: a dump keeps the lock it got.

### The destination

After `terraform/dokploy` creates or changes the destination, test it in Dokploy: Settings → S3
Destinations → `database-backups` → **Test Connection**. Not in OpenTofu: the provider can test it at
apply (`verify_connection`), but a failed test's message contains the rclone command, secret key
included, and CI would print it to this public repo's Actions log.

## When a backup fails

Dokploy emails `ops@`, which only the infra admins read: its email notification has **Database
Backup** on. It sends one for every backup, failed or not. The notification is set up by hand in
Dokploy (Settings → Notifications), not in OpenTofu yet: **after a fresh Dokploy install, set it up
again**, with Database Backup on.

**A failure email contains the destination's secret key.** Dokploy v0.30.8 puts the failed command in
the error it sends, and the command has the key in it. Anyone with that email can read and delete
every dump. A failed **Run Manual Backup** shows the same error on screen. So a failure email means
rotating the credential, whatever failed:

1. In a PR, change `description` in `glesys_objectstorage_credential.database_backups`
   (`terraform/glesys/main.tf`), e.g. add the date. A changed description makes a new credential: on
   merge, `glesys-apply` deletes the old one and creates its replacement, then `dokploy-apply` gives
   the destination the new key.
2. Dokploy: the project → **production** → its Postgres → **Backups** → **Run Manual Backup**, to
   check the new key.
3. Delete the email. Its key no longer works.

Then fix what failed: the email names the project and the database.

v0.30.8 also writes the key to Dokploy's own log (`docker service logs dokploy`) on every backup,
failed or not. Only the host's admins can read that log, and they can read the key in Dokploy anyway.
Dokploy has fixed both on its `canary` branch ([#5733](https://github.com/Dokploy/dokploy/pull/5733),
[#5527](https://github.com/Dokploy/dokploy/pull/5527)), not yet in a release
(v0.30.10 still has them). Once production runs one that has them, a failure email no longer needs a
rotation.

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
- Renaming or deleting the destination stops every project's deploys, not only the backups:
  `deployments` looks `database-backups` up by name in every plan with a production Postgres.
- One project's schedule or retention: its `project.yaml`. The defaults for every project:
  `databases.tf` in `deployments`.
- **A dump deleted within its 14 days isn't gone**, whether Dokploy deleted it or someone with the key
  did. With the `s3api` helper above (`B=kthais-database-backups`),
  `s3api list-object-versions --bucket $B --prefix <app_name>/` shows it under a delete marker, and
  deleting the marker brings it back:
  `s3api delete-object --bucket $B --key <key> --version-id <the marker's VersionId>`.
- Nobody can delete a dump within its 14 days, not even for a GDPR erasure request: those dumps have to
  age out. That was agreed on IT-18.

**Tested** on 2026-10-25, against a local copy of the platform (rclone's S3 server standing in for
GleSYS): Test Connection, a scheduled run and a manual one, retention, a restore with Dokploy after
dropping a table, and the manual restore into a new, empty Postgres. Both restores gave back every row.
On 2026-10-28, the same way: the daily default, and a failed backup's email to a local mail server
standing in for `ops@`. The email had the key in it. On 2026-10-29, on a GleSYS test instance with a
bucket made as above, locked for 1 day:
- The bucket's own key couldn't delete a locked dump, even with `--bypass-governance-retention`, and
  couldn't shorten its lock or switch it to Governance mode.
- The local Dokploy backed up to that bucket with `keep: 2` (11.6 MB dumps, so multipart uploads): every
  dump was locked, and its delete of the oldest left a delete marker. Restoring the newest gave back
  every row. Deleting the marker brought the deleted dump back.
- GleSYS runs the lifecycle rule, checked on 2026-10-31: once their locks had run out, both deleted
  dumps' old versions were gone. Their delete markers were still there at 10:06 UTC, when the test bucket
  was deleted, so whether the rule removes those too isn't confirmed. They take next to no space.
