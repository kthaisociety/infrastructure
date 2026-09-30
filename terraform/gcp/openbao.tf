# GCP side of OpenBao: the KMS key it auto-unseals with, and the bucket its
# Raft snapshots are backed up to. Service account keys are created by hand
# (see docs/bootstrap.md) so they never end up in Terraform state.

# --- Auto-unseal -------------------------------------------------------------

resource "google_kms_key_ring" "openbao" {
  name     = "openbao"
  location = var.region
}

resource "google_kms_crypto_key" "openbao_unseal" {
  name            = "unseal"
  key_ring        = google_kms_key_ring.openbao.id
  rotation_period = "7776000s" # 90 days; old versions stay usable for decryption

  lifecycle {
    # Destroying this key makes every OpenBao snapshot unrecoverable.
    prevent_destroy = true
  }
}

resource "google_service_account" "openbao_unseal" {
  account_id   = "openbao-unseal"
  display_name = "OpenBao auto-unseal (KMS)"
}

resource "google_kms_crypto_key_iam_member" "openbao_unseal" {
  for_each = toset([
    "roles/cloudkms.cryptoKeyEncrypterDecrypter",
    "roles/cloudkms.viewer", # the seal reads key metadata on startup
  ])

  crypto_key_id = google_kms_crypto_key.openbao_unseal.id
  role          = each.value
  member        = google_service_account.openbao_unseal.member
}

# --- Snapshots ---------------------------------------------------------------

resource "google_storage_bucket" "openbao_snapshots" {
  name                        = "${var.project_id}-openbao-snapshots"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Write-only: a leaked backup key can add snapshots but not read or delete them.
resource "google_service_account" "openbao_backup" {
  account_id   = "openbao-backup"
  display_name = "OpenBao snapshot uploader"
}

resource "google_storage_bucket_iam_member" "openbao_backup" {
  bucket = google_storage_bucket.openbao_snapshots.name
  role   = "roles/storage.objectCreator"
  member = google_service_account.openbao_backup.member
}
