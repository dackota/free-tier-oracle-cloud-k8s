# R9: Service gateway, so private subnets reach Oracle Services Network
# (e.g. Object Storage for OKE image pulls) without a public IP.
data "oci_core_services" "all_oci_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_service_gateway" "sgw" {
  vcn_id = oci_core_vcn.main.id

  display_name   = "${oci_core_vcn.main.display_name}-sgw"
  compartment_id = oci_core_vcn.main.compartment_id

  services {
    service_id = data.oci_core_services.all_oci_services.services[0]["id"]
  }
}
