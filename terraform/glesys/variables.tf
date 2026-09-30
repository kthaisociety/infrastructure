variable "state_passphrase" {
  description = "Passphrase for OpenTofu state and plan encryption. Set via TF_VAR_state_passphrase."
  type        = string
  sensitive   = true
}

variable "datacenter" {
  description = "GleSYS datacenter for object storage instances."
  type        = string
  default     = "dc-sto1"
}
