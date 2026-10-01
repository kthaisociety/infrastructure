variable "state_passphrase" {
  description = "Passphrase for OpenTofu state and plan encryption. Set via TF_VAR_state_passphrase."
  type        = string
  sensitive   = true
}

variable "openbao_public" {
  description = "Route bao.kthais.com to OpenBao. Stays false until OpenBao is initialized by hand."
  type        = bool
  default     = false
}
