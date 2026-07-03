# Shared naming and networking locals for the VCN, subnets, gateways, route
# tables, and security lists (R8-R10). Ported from the reference homelab
# config; scoped to this slice only (no nodepool_size — that belongs to the
# node-pool slice, not networking, per YAGNI).
locals {
  name = "k8s"

  # Reference CIDR layout (R8): a /21 VCN split into per-purpose subnets. The
  # pods subnet is sized /22 because the OKE cluster's CNI is
  # OCI_VCN_IP_NATIVE — pods draw IPs directly from this subnet.
  subnets = {
    vcn = "10.127.80.0/21"

    bastion      = "10.127.80.0/24"
    api_endpoint = "10.127.81.0/24"
    lbs          = "10.127.82.0/24"
    worker_nodes = "10.127.83.0/24"
    pods         = "10.127.84.0/22"
  }
}

# Named protocol numbers (R10): OCI security list rules require numeric
# protocol identifiers rather than names.
locals {
  protocol_numbers = {
    ICMP = 1
    TCP  = 6
    UDP  = 17
  }
}
