variable "state_passphrase" {
  description = "Passphrase for OpenTofu state and plan encryption. Set via TF_VAR_state_passphrase."
  type        = string
  sensitive   = true
}

variable "org_id" {
  description = "The kthais.com Google Cloud organization."
  type        = string
  default     = "914442966401"
}

# The next three are written only at the top of .github/workflows/tofu.yml, which signs in with them and
# passes them here.

variable "provisioner_project" {
  description = "ID of the hand-made project CI signs in through. From GCP_PROVISIONER_PROJECT."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.provisioner_project))
    error_message = "Not a Google Cloud project ID: 6 to 30 lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "plan_account" {
  description = "Name of the read-only service account in that project that CI plans as. From GCP_PLAN_ACCOUNT."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.plan_account))
    error_message = "Not a service account name: 6 to 30 lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "apply_account" {
  description = "Name of the service account in that project that CI applies as. From GCP_APPLY_ACCOUNT."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.apply_account))
    error_message = "Not a service account name: 6 to 30 lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "billing_account" {
  description = "KTHAIS's central billing account, linked to every project here. Null until it exists: nothing here costs money (docs/gcp.md, \"Billing\")."
  type        = string
  default     = null
}
