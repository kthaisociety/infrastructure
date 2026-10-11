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

variable "billing_account" {
  description = "KTHAIS's central billing account, linked to every project here. Null until it exists: nothing here costs money (docs/gcp.md, \"Billing\")."
  type        = string
  default     = null
}
