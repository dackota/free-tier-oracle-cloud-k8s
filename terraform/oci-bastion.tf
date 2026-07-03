# R14: managed OCI Bastion, giving the operator SSH access to the private
# worker-node subnet for debugging without exposing the nodes themselves to
# the internet or burning A1 compute quota on a dedicated jump host.
resource "oci_bastion_bastion" "main" {
  compartment_id = oci_core_vcn.main.compartment_id

  bastion_type = "STANDARD"

  name             = "${local.name}-bastion"
  target_subnet_id = oci_core_subnet.bastion.id

  # Security posture: var.bastion_allowed_cidr_blocks defaults to 0.0.0.0/0,
  # which is a deliberate choice, not an oversight, for a single-operator
  # homelab with a dynamic home IP. The Bastion is defense-in-depth gated
  # regardless of source CIDR -- OCI IAM policy, an uploaded SSH public key,
  # and a time-boxed ephemeral session are all still required before any SSH
  # traffic reaches a worker node. Narrow the variable to a static IP/CIDR if
  # one becomes available.
  client_cidr_block_allow_list = var.bastion_allowed_cidr_blocks
}
