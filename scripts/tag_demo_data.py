#!/usr/bin/env python3
"""Label the Getting Started guide's fictional objects as demo data.

This instance holds a model of the real OCI cluster (tagged `oci-live`, see
scripts/model_oci_cluster.py) alongside the guide's teaching dataset. Nothing in
Nautobot's UI distinguishes the two on sight, so the fictional objects are
tagged `demo-data` and given a description saying so.

It also strips any real-world street address from the fictional sites. A demo
object carrying a verifiable real-world identifier is the kind of record that
gets read as inventory a year later, so demo data stays obviously fake:
no real addresses, and loopback DNS names under .example.invalid.

Run after scripts/seed_nautobot_demo_data.py.

Usage:
    NAUTOBOT_TOKEN=... python3 scripts/tag_demo_data.py
"""

from nautobot_api import add_tag, find, get_or_create, patch, report, request, require_token

require_token()

DEMO_NOTE = "Fictional object from the Nautobot Getting Started guide. Not real infrastructure."

print("Demo tag...")
tag_demo = get_or_create(
    "extras/tags",
    {"name": "demo-data"},
    {
        "content_types": [
            "dcim.location", "dcim.device", "dcim.devicetype",
            "ipam.vlan", "ipam.prefix", "ipam.ipaddress", "tenancy.tenant",
        ],
        "color": "ff9800",
        "description": DEMO_NOTE,
    },
)

global_ns = find("ipam/namespaces", name="Global")

DEMO_LOCATIONS = ["North America", "Canada", "Vancouver", "Ottawa", "Vancouver 1", "Ottawa 1"]
DEMO_DEVICES = ["van01-edge-01", "van01-edge-02", "van01-acc-01", "ott01-edge-01"]
DEMO_DEVICE_TYPES = ["MX240-edge", "DCS-7050SX3-48YC8"]
DEMO_TENANTS = ["Retail", "Corporate"]
DEMO_PREFIXES = ["10.10.10.0/24", "10.0.0.0/24"]
DEMO_IPS = [
    "10.10.10.0/31", "10.10.10.1/31", "10.10.10.2/31",
    "10.10.10.3/31", "10.10.10.6/31", "10.10.10.7/31",
    "10.0.0.1/32", "10.0.0.2/32", "10.0.0.3/32", "10.0.0.4/32",
]

print("Tagging locations...")
for name in DEMO_LOCATIONS:
    obj = find("dcim/locations", name=name)
    add_tag("dcim/locations", obj, tag_demo["id"], f"demo-data on {name}")

# A real street address on a site that does not exist is the single most
# misleading field in the demo set, so it is cleared rather than left populated.
print("Clearing street addresses on fictional sites...")
for name in ("Vancouver 1", "Ottawa 1"):
    obj = find("dcim/locations", name=name)
    if obj.get("physical_address"):
        patch("dcim/locations", obj["id"], {"physical_address": "", "description": DEMO_NOTE})
        print(f"  cleared address on {name}")
    elif obj.get("description") != DEMO_NOTE:
        patch("dcim/locations", obj["id"], {"description": DEMO_NOTE})

print("Tagging devices, device types, tenants...")
for name in DEMO_DEVICES:
    obj = find("dcim/devices", name=name)
    add_tag("dcim/devices", obj, tag_demo["id"], f"demo-data on {name}")
for model in DEMO_DEVICE_TYPES:
    obj = find("dcim/device-types", model=model)
    add_tag("dcim/device-types", obj, tag_demo["id"], f"demo-data on {model}")
for name in DEMO_TENANTS:
    obj = find("tenancy/tenants", name=name)
    add_tag("tenancy/tenants", obj, tag_demo["id"], f"demo-data on {name}")

# Every VLAN in this instance came from the guide -- the OCI model creates none.
# They are fetched as a list rather than by natural key because two of them
# deliberately share a VID and name, so no single filter identifies one.
print("Tagging VLANs...")
for vlan in request("GET", "ipam/vlans/?limit=100")["results"]:
    add_tag("ipam/vlans", vlan, tag_demo["id"], f"demo-data on vlan {vlan['vid']}")

print("Tagging demo prefixes and IPs (Global namespace only)...")
for cidr in DEMO_PREFIXES:
    obj = find("ipam/prefixes", prefix=cidr, namespace=global_ns["id"])
    add_tag("ipam/prefixes", obj, tag_demo["id"], f"demo-data on {cidr}")
for addr in DEMO_IPS:
    obj = find("ipam/ip-addresses", address=addr, namespace=global_ns["id"])
    add_tag("ipam/ip-addresses", obj, tag_demo["id"], f"demo-data on {addr}")

report("Demo data labelling")
