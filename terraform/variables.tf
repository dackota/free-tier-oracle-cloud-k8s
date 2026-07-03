# region is required with no default (R7): it must be set at apply time to
# the tenancy's home region, and there is no safe cross-tenancy default.
variable "region" {
  description = "OCI region to deploy into, e.g. \"us-ashburn-1\" — set at apply time to the tenancy's home region. No default: it cannot be safely guessed across tenancies."
  type        = string
}

# Provider authentication (R6): the OCI provider authenticates via the
# tenancy OCID plus an API signing key (user OCID, fingerprint, private key).
# All four are supplied via variables/environment — never a literal value in
# committed HCL. See terraform.tfvars.example and README.md.
variable "tenancy_ocid" {
  description = "OCID of the OCI tenancy the provider authenticates against."
  type        = string
}

variable "user_ocid" {
  description = "OCID of the OCI user whose API signing key is used for provider authentication."
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint of the OCI API signing key configured for var.user_ocid."
  type        = string
  sensitive   = true
}

variable "private_key_path" {
  description = "Filesystem path to the PEM-encoded OCI API signing private key. Only the path is configured here; the key file itself must never be committed (see .gitignore)."
  type        = string
  sensitive   = true
}

variable "compartment_ocid" {
  description = "OCID of the OCI compartment that will own resources provisioned by this config."
  type        = string
}

# Budget guardrail (R30): the recipient for the near-zero-threshold spend
# alert. Supplied via terraform.tfvars (gitignored) or TF_VAR_* — never a
# literal email address in committed HCL (ADR 0003: public repo, no secrets).
variable "budget_alert_email_address" {
  description = "Email address notified by the budget guardrail's alert rules when forecasted or actual spend crosses the near-zero threshold."
  type        = string
}
