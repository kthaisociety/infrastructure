variable "state_passphrase" {
  description = "Passphrase for OpenTofu state and plan encryption. Set via TF_VAR_state_passphrase."
  type        = string
  sensitive   = true
}

variable "openbao_jwt" {
  description = "GitHub Actions OIDC token with audience https://bao.kthais.com. Set by the openbao-apply job."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "openbao_oidc_client_id" {
  description = "Google OAuth client for people's sign-in (GCP project clean-healer-452020-n9). From OPENBAO_OIDC_CLIENT_ID."
  type        = string
}

variable "openbao_oidc_client_secret" {
  description = "That client's secret. From OPENBAO_OIDC_CLIENT_SECRET. Write-only: never in state."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "openbao_admin_emails" {
  description = "kthais.com accounts that can sign in to OpenBao as infra-admin."
  type        = list(string)
  default = [
    "sam@kthais.com",
    "vilhelm@kthais.com",
    "pavlos.spanoudakis@kthais.com",
    "max.astrand@kthais.com",
  ]
}
