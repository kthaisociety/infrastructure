variable "state_passphrase" {
  description = "Passphrase for OpenTofu state and plan encryption. Set via TF_VAR_state_passphrase."
  type        = string
  sensitive   = true
}

variable "openbao_initialized" {
  description = "Set after OpenBao is initialized by hand (runbook Part B). Until then it's off dokploy-network."
  type        = bool
  default     = true
}

variable "openbao_public" {
  description = "Route bao.kthais.com to OpenBao. Needs openbao_initialized."
  type        = bool
  default     = true
}
