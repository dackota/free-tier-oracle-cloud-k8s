#!/usr/bin/env python3
"""Seed Nautobot with the objects from the official "Getting Started" feature guide.

This is TEACHING DATA, not inventory: fictional sites, devices, VLANs and
addresses that mirror the guide at
https://docs.nautobot.com/projects/core/en/stable/user-guide/feature-guides/getting-started/

Run scripts/tag_demo_data.py afterwards to label everything `demo-data`. The
same instance also holds a model of the real OCI cluster (scripts/
model_oci_cluster.py, tagged `oci-live`), and unlabelled fictional records that
look authoritative are exactly how demo data gets mistaken for inventory later.

Follows the guide's prerequisite order: location types -> locations -> roles ->
manufacturers -> platforms -> device types (+ interface templates) -> tenants ->
devices -> LAG members -> VLANs -> IPAM.

Idempotent: every object is looked up by its natural key before being created,
so re-running only fills in what is missing.

Usage:
    NAUTOBOT_TOKEN=... [NAUTOBOT_URL=https://...] python3 scripts/seed_nautobot_demo_data.py
"""

from nautobot_api import (
    ApiError,
    find,
    get_or_create,
    patch,
    report,
    request,
    require_token,
    status_id,
)

require_token()


def expand(pattern):
    """Expand one `[start-end]` range per pass, e.g. xe-[0-1]/0/[0-2] -> 6 names.

    Mirrors the bracket syntax the Nautobot UI accepts in component name fields.
    The REST API does not expand it, so it is done here.
    """
    start = pattern.find("[")
    if start == -1:
        return [pattern]
    end = pattern.index("]", start)
    lo, hi = pattern[start + 1 : end].split("-")
    prefix, suffix = pattern[:start], pattern[end + 1 :]
    return [n for i in range(int(lo), int(hi) + 1) for n in expand(f"{prefix}{i}{suffix}")]


def interface(device_name, iface_name):
    found = find("dcim/interfaces", device=device_name, name=iface_name)
    if not found:
        raise ApiError(f"interface {device_name}:{iface_name} not found")
    return found


print("Resolving statuses and namespace...")
ACTIVE = status_id("Active")
GLOBAL_NS = find("ipam/namespaces", name="Global")["id"]

# -- Location Types --------------------------------------------------------
# The guide's four-tier hierarchy. Only the bottom tier holds devices/VLANs, so
# only it needs those content types.
print("Location types...")
SITE_CONTENT = ["dcim.device", "dcim.rack", "ipam.vlan", "ipam.vlangroup", "ipam.prefix"]
lt_continent = get_or_create("dcim/location-types", {"name": "Continent"}, {"content_types": []})
lt_country = get_or_create(
    "dcim/location-types", {"name": "Country"}, {"parent": lt_continent["id"], "content_types": []}
)
lt_market = get_or_create(
    "dcim/location-types", {"name": "Market"}, {"parent": lt_country["id"], "content_types": []}
)
lt_site = get_or_create(
    "dcim/location-types",
    {"name": "Site"},
    {"parent": lt_market["id"], "content_types": SITE_CONTENT},
)

# -- Locations -------------------------------------------------------------
print("Locations...")
loc_na = get_or_create(
    "dcim/locations",
    {"name": "North America"},
    {"location_type": lt_continent["id"], "status": ACTIVE},
)
loc_canada = get_or_create(
    "dcim/locations",
    {"name": "Canada"},
    {"location_type": lt_country["id"], "parent": loc_na["id"], "status": ACTIVE},
)
loc_vancouver = get_or_create(
    "dcim/locations",
    {"name": "Vancouver"},
    {"location_type": lt_market["id"], "parent": loc_canada["id"], "status": ACTIVE},
)
loc_ottawa = get_or_create(
    "dcim/locations",
    {"name": "Ottawa"},
    {"location_type": lt_market["id"], "parent": loc_canada["id"], "status": ACTIVE},
)
# No street addresses: these sites do not exist, and a real-looking address on a
# fictional site is the part most likely to be mistaken for a real record.
loc_van1 = get_or_create(
    "dcim/locations",
    {"name": "Vancouver 1"},
    {"location_type": lt_site["id"], "parent": loc_vancouver["id"], "status": ACTIVE,
     "facility": "VAN01", "time_zone": "America/Vancouver"},
)
loc_ott1 = get_or_create(
    "dcim/locations",
    {"name": "Ottawa 1"},
    {"location_type": lt_site["id"], "parent": loc_ottawa["id"], "status": ACTIVE,
     "facility": "OTT01", "time_zone": "America/Toronto"},
)

# -- Device roles ----------------------------------------------------------
print("Device roles...")
DEVICE_CT = ["dcim.device"]
role_edge = get_or_create(
    "extras/roles", {"name": "edge"}, {"content_types": DEVICE_CT, "color": "f44336"}
)
role_access = get_or_create(
    "extras/roles", {"name": "access"}, {"content_types": DEVICE_CT, "color": "2196f3"}
)
get_or_create(
    "extras/roles", {"name": "distribution"}, {"content_types": DEVICE_CT, "color": "4caf50"}
)

# -- Manufacturers and platforms -------------------------------------------
print("Manufacturers and platforms...")
mfg_juniper = get_or_create("dcim/manufacturers", {"name": "Juniper"})
mfg_arista = get_or_create("dcim/manufacturers", {"name": "Arista"})
plat_junos = get_or_create(
    "dcim/platforms",
    {"name": "Juniper Junos"},
    {"manufacturer": mfg_juniper["id"], "napalm_driver": "junos", "network_driver": "juniper_junos"},
)
plat_eos = get_or_create(
    "dcim/platforms",
    {"name": "Arista EOS"},
    {"manufacturer": mfg_arista["id"], "napalm_driver": "eos", "network_driver": "arista_eos"},
)

# -- Device types and their interface templates ----------------------------
# Templates must exist before the devices: Nautobot instantiates a device's
# interfaces from the template at creation time and does not retroactively apply
# later template changes.
print("Device types and interface templates...")
dt_mx240 = get_or_create(
    "dcim/device-types", {"model": "MX240-edge"}, {"manufacturer": mfg_juniper["id"], "u_height": 5}
)
dt_7050 = get_or_create(
    "dcim/device-types",
    {"model": "DCS-7050SX3-48YC8"},
    {"manufacturer": mfg_arista["id"], "u_height": 1},
)

TEMPLATES = [
    (dt_mx240, "ae0", "lag"),
    *[(dt_mx240, n, "10gbase-x-sfpp") for n in expand("xe-[0-1]/0/[0-9]")],
    *[(dt_7050, n, "25gbase-x-sfp28") for n in expand("Ethernet[1-8]")],
]
for device_type, iface_name, iface_type in TEMPLATES:
    get_or_create(
        "dcim/interface-templates",
        {"device_type": device_type["id"], "name": iface_name},
        {"type": iface_type},
        label=f"{device_type['model']} {iface_name}",
    )

# -- Tenancy ---------------------------------------------------------------
print("Tenants...")
tg = get_or_create("tenancy/tenant-groups", {"name": "Business Units"})
tenant_retail = get_or_create("tenancy/tenants", {"name": "Retail"}, {"tenant_group": tg["id"]})
tenant_corp = get_or_create("tenancy/tenants", {"name": "Corporate"}, {"tenant_group": tg["id"]})

# -- Devices ---------------------------------------------------------------
print("Devices...")
DEVICES = [
    ("van01-edge-01", dt_mx240, role_edge, loc_van1, plat_junos, tenant_retail),
    ("van01-edge-02", dt_mx240, role_edge, loc_van1, plat_junos, tenant_retail),
    ("van01-acc-01", dt_7050, role_access, loc_van1, plat_eos, tenant_corp),
    ("ott01-edge-01", dt_mx240, role_edge, loc_ott1, plat_junos, tenant_corp),
]
devices = {}
for name, dtype, role, loc, platform, tenant in DEVICES:
    devices[name] = get_or_create(
        "dcim/devices",
        {"name": name},
        {"device_type": dtype["id"], "role": role["id"], "location": loc["id"],
         "platform": platform["id"], "tenant": tenant["id"], "status": ACTIVE},
    )

# -- LAG membership --------------------------------------------------------
# A device type template cannot express LAG membership, so it is set per device.
print("LAG membership...")
for device_name in ("van01-edge-01", "van01-edge-02", "ott01-edge-01"):
    lag = interface(device_name, "ae0")
    for member in ("xe-0/0/9", "xe-1/0/9"):
        iface = interface(device_name, member)
        if iface.get("lag") is None:
            patch("dcim/interfaces", iface["id"], {"lag": lag["id"]})
            print(f"  {device_name} {member} -> ae0")

# -- VLANs -----------------------------------------------------------------
# vlan 200 is global (no location) so it is assignable anywhere; the two vlan 100
# instances are location-scoped and deliberately share a VID and name.
print("VLANs...")
get_or_create("ipam/vlan-groups", {"name": "Vancouver 1 VLANs"}, {"location": loc_van1["id"]})
get_or_create(
    "ipam/vlans", {"vid": 200, "name": "vlan 200"}, {"status": ACTIVE}, label="vlan 200 (global)"
)
vlan100_van = get_or_create(
    "ipam/vlans",
    {"vid": 100, "name": "vlan 100", "location": loc_van1["id"]},
    {"status": ACTIVE},
    label="vlan 100 (Vancouver 1)",
)
get_or_create(
    "ipam/vlans",
    {"vid": 100, "name": "vlan 100", "location": loc_ott1["id"]},
    {"status": ACTIVE},
    label="vlan 100 (Ottawa 1)",
)

print("VLAN assignment to interface...")
access_iface = interface("van01-edge-01", "xe-0/0/0")
if access_iface.get("untagged_vlan") is None:
    patch(
        "dcim/interfaces",
        access_iface["id"],
        {"mode": "access", "untagged_vlan": vlan100_van["id"]},
    )
    print("  van01-edge-01 xe-0/0/0 -> access vlan 100")

# -- IPAM ------------------------------------------------------------------
print("IPAM...")
rir = get_or_create("ipam/rirs", {"name": "RFC1918"}, {"is_private": True})
get_or_create(
    "ipam/prefixes",
    {"prefix": "10.10.10.0/24", "namespace": GLOBAL_NS},
    {"status": ACTIVE, "rir": rir["id"], "type": "network", "location": loc_van1["id"],
     "description": "Point-to-point links"},
)
get_or_create(
    "ipam/prefixes",
    {"prefix": "10.0.0.0/24", "namespace": GLOBAL_NS},
    {"status": ACTIVE, "rir": rir["id"], "type": "pool", "description": "Device loopbacks"},
)

# The guide's 10.10.10.[0-1,2-3,6-7]/31 -- three non-contiguous /31 links.
P2P_ADDRESSES = ["10.10.10.0/31", "10.10.10.1/31", "10.10.10.2/31",
                 "10.10.10.3/31", "10.10.10.6/31", "10.10.10.7/31"]
for addr in P2P_ADDRESSES:
    get_or_create(
        "ipam/ip-addresses",
        {"address": addr, "namespace": GLOBAL_NS},
        {"status": ACTIVE, "type": "host"},
    )

LOOPBACKS = {
    "van01-edge-01": "10.0.0.1/32",
    "van01-edge-02": "10.0.0.2/32",
    "van01-acc-01": "10.0.0.3/32",
    "ott01-edge-01": "10.0.0.4/32",
}
loopback_objs = {
    device_name: get_or_create(
        "ipam/ip-addresses",
        {"address": addr, "namespace": GLOBAL_NS},
        {"status": ACTIVE, "type": "host", "dns_name": f"{device_name}.example.invalid"},
    )
    for device_name, addr in LOOPBACKS.items()
}

# -- Attach IPs to interfaces and mark them primary ------------------------
print("IP assignment...")
for device_name, iface_name, addr in (
    ("van01-edge-01", "xe-0/0/1", "10.10.10.0/31"),
    ("van01-edge-02", "xe-0/0/1", "10.10.10.1/31"),
):
    iface = interface(device_name, iface_name)
    ip = find("ipam/ip-addresses", address=addr, namespace=GLOBAL_NS)
    get_or_create(
        "ipam/ip-address-to-interface",
        {"ip_address": ip["id"], "interface": iface["id"]},
        label=f"{device_name} {iface_name} {addr}",
    )

for device_name, addr in LOOPBACKS.items():
    device = devices[device_name]
    lo = get_or_create(
        "dcim/interfaces",
        {"device": device["id"], "name": "lo0"},
        {"type": "virtual", "status": ACTIVE},
        label=f"{device_name} lo0",
    )
    ip = loopback_objs[device_name]
    get_or_create(
        "ipam/ip-address-to-interface",
        {"ip_address": ip["id"], "interface": lo["id"]},
        label=f"{device_name} lo0 {addr}",
    )
    fresh = request("GET", f"dcim/devices/{device['id']}/")
    if fresh.get("primary_ip4") is None:
        patch("dcim/devices", device["id"], {"primary_ip4": ip["id"]})
        print(f"  primary_ip4 {device_name} -> {addr}")

report("Getting Started demo data")
