# Apps' object storage (IT-39): terraform/glesys (storage.tf) makes an instance, a credential and a bucket
# per environment of every project with `storage: true` in projects.yaml. This writes each to
# secret/<project>/<env>/storage, under the names the app lists in its project.yaml's secrets. Its own
# path, not secret/<project>/<env>: a KV v2 write replaces the whole secret, so writing there would wipe
# what people filled in. The project's policy reads it (modules/project-secrets); people only read it
# (main.tf), since a hand edit would cut the app off from its bucket until the credential changes.

locals {
  # "<project>/<env>" => its storage, from terraform/glesys's output (snapshots.tf reads that state).
  # glesys-apply runs before this root, so a project that just asked for storage is already there.
  storage = {
    for k, s in data.terraform_remote_state.glesys.outputs.storage : k => jsonencode({
      S3_ACCESS_KEY_ID     = s.access_key
      S3_SECRET_ACCESS_KEY = s.secret_key
      S3_ENDPOINT          = s.endpoint
      S3_REGION            = s.region
      S3_BUCKET            = s.bucket
    })
  }

  # For main.tf's infra-admin policy: read-only, like the database paths.
  storage_paths = flatten([
    for p, cfg in local.projects : [
      for env in try(cfg.environments, ["staging", "production"]) : "${p}/${env}/storage"
    ] if try(cfg.storage, false) == true
  ])
}

resource "vault_kv_secret_v2" "storage" {
  for_each     = local.storage
  mount        = vault_mount.secret.path
  name         = "${each.key}/storage"
  data_json_wo = each.value
  # A new version whenever a value changes (a replaced credential), without the values in this state.
  data_json_wo_version = parseint(substr(sha256(each.value), 0, 8), 16)

  # Like modules/project-secrets' path: removing storage from a project mustn't delete the credential
  # its app still runs with. terraform/glesys refuses to remove the storage itself anyway.
  lifecycle {
    prevent_destroy = true
  }
}
