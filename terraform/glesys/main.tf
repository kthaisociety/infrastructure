# GleSYS object storage. Credentials have full access to their whole instance, so each consumer gets
# its own instance: a leaked key for one can't touch the others.
#
# Buckets and consumers' credentials aren't managed here unless noted: buckets aren't in the GleSYS
# API, and existing credentials can't be imported.
#
# Every instance is prevent_destroy: they hold state, backups and live data.

# --- State -------------------------------------------------------------------

# Created by hand together with the kthais-tfstate bucket and CI's credential. CI's credential stays
# hand-made: OpenTofu managing the key it runs with would be circular. Rotate it by hand.
resource "glesys_objectstorage_instance" "tfstate" {
  datacenter  = var.datacenter
  description = "kthais-tfstates"

  lifecycle {
    prevent_destroy = true
  }
}

# kthaisociety/deployments' state, apart from this repo's: GleSYS credentials cover a whole instance, so
# sharing kthais-tfstate would let deployments' CI read and overwrite infrastructure's state. Its bucket
# (kthais-deployments-tfstate) and CI credential are made by hand, like tfstate's, and go straight into
# deployments' environment secrets, never into this state.
resource "glesys_objectstorage_instance" "deployments_tfstate" {
  datacenter  = var.datacenter
  description = "deployments-tfstates"

  lifecycle {
    prevent_destroy = true
  }
}

# --- OpenBao snapshots -------------------------------------------------------

resource "glesys_objectstorage_instance" "openbao_snapshots" {
  datacenter  = var.datacenter
  description = "openbao-snapshots"

  lifecycle {
    prevent_destroy = true
  }
}

# Used by OpenBao's snapshot sidecar, which also creates its bucket if missing.
resource "glesys_objectstorage_credential" "openbao_snapshots" {
  instanceid  = glesys_objectstorage_instance.openbao_snapshots.id
  description = "openbao snapshot sidecar"
}

# --- Existing app storage ----------------------------------------------------

# Dokploy's backup destination for the website's Postgres.
resource "glesys_objectstorage_instance" "website_psql_backups" {
  datacenter  = var.datacenter
  description = "website-psql-backups"

  lifecycle {
    prevent_destroy = true
  }
}

# Mattermost's own backups.
resource "glesys_objectstorage_instance" "mattermost_backups" {
  datacenter  = var.datacenter
  description = "mattermost-backups"

  lifecycle {
    prevent_destroy = true
  }
}

# Mattermost's live file uploads. Production data, not a backup.
resource "glesys_objectstorage_instance" "mattermost_file_storage" {
  datacenter  = var.datacenter
  description = "mattermost-file-storage"

  lifecycle {
    prevent_destroy = true
  }
}
