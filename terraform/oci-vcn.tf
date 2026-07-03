# R8: the VCN that holds the OKE cluster's network. Deviation from the
# reference: compartment_id is var.compartment_ocid (a dedicated compartment),
# not var.tenancy_ocid (tenancy root) — see CONTEXT.md -> "Compartment".
resource "oci_core_vcn" "main" {
  display_name   = "${local.name}-vcn"
  compartment_id = var.compartment_ocid

  cidr_blocks = [local.subnets.vcn]
  dns_label   = "${local.name}vcn"
}
