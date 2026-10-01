variable "state_passphrase" {
  description = "Passphrase for OpenTofu state and plan encryption. Set via TF_VAR_state_passphrase."
  type        = string
  sensitive   = true
}

variable "openbao_initialized" {
  # True since OpenBao was initialized on 2026-10-01. On a fresh host (empty data volume, disaster recovery)
  # apply with -var openbao_initialized=false -var openbao_public=false until it's initialized again:
  # an uninitialized OpenBao on dokploy-network can be initialized by any container there.
  description = "OpenBao has been initialized by hand (runbook Part B). False keeps it off dokploy-network."
  type        = bool
  default     = true
}

variable "openbao_public" {
  description = "Route bao.kthais.com to OpenBao. Needs openbao_initialized."
  type        = bool
  default     = true
}
