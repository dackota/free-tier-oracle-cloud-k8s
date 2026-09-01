#!/usr/bin/env python3
"""Model the live OCI / OKE cluster in Nautobot.

Every value here was read from the running environment, not invented:

  * VCN and subnet names, CIDRs, public/private  -- `oci network vcn|subnet list`
  * cluster name, Kubernetes version, CNI        -- `oci ce cluster list`, terraform/
  * node names, IPs, AD, fault domain, OS        -- `kubectl get nodes -o json`
  * CIDR layout                                  -- terraform/locals.tf
  * shape sizing and boot volume                 -- terraform/oci-containerengine-nodepool.tf
  * service CIDR                                 -- the `kubernetes` Service ClusterIP
  * load balancer public IP                      -- `kubectl get svc -n traefik traefik`

DELIBERATELY EXCLUDED: OCIDs (tenancy, compartment, cluster, VCN, subnet,
instance). They are account-scoped identifiers for real resources, this repo is
public, and the Nautobot instance is shown as a demo. Nothing in the model needs
them -- region, CIDR, shape and version carry all the useful meaning. Do not add
them back; look them up in the OCI console when you actually need one.

Objects are tagged `oci-live` so they can never be confused with the `demo-data`
objects from the Getting Started guide sharing this instance.

Usage:
    NAUTOBOT_TOKEN=... python3 model_oci_cluster.py
"""

from nautobot_api import (
    add_tag,
    get_or_create,
    patch,
    report,
    request,
    require_token,
    status_id,
)

require_token()

REGION = "us-phoenix-1"
K8S_VERSION = "v1.36.1"
SERVICE_CIDR = "10.96.0.0/16"
LB_PUBLIC_IP = "129.151.8.51"
EXPOSED_HOSTNAMES = ["nautobot.dackota.com", "changes.dackota.com", "me.dackota.com"]

# name, cidr, is_public
SUBNETS = [
    ("k8s-vcn-bastion-subnet", "10.127.80.0/24", False),
    ("k8s-vcn-api-endpoint-subnet", "10.127.81.0/24", True),
    ("k8s-vcn-lbs-subnet", "10.127.82.0/24", True),
    ("k8s-vcn-worker-nodes-subnet", "10.127.83.0/24", False),
    ("k8s-vcn-pods-subnet", "10.127.84.0/22", False),
]

# hostname, internal IP, availability domain, fault domain
NODES = [
    ("oke-c4dojcgdzla-nhw3iilxy3a-slskqbhahnq-0", "10.127.83.119", "PHX-AD-3", "FAULT-DOMAIN-1"),
    ("oke-c4dojcgdzla-nhw3iilxy3a-slskqbhahnq-1", "10.127.83.195", "PHX-AD-2", "FAULT-DOMAIN-1"),
]

ACTIVE = status_id("Active")

# -- Tags ------------------------------------------------------------------
# `oci-live` marks everything below as a record of real infrastructure. The AD
# tags exist because Nautobot's VirtualMachine has no location field -- the
# cluster carries the region, so per-node placement needs a taggable dimension.
print("Tags...")
TAGGABLE = [
    "dcim.location", "ipam.prefix", "ipam.ipaddress", "ipam.namespace",
    "virtualization.cluster", "virtualization.virtualmachine", "virtualization.vminterface",
    "cloud.cloudaccount", "cloud.cloudnetwork", "cloud.cloudservice", "cloud.cloudresourcetype",
]
tag_live = get_or_create(
    "extras/tags",
    {"name": "oci-live"},
    {"content_types": TAGGABLE, "color": "4caf50",
     "description": "Record of real, running infrastructure in the OCI free-tier tenancy."},
)
ad_tags = {
    ad: get_or_create(
        "extras/tags",
        {"name": ad},
        {"content_types": ["virtualization.virtualmachine"], "color": "9e9e9e",
         "description": f"Node placed in OCI availability domain {ad}."},
    )
    for ad in sorted({n[2] for n in NODES})
}

# -- Locations -------------------------------------------------------------
# A second, parallel location-type root alongside the guide's Continent/Country
# tree. Cloud topology is region -> availability domain, not geography.
print("Cloud locations...")
lt_region = get_or_create(
    "dcim/location-types",
    {"name": "Cloud Region"},
    {"content_types": ["virtualization.cluster", "ipam.prefix", "ipam.namespace"],
     "description": "An OCI region."},
)
lt_ad = get_or_create(
    "dcim/location-types",
    {"name": "Availability Domain"},
    {"parent": lt_region["id"], "content_types": ["ipam.prefix"],
     "description": "An OCI availability domain within a region."},
)

loc_region = get_or_create(
    "dcim/locations",
    {"name": REGION},
    {"location_type": lt_region["id"], "status": ACTIVE,
     "description": "OCI region us-phoenix-1 (phx), Phoenix, Arizona."},
)
add_tag("dcim/locations", loc_region, tag_live["id"], f"oci-live on {REGION}")

for ad in sorted({n[2] for n in NODES}):
    loc_ad = get_or_create(
        "dcim/locations",
        {"name": ad},
        {"location_type": lt_ad["id"], "parent": loc_region["id"], "status": ACTIVE,
         "description": f"OCI availability domain {ad}."},
    )
    add_tag("dcim/locations", loc_ad, tag_live["id"], f"oci-live on {ad}")

# -- Hardware / software vocabulary ---------------------------------------
print("Manufacturer, platform, role...")
mfg_oracle = get_or_create("dcim/manufacturers", {"name": "Oracle"})
platform_ol = get_or_create(
    "dcim/platforms",
    {"name": "Oracle Linux 8.10 (aarch64)"},
    {"manufacturer": mfg_oracle["id"],
     "description": "OKE aarch64 node image. Kernel 5.15.0-321.202.5.1.el8uek, cri-o 1.36.0."},
)
role_worker = get_or_create(
    "extras/roles",
    {"name": "kubernetes-worker"},
    {"content_types": ["virtualization.virtualmachine"], "color": "3f51b5"},
)

# -- IPAM ------------------------------------------------------------------
# The VCN gets its own IPAM namespace so cluster addressing can never collide
# with, or be mistaken for, the demo data in the Global namespace.
print("IPAM namespace and prefixes...")
ns = get_or_create(
    "ipam/namespaces",
    {"name": "OCI k8s-vcn"},
    {"location": loc_region["id"], "description": "Address space of the k8s-vcn VCN."},
)
add_tag("ipam/namespaces", ns, tag_live["id"], "oci-live on namespace")

prefixes = {}
prefixes["10.127.80.0/21"] = get_or_create(
    "ipam/prefixes",
    {"prefix": "10.127.80.0/21", "namespace": ns["id"]},
    {"status": ACTIVE, "type": "container", "location": loc_region["id"],
     "description": "k8s-vcn VCN supernet."},
)
for name, cidr, is_public in SUBNETS:
    scope = "public" if is_public else "private"
    prefixes[cidr] = get_or_create(
        "ipam/prefixes",
        {"prefix": cidr, "namespace": ns["id"]},
        {"status": ACTIVE, "type": "network", "location": loc_region["id"],
         "description": f"{name} ({scope})."},
    )
# Cluster-internal, not routed in the VCN -- recorded here so the range is not
# accidentally reused elsewhere.
prefixes[SERVICE_CIDR] = get_or_create(
    "ipam/prefixes",
    {"prefix": SERVICE_CIDR, "namespace": ns["id"]},
    {"status": ACTIVE, "type": "container",
     "description": "Kubernetes Service ClusterIP range (OKE default). Not routed in the VCN."},
)
# A /32 container so the OCI-assigned load balancer address has a parent Prefix
# without inventing ownership of the surrounding public block.
prefixes[f"{LB_PUBLIC_IP}/32"] = get_or_create(
    "ipam/prefixes",
    {"prefix": f"{LB_PUBLIC_IP}/32", "namespace": ns["id"]},
    {"status": ACTIVE, "type": "network",
     "description": "OCI-assigned public IP for the Traefik load balancer."},
)
for cidr, obj in prefixes.items():
    add_tag("ipam/prefixes", obj, tag_live["id"], f"oci-live on {cidr}")

# -- Virtualization --------------------------------------------------------
print("Cluster and nodes...")
ctype = get_or_create(
    "virtualization/cluster-types",
    {"name": "Oracle Container Engine for Kubernetes (OKE)"},
    {"description": "Managed Kubernetes control plane on Oracle Cloud Infrastructure."},
)
cluster = get_or_create(
    "virtualization/clusters",
    {"name": "k8s-cluster"},
    {"cluster_type": ctype["id"], "location": loc_region["id"],
     "comments": (
         f"OKE cluster, Kubernetes {K8S_VERSION}, CNI OCI_VCN_IP_NATIVE.\n"
         f"Node pool k8s-pool: 1 x VM.Standard.A1.Flex (2 OCPU / 12 GB), "
         f"sized to the Always Free allocation of 2 OCPU / 12 GB."
     )},
)
add_tag("virtualization/clusters", cluster, tag_live["id"], "oci-live on k8s-cluster")

for hostname, ip_addr, ad, fault_domain in NODES:
    vm = get_or_create(
        "virtualization/virtual-machines",
        {"name": hostname},
        {"cluster": cluster["id"], "status": ACTIVE, "role": role_worker["id"],
         "platform": platform_ol["id"],
         "vcpus": 2, "memory": 12288, "disk": 100,
         "comments": (
             f"OKE worker node, shape VM.Standard.A1.Flex (arm64).\n"
             f"Availability domain: {ad}\nFault domain: {fault_domain}\n"
             f"kubelet {K8S_VERSION}, Oracle Linux Server 8.10, cri-o 1.36.0.\n"
             f"Max pods 31 (OCI_VCN_IP_NATIVE, VNIC-limited)."
         )},
    )
    add_tag("virtualization/virtual-machines", vm, tag_live["id"], f"oci-live on {hostname}")
    add_tag("virtualization/virtual-machines", vm, ad_tags[ad]["id"], f"{ad} on {hostname}")

    vmi = get_or_create(
        "virtualization/interfaces",
        {"virtual_machine": vm["id"], "name": "primary"},
        {"status": ACTIVE, "description": "Primary VNIC in k8s-vcn-worker-nodes-subnet."},
        label=f"{hostname} primary",
    )
    ip = get_or_create(
        "ipam/ip-addresses",
        {"address": f"{ip_addr}/24", "namespace": ns["id"]},
        {"status": ACTIVE, "type": "host", "dns_name": hostname},
    )
    add_tag("ipam/ip-addresses", ip, tag_live["id"], f"oci-live on {ip_addr}")
    get_or_create(
        "ipam/ip-address-to-interface",
        {"ip_address": ip["id"], "vm_interface": vmi["id"]},
        label=f"{hostname} primary {ip_addr}",
    )
    fresh = request("GET", f"virtualization/virtual-machines/{vm['id']}/")
    if fresh.get("primary_ip4") is None:
        patch("virtualization/virtual-machines", vm["id"], {"primary_ip4": ip["id"]})
        print(f"  set primary_ip4 {hostname} -> {ip_addr}")

lb_ip = get_or_create(
    "ipam/ip-addresses",
    {"address": f"{LB_PUBLIC_IP}/32", "namespace": ns["id"]},
    {"status": ACTIVE, "type": "host",
     "description": "Traefik LoadBalancer ingress address; fronts all published hostnames."},
)
add_tag("ipam/ip-addresses", lb_ip, tag_live["id"], f"oci-live on {LB_PUBLIC_IP}")

# -- Cloud app -------------------------------------------------------------
# account_number is a required field; it carries a placeholder rather than the
# real tenancy OCID for the reason given at the top of this file.
print("Cloud account, networks, services...")
account = get_or_create(
    "cloud/cloud-accounts",
    {"name": "OCI Free Tier (dackota tenancy)"},
    {"account_number": "REDACTED", "provider": mfg_oracle["id"],
     "description": f"Oracle Cloud Infrastructure tenancy, home region {REGION}."},
)
add_tag("cloud/cloud-accounts", account, tag_live["id"], "oci-live on cloud account")

rt_vcn = get_or_create(
    "cloud/cloud-resource-types",
    {"name": "OCI VCN"},
    {"provider": mfg_oracle["id"], "content_types": ["cloud.cloudnetwork"],
     "description": "Oracle Cloud Infrastructure Virtual Cloud Network."},
)
rt_subnet = get_or_create(
    "cloud/cloud-resource-types",
    {"name": "OCI Subnet"},
    {"provider": mfg_oracle["id"], "content_types": ["cloud.cloudnetwork"],
     "description": "Regional subnet within an OCI VCN."},
)
rt_oke = get_or_create(
    "cloud/cloud-resource-types",
    {"name": "OCI Container Engine for Kubernetes"},
    {"provider": mfg_oracle["id"], "content_types": ["cloud.cloudservice"],
     "description": "OKE managed Kubernetes service."},
)
rt_lb = get_or_create(
    "cloud/cloud-resource-types",
    {"name": "OCI Load Balancer"},
    {"provider": mfg_oracle["id"], "content_types": ["cloud.cloudservice"],
     "description": "OCI load balancer fronting a Kubernetes Service of type LoadBalancer."},
)

vcn = get_or_create(
    "cloud/cloud-networks",
    {"name": "k8s-vcn"},
    {"cloud_resource_type": rt_vcn["id"], "cloud_account": account["id"],
     "description": "VCN holding the OKE cluster.",
     "extra_config": {"cidr_block": "10.127.80.0/21", "region": REGION}},
)
add_tag("cloud/cloud-networks", vcn, tag_live["id"], "oci-live on k8s-vcn")
get_or_create(
    "cloud/cloud-network-prefix-assignments",
    {"cloud_network": vcn["id"], "prefix": prefixes["10.127.80.0/21"]["id"]},
    label="k8s-vcn -> 10.127.80.0/21",
)

subnet_networks = {}
for name, cidr, is_public in SUBNETS:
    net = get_or_create(
        "cloud/cloud-networks",
        {"name": name},
        {"cloud_resource_type": rt_subnet["id"], "cloud_account": account["id"],
         "parent": vcn["id"],
         "description": f"{'Public' if is_public else 'Private'} subnet, {cidr}.",
         "extra_config": {"cidr_block": cidr, "public": is_public}},
    )
    add_tag("cloud/cloud-networks", net, tag_live["id"], f"oci-live on {name}")
    get_or_create(
        "cloud/cloud-network-prefix-assignments",
        {"cloud_network": net["id"], "prefix": prefixes[cidr]["id"]},
        label=f"{name} -> {cidr}",
    )
    subnet_networks[name] = net

svc_oke = get_or_create(
    "cloud/cloud-services",
    {"name": "k8s-cluster (OKE)"},
    {"cloud_resource_type": rt_oke["id"], "cloud_account": account["id"],
     "description": f"Managed Kubernetes {K8S_VERSION} control plane.",
     "extra_config": {"kubernetes_version": K8S_VERSION,
                      "cni_type": "OCI_VCN_IP_NATIVE", "service_cidr": SERVICE_CIDR}},
)
add_tag("cloud/cloud-services", svc_oke, tag_live["id"], "oci-live on OKE service")

svc_lb = get_or_create(
    "cloud/cloud-services",
    {"name": "traefik (LoadBalancer)"},
    {"cloud_resource_type": rt_lb["id"], "cloud_account": account["id"],
     "description": "OCI load balancer created by the traefik Service; ingress for all published hosts.",
     "extra_config": {"public_ip": LB_PUBLIC_IP, "ports": [80, 443],
                      "node_ports": [30217, 30348], "hostnames": EXPOSED_HOSTNAMES}},
)
add_tag("cloud/cloud-services", svc_lb, tag_live["id"], "oci-live on LB service")

for svc, nets in (
    (svc_oke, ["k8s-vcn-api-endpoint-subnet", "k8s-vcn-worker-nodes-subnet", "k8s-vcn-pods-subnet"]),
    (svc_lb, ["k8s-vcn-lbs-subnet"]),
):
    for net_name in nets:
        get_or_create(
            "cloud/cloud-service-network-assignments",
            {"cloud_service": svc["id"], "cloud_network": subnet_networks[net_name]["id"]},
            label=f"{svc['name']} -> {net_name}",
        )

report("OCI cluster model")
