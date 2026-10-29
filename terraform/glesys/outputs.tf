# Read by other root modules through terraform_remote_state, never printed in CI.

output "openbao_snapshots" {
  value = {
    access_key = glesys_objectstorage_credential.openbao_snapshots.accesskey
    secret_key = glesys_objectstorage_credential.openbao_snapshots.secretkey
  }
  sensitive = true
}

output "storage" {
  description = "Per \"<project>/<env>\" with storage: everything its app needs to reach its bucket. terraform/openbao writes it to secret/<project>/<env>/storage."
  value = {
    for k, s in local.storage : k => {
      access_key = glesys_objectstorage_credential.storage[k].accesskey
      secret_key = glesys_objectstorage_credential.storage[k].secretkey
      endpoint   = "https://${local.storage_endpoint}"
      region     = "us-east-1"
      bucket     = minio_s3_bucket.storage[k].bucket
    }
  }
  sensitive = true
}

output "database_backups" {
  value = {
    access_key = glesys_objectstorage_credential.database_backups.accesskey
    secret_key = glesys_objectstorage_credential.database_backups.secretkey
  }
  sensitive = true
}
