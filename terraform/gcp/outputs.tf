output "openbao_unseal_key" {
  value = google_kms_crypto_key.openbao_unseal.id
}

output "openbao_unseal_sa" {
  value = google_service_account.openbao_unseal.email
}

output "openbao_backup_sa" {
  value = google_service_account.openbao_backup.email
}

output "openbao_snapshot_bucket" {
  value = google_storage_bucket.openbao_snapshots.name
}
