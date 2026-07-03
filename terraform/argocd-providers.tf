# R19: OKE has no static, long-lived kubeconfig token to hand a provider —
# credentials for the helm/kubernetes/kubectl providers below come from
# `oci ce cluster generate-token`, invoked on demand via each provider's
# `exec` block (OCI's analogue of the reference's `aws eks get-token`). No
# token is ever written to state.
#
# The cluster's CA certificate isn't exposed as a plain resource attribute on
# oci_containerengine_cluster the way EKS exposes certificate_authority[0].data
# — OCI only returns it embedded in a full kubeconfig document, via the
# oci_containerengine_cluster_kube_config data source. So that data source is
# fetched once, purely to pull the CA back out of it; host and cluster id come
# directly off the cluster resource instead of being re-parsed from the same
# document (avoids brittle indexing into the kubeconfig's generated exec args).
#
# Apply-ordering scar: this is a single Terraform config, and the OKE cluster
# lives in the SAME state as everything below — there is no separate "cluster"
# state this bootstrap could depend on the way some multi-stage setups do.
# cluster_id below is a direct reference to oci_containerengine_cluster.main.id
# (a resource attribute, not a name-based lookup), which is what lets
# Terraform's dependency graph do the right thing on a first apply: the
# cluster must be created before this data source can be read, and before any
# resource whose provider config depends on it (helm_release.argocd,
# kubectl_manifest.bootstrap in argocd.tf) can be planned. A name-based
# `data "oci_containerengine_cluster"` lookup was deliberately rejected here —
# it would need a hand-written depends_on to get the same ordering guarantee
# (nothing about looking a cluster up by name implies "wait for the resource
# that creates it"), and a missing depends_on would fail hard on a fresh
# apply. Referencing the resource directly and letting Terraform infer the
# edge is the safer default.
data "oci_containerengine_cluster_kube_config" "main" {
  cluster_id = oci_containerengine_cluster.main.id
}

locals {
  # endpoints[0].public_endpoint is a bare "host:port" with no scheme.
  argocd_cluster_host = "https://${oci_containerengine_cluster.main.endpoints[0].public_endpoint}"

  argocd_cluster_ca_certificate = base64decode(
    yamldecode(data.oci_containerengine_cluster_kube_config.main.content)["clusters"][0]["cluster"]["certificate-authority-data"]
  )

  # Shared across all three providers below so the exec invocation can't
  # drift between them.
  argocd_exec_args = ["ce", "cluster", "generate-token", "--cluster-id", oci_containerengine_cluster.main.id, "--region", var.region]
}

# helm provider v3 schema: Kubernetes connection settings live under a
# `kubernetes = { ... }` object, not a nested block. v3 rewrote this provider
# on Terraform's plugin framework, which changed the shape from v2's
# `kubernetes { ... }` block — the kubernetes/kubectl providers below still
# use the classic block syntax.
provider "helm" {
  kubernetes = {
    host                   = local.argocd_cluster_host
    cluster_ca_certificate = local.argocd_cluster_ca_certificate

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "oci"
      args        = local.argocd_exec_args
    }
  }
}

provider "kubernetes" {
  host                   = local.argocd_cluster_host
  cluster_ca_certificate = local.argocd_cluster_ca_certificate

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "oci"
    args        = local.argocd_exec_args
  }
}

# R18: kubectl provider defers CRD schema validation to apply time — on a
# fresh cluster, argoproj.io CRDs don't exist until helm_release.argocd (in
# argocd.tf) has applied them, so this is the only provider that can apply the
# bootstrap Application without `plan` failing schema validation against
# CRDs that aren't there yet. load_config_file = false because auth is fully
# explicit above (host/CA/exec) — never fall back to a local kubeconfig.
provider "kubectl" {
  host                   = local.argocd_cluster_host
  cluster_ca_certificate = local.argocd_cluster_ca_certificate
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "oci"
    args        = local.argocd_exec_args
  }
}
