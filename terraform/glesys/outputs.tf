# Read by other root modules through terraform_remote_state, never printed in CI.

output "openbao_snapshots" {
  value = {
    access_key = glesys_objectstorage_credential.openbao_snapshots.accesskey
    secret_key = glesys_objectstorage_credential.openbao_snapshots.secretkey
  }
  sensitive = true
}
