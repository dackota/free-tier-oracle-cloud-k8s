# R12/R13: the A1 node pool. Deliberately literal, per-node sizing (KISS)
# rather than the reference's pool-total-divided-by-size math: one node at
# 2 OCPU / 12 GB / 100 GB boot is the whole Always Free A1 allowance, and sits
# at half the 200 GB / 2-volume block-storage cap. Do not raise ocpus,
# memory_in_gbs, or boot_volume_size_in_gbs without re-checking the free-tier
# tripwires in CONTEXT.md / the PRD's Implementation Decisions.
#
# Node count comes from var.stay_within_free_tier (variables.tf): one node when
# true, var.worker_node_count when false. Every node past the first is billed.
resource "oci_containerengine_node_pool" "main" {
  cluster_id = oci_containerengine_cluster.main.id

  name           = "${local.name}-pool"
  compartment_id = oci_containerengine_cluster.main.compartment_id

  # Derived from the cluster (not re-pinned here) so the pool can never drift
  # from the cluster's pinned version (R11).
  kubernetes_version = oci_containerengine_cluster.main.kubernetes_version

  node_config_details {
    # R12: one node is the whole Always Free allowance. Each node past it adds
    # 2 OCPU / 12 GB of billed capacity.
    size = var.stay_within_free_tier ? 1 : var.worker_node_count

    dynamic "placement_configs" {
      for_each = data.oci_identity_availability_domains.worker_nodes.availability_domains
      content {
        availability_domain = placement_configs.value.name
        subnet_id           = oci_core_subnet.worker_nodes.id
      }
    }

    node_pool_pod_network_option_details {
      cni_type       = oci_containerengine_cluster.main.cluster_pod_network_options[0].cni_type
      pod_subnet_ids = [oci_core_subnet.pods.id]

      # R11/R12: VCN-native CNI draws each pod's IP from the pods subnet via
      # a secondary VNIC per pod. A VM.Standard.A1.Flex node gets one
      # secondary VNIC per OCPU beyond the first (reserved for the node's
      # own primary VNIC), and each VNIC hosts up to 31 pod IPs -- so for our
      # 2-OCPU node that's (2 - 1) * 31 = 31, capped at OKE's hard ceiling of
      # 110. This is the same value the reference's per-pool formula
      # evaluates to for a 2-OCPU node; written as a literal here because our
      # sizing is per-node, not pool-divided.
      max_pods_per_node = 31
    }

    # Hardening default: encrypt Paravirtualized volume traffic between the
    # node and its boot/block volumes.
    is_pv_encryption_in_transit_enabled = true
  }

  node_shape = "VM.Standard.A1.Flex"

  node_shape_config {
    # R12: per node, and the full Always Free A1 allowance. Literal whatever
    # size resolves to: the allowance covers ONE node, so a second duplicates
    # these as billed capacity rather than stretching the free ones further.
    ocpus         = 2
    memory_in_gbs = 12
  }

  node_source_details {
    source_type = "IMAGE"

    # Selects the aarch64 (A1) Oracle Linux OKE platform image matching the
    # cluster's pinned Kubernetes version, excluding GPU variants. Encodes a
    # real scar from the reference: OCI publishes many node images per
    # compartment and there is no simpler filter than string-matching the
    # image name. Ported verbatim -- do not hand-simplify.
    #
    # The OS is pinned to "Oracle-Linux-8.10" (not bare "Oracle-Linux") on
    # purpose: OKE publishes MULTIPLE OS variants per Kubernetes version
    # (e.g. v1.36.1 ships both OL 8.10 and OL 9.7 aarch64 images), so a bare
    # match would make the [0] pick nondeterministic and could silently jump
    # the OS major version on a routine k8s upgrade. Bumping the OS is a
    # deliberate, reviewed change -- edit this literal, same as the version.
    image_id = try(([for s in data.oci_containerengine_node_pool_option.node_pool_options.sources : s.image_id if
      strcontains(s.source_name, "aarch64") &&
      strcontains(s.source_name, "Oracle-Linux-8.10") &&
      !strcontains(s.source_name, "GPU") &&
      strcontains(s.source_name, "OKE-${trimprefix(oci_containerengine_cluster.main.kubernetes_version, "v")}")
    ])[0], null)

    # R13: 100 GB per node. The Always Free block-storage cap is 200 GB across
    # at most 2 volumes, and boot volumes count against it, so 100 GB is the
    # largest size that still leaves room for a second volume. That headroom is
    # not spare capacity to reclaim: replacing a node transiently needs its
    # replacement's boot volume alongside the outgoing one, so raising this to
    # 200 would make every node replacement fail on the cap.
    boot_volume_size_in_gbs = 100
  }

  node_metadata = {
    # path.module makes this cwd-independent (validate/apply from any
    # directory), unlike the reference's bare file("init.sh").
    user_data                      = base64encode(file("${path.module}/init.sh"))
    areLegacyImdsEndpointsDisabled = true
  }
}

# R12/R13: candidate node images/shapes for the cluster's compartment; queried
# by node_source_details.image_id above to resolve the correct aarch64 OKE
# image for the pinned Kubernetes version.
data "oci_containerengine_node_pool_option" "node_pool_options" {
  node_pool_option_id = "all"
  compartment_id      = oci_containerengine_cluster.main.compartment_id
}
