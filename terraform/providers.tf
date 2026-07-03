# OCI provider authentication (R6): tenancy OCID plus an API signing key
# (user OCID, fingerprint, private key), and region — all wired to variables,
# never a literal value here. Populate the variables via environment
# (TF_VAR_*) or a local, gitignored terraform.tfvars — see
# terraform.tfvars.example and README.md.
provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}
