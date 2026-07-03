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

# R14: source CIDR ranges allowed to open sessions against the managed OCI
# Bastion. Defaults to 0.0.0.0/0 — see the comment on oci_bastion_bastion.main
# for why that default is a deliberate, defense-in-depth-gated choice for a
# single-operator homelab with a dynamic home IP, not an open door to the
# worker nodes themselves. Override in terraform.tfvars to narrow it once a
# static source IP/CIDR is available.
variable "bastion_allowed_cidr_blocks" {
  description = "CIDR blocks allowed to create sessions against the managed OCI Bastion. Defaults to [\"0.0.0.0/0\"], acceptable because Bastion access is still gated by IAM policy, an SSH key, and a time-boxed ephemeral session regardless of source CIDR."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# Bootstrap (R18/R20): the public GitOps repo the bootstrap ArgoCD
# Application pulls from. A variable, not a literal, so a fork of this repo
# only has to override one value instead of hunting it down inline. The child
# Applications committed under gitops/bootstrap/ (platform.yaml,
# workloads.yaml) and gitops/platform/argocd.yaml still hardcode this same
# URL literally — they're plain YAML ArgoCD reads as-is, with no Terraform
# templating, so a variable can't reach them; keep those in sync by hand if
# this default ever changes. Defaults to this project's own repo; anonymous
# HTTPS, no repository credential is ever created (R20/ADR 0003 — the repo is
# public).
variable "gitops_repo_url" {
  description = "HTTPS URL of the public GitOps repo the bootstrap ArgoCD Application pulls from. Pulled anonymously — no repository-credential Secret (R20)."
  type        = string
  default     = "https://github.com/dackota/free-tier-oracle-cloud-k8s.git"
}

# Budget guardrail (R30): the recipient for the near-zero-threshold spend
# alert. Supplied via terraform.tfvars (gitignored) or TF_VAR_* — never a
# literal email address in committed HCL (ADR 0003: public repo, no secrets).
variable "budget_alert_email_address" {
  description = "Email address notified by the budget guardrail's alert rules when forecasted or actual spend crosses the near-zero threshold."
  type        = string
  sensitive   = true # PII: keep the recipient out of plan/apply and CI output

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email_address))
    error_message = "budget_alert_email_address must be a valid email address (e.g. alerts@example.com)."
  }
}
