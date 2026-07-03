# R12: availability domains in the compartment. The node pool's
# placement_configs (oci-containerengine-nodepool.tf) fans out over these to
# place the 2-node pool.
data "oci_identity_availability_domains" "worker_nodes" {
  compartment_id = oci_core_subnet.worker_nodes.compartment_id
}
