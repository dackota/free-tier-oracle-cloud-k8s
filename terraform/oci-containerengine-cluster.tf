# R11: the OKE control plane. BASIC_CLUSTER is the free-tier tier (no charge
# for the control plane); the API endpoint is public so kubectl works from
# the operator's laptop with no bastion tunnel; the Kubernetes version is
# pinned to a literal so upgrades are a deliberate, reviewed change rather
# than floating to whatever OKE currently defaults to.
resource "oci_containerengine_cluster" "main" {
  name               = "${local.name}-cluster"
  compartment_id     = oci_core_vcn.main.compartment_id
  kubernetes_version = "v1.36.1"
  type               = "BASIC_CLUSTER"

  # No policy-based image verification for this homelab-scale cluster.
  image_policy_config {
    is_policy_enabled = false
  }

  # R11: OCI_VCN_IP_NATIVE draws pod IPs directly from the pods subnet
  # (oci-subnets.tf) instead of an overlay, matching the reference topology
  # this project ported.
  cluster_pod_network_options {
    cni_type = "OCI_VCN_IP_NATIVE"
  }

  vcn_id = oci_core_vcn.main.id

  # R11: public API endpoint, placed in the dedicated api_endpoint subnet.
  endpoint_config {
    subnet_id            = oci_core_subnet.api_endpoint.id
    is_public_ip_enabled = true
  }

  # Wires the cluster's Kubernetes service LoadBalancers (kube-system's, not
  # the workload Gateway LB provisioned later via GitOps) to the lbs subnet.
  options {
    service_lb_subnet_ids = [oci_core_subnet.lbs.id]
  }
}
