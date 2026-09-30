variable "org_id" {
  description = "kthais.com Google Cloud organization ID."
  type        = string
  default     = "914442966401"
}

variable "billing_account" {
  description = "Billing account for the infrastructure project (KMS and Cloud Storage need billing)."
  type        = string
}

variable "project_id" {
  type    = string
  default = "kthais-infrastructure"
}

variable "region" {
  type    = string
  default = "europe-north1"
}

variable "github_org" {
  type    = string
  default = "kthaisociety"
}

variable "github_org_id" {
  description = "Numeric GitHub org ID. Immutable, unlike the org name."
  type        = string
  default     = "57193069"
}

variable "github_repo" {
  type    = string
  default = "infrastructure"
}

variable "apply_environment" {
  description = "GitHub Actions environment whose jobs may impersonate the apply service account."
  type        = string
  default     = "production"
}
