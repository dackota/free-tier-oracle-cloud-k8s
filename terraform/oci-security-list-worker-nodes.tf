# R10: worker nodes security list — the Node pool's private subnet. Allows
# the API endpoint and pods to reach kubelet, the bastion over SSH, load
# balancer node-port/kube-proxy traffic, and outbound access to the API
# endpoint, OKE, and image registries.
resource "oci_core_security_list" "worker_nodes" {
  vcn_id = oci_core_vcn.main.id

  display_name   = "${oci_core_vcn.main.display_name}-worker-nodes-sl"
  compartment_id = oci_core_vcn.main.compartment_id

  ingress_security_rules {
    description = "Allow Kubernetes API endpoint to communicate with worker nodes"
    source      = local.subnets.api_endpoint
    protocol    = local.protocol_numbers["TCP"]
    tcp_options {
      min = 10250
      max = 10250
    }
  }

  ingress_security_rules {
    description = "Allow pods to communicate with worker nodes"
    source      = local.subnets.pods
    protocol    = local.protocol_numbers["TCP"]
    tcp_options {
      min = 10250
      max = 10250
    }
  }

  ingress_security_rules {
    description = "Path Discovery"
    source      = "0.0.0.0/0"
    protocol    = local.protocol_numbers["ICMP"]
    icmp_options {
      type = 3
      code = 4
    }
  }

  ingress_security_rules {
    description = "Allow inbound SSH traffic to managed nodes"
    source      = local.subnets.bastion
    protocol    = local.protocol_numbers["TCP"]
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Node-port traffic reaches the workers via the LB data plane (lbs subnet),
  # so scope these two rules to the lbs subnet rather than the reference's
  # 0.0.0.0/0 — NodePort Services must not be reachable directly from the
  # internet (security-hardening follow-up; matches the kube-proxy rule below).
  #
  # traefik-nlb (gitops/platform/traefik/values.yaml, PR #134) is the one
  # exception: it sets is-preserve-source, so packets reach the node still
  # carrying the *client's* address rather than an lbs-subnet address — the
  # rule above never matches them, and every connection through the NLB times
  # out. Rather than widen the shared 30000-32767 rule to 0.0.0.0/0 (which
  # would expose every current and future NodePort on this cluster), open
  # only the two ports this Service actually uses. They're Kubernetes'
  # auto-assigned nodePorts (unpinnable for now — .ports.*.nodePort in the
  # chart is shared across all Services rendered from it, so pinning would
  # collide with the primary `traefik` Service's own auto-assigned ports
  # while both run in parallel) — confirm they still match
  # `kubectl -n traefik get svc traefik-nlb` before trusting this rule, and
  # revisit at cutover once only one Service remains and its ports can be
  # pinned.
  ingress_security_rules {
    description = "traefik-nlb web (80) node port — is-preserve-source bypasses the lbs-subnet rule above"
    source      = "0.0.0.0/0"
    protocol    = local.protocol_numbers["TCP"]
    tcp_options {
      min = 31379
      max = 31379
    }
  }

  ingress_security_rules {
    description = "traefik-nlb websecure (443) node port — is-preserve-source bypasses the lbs-subnet rule above"
    source      = "0.0.0.0/0"
    protocol    = local.protocol_numbers["TCP"]
    tcp_options {
      min = 32347
      max = 32347
    }
  }

  ingress_security_rules {
    description = "Load balancer to worker nodes node TCP ports"
    source      = local.subnets.lbs
    protocol    = local.protocol_numbers["TCP"]
    tcp_options {
      min = 30000
      max = 32767
    }
  }

  ingress_security_rules {
    description = "Load balancer to worker nodes node UDP ports"
    source      = local.subnets.lbs
    protocol    = local.protocol_numbers["UDP"]
    udp_options {
      min = 30000
      max = 32767
    }
  }

  ingress_security_rules {
    description = "Allow load balancer to communicate with kube-proxy on worker nodes"
    source      = local.subnets.lbs
    protocol    = local.protocol_numbers["TCP"]
    tcp_options {
      min = 10256
      max = 10256
    }
  }

  egress_security_rules {
    description = "Allow worker nodes to access pods"
    destination = local.subnets.pods
    protocol    = "all"
  }

  egress_security_rules {
    description = "Path Discovery"
    destination = "0.0.0.0/0"
    protocol    = local.protocol_numbers["ICMP"]
    icmp_options {
      type = 3
      code = 4
    }
  }

  egress_security_rules {
    description      = "Allow worker nodes to communicate with OKE"
    destination_type = "SERVICE_CIDR_BLOCK"
    destination      = data.oci_core_services.all_oci_services.services[0]["cidr_block"]
    protocol         = "all"
  }

  egress_security_rules {
    description = "Kubernetes worker to Kubernetes API endpoint communication"
    destination = local.subnets.api_endpoint
    protocol    = local.protocol_numbers["TCP"]
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  egress_security_rules {
    description = "Kubernetes worker to Kubernetes API endpoint communication"
    destination = local.subnets.api_endpoint
    protocol    = local.protocol_numbers["TCP"]
    tcp_options {
      min = 12250
      max = 12250
    }
  }

  egress_security_rules {
    description = "Allow worker nodes to pull images from the Internet"
    destination = "0.0.0.0/0"
    protocol    = local.protocol_numbers["TCP"]
    tcp_options {
      min = 443
      max = 443
    }
  }
}
