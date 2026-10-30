# Object storage for apps (IT-39): every project with `storage` in terraform/openbao/projects.yaml gets,
# per environment, its own instance, a credential for the app and its buckets. One instance per project
# and environment, since a credential reaches every bucket of its instance: staging's key can't
# touch production's files. terraform/openbao (storage.tf) writes the app's credential to
# secret/<project>/<env>/storage, where the app reads it.
#
# Buckets aren't in the GleSYS API, so the MinIO provider creates them through the S3 API: one provider
# configuration per instance, with a credential of OpenTofu's own. Not the app's, which would leave the
# provider without a key while the app's is being replaced. Not the instance's default one either: the
# GleSYS provider (0.18.0) refreshes the instance's accesskey from whichever credential the API lists
# first, keeping the old secretkey (tested 2026-10-30; glesys/terraform-provider-glesys#293). Once that's
# fixed, the instance's own credential could replace OpenTofu's. Bucket names are global across all of
# GleSYS (tested 2026-10-29: `test` and `uploads` are taken), hence kthais-<project>-<env>[-<bucket>].
#
# prevent_destroy on the instance and the buckets: they hold an app's live files. Removing `storage` from
# a project, or a bucket from its list, fails the plan, and so would dropping an instance's provider
# configuration while its buckets are still in state. Removing either is a deliberate PR of its own, with
# `removed` blocks. Adding a bucket to the list is just that.

locals {
  projects = yamldecode(file("${path.module}/../openbao/projects.yaml"))

  # "<project>/<env>" => its instance's name and its buckets (secret name => bucket name), for every
  # environment of every project with storage. The environments default as in
  # terraform/openbao/projects.tf. `storage: {}` is one bucket, S3_BUCKET; `storage: {buckets: [...]}`
  # one per name, S3_BUCKET_<NAME> (`user-uploads` gives S3_BUCKET_USER_UPLOADS), and no S3_BUCKET.
  storage = merge([
    for p, cfg in local.projects : {
      for env in try(cfg.environments, ["staging", "production"]) : "${p}/${env}" => {
        name = "${p}-${env}"
        buckets = try(cfg.storage.buckets, null) == null ? tomap({ S3_BUCKET = "kthais-${p}-${env}" }) : {
          for b in cfg.storage.buckets : "S3_BUCKET_${upper(replace(b, "-", "_"))}" => "kthais-${p}-${env}-${b}"
        }
      }
    } if try(cfg.storage, null) != null
  ]...)

  # Bucket name => its instance's key in local.storage.
  storage_buckets = merge([for k, s in local.storage : { for b in values(s.buckets) : b => k }]...)

  storage_endpoint = "objects.${var.datacenter}.glesys.net"
}

resource "glesys_objectstorage_instance" "storage" {
  for_each    = local.storage
  datacenter  = var.datacenter
  description = each.value.name

  lifecycle {
    prevent_destroy = true
  }
}

# The app's, in OpenBao. Rotate it by changing the description (it's replaced, and so is the secret).
resource "glesys_objectstorage_credential" "storage" {
  for_each    = local.storage
  instanceid  = glesys_objectstorage_instance.storage[each.key].id
  description = "${each.value.name} app"
}

# OpenTofu's, for the buckets. Never rotated: it's only in this state.
resource "glesys_objectstorage_credential" "storage_buckets" {
  for_each    = local.storage
  instanceid  = glesys_objectstorage_instance.storage[each.key].id
  description = "${each.value.name} buckets (OpenTofu)"
}

# A new credential gets 403 for its first few seconds (1-3 s, measured 2026-10-30), and the bucket is
# created right after it.
resource "time_sleep" "storage_buckets_credential" {
  for_each        = local.storage
  create_duration = "30s"
  triggers = {
    credential = glesys_objectstorage_credential.storage_buckets[each.key].id
  }
}

provider "minio" {
  alias          = "storage"
  for_each       = local.storage
  minio_server   = local.storage_endpoint
  minio_ssl      = true
  minio_region   = "us-east-1" # placeholder; GleSYS ignores it, but request signing needs one
  minio_user     = glesys_objectstorage_credential.storage_buckets[each.key].accesskey
  minio_password = glesys_objectstorage_credential.storage_buckets[each.key].secretkey
}

resource "minio_s3_bucket" "storage" {
  for_each = local.storage_buckets
  provider = minio.storage[each.value]
  bucket   = each.key

  depends_on = [time_sleep.storage_buckets_credential]

  lifecycle {
    prevent_destroy = true

    # S3's rule; the rest of a bucket name's rules hold for any project and environment name.
    precondition {
      condition     = length(each.key) <= 63
      error_message = "Bucket ${each.key} is longer than 63 characters: shorten the project or bucket name."
    }
  }
}
