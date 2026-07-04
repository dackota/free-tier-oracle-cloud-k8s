# Bootstrap (R17): Terraform's one-time ArgoCD install. This is the seam
# where "Terraform built it" hands off to "ArgoCD manages it" — see
# gitops/platform/argocd/ (the self-management add-on chart, R22) that takes
# over managing this same Helm release once it syncs.
#
# VALUES-SYNC CONTRACT (R17 <-> R22) — read before touching either side:
# local.argocd_helm_values below MUST stay identical to the `argo-cd:` values
# in gitops/platform/argocd/values.yaml, using the same chart version pinned
# here (10.1.1). ArgoCD's first sync of that self-management Application diffs
# against the Helm release this resource already installed; if the chart
# version or values differ, that first sync becomes a real upgrade instead of
# a no-op — and an upgrade that changes an immutable Deployment label
# selector orphans the old ReplicaSet's pods. This is a documented scar from
# the reference EKS setup this project ported from. Change one side, change
# the other in the same commit.
locals {
  argocd_helm_values = {
    configs = {
      params = {
        # No TLS on the Service; acceptable because the UI/API is reached
        # only via `kubectl port-forward` (see README.md), never a public
        # LoadBalancer/Ingress (R31).
        "server.insecure" = "true"
      }
    }

    # No SSO/dex/Okta in v1 — disable dex-server entirely rather than run an
    # idle pod on a 4 OCPU / 24 GB cluster.
    dex = {
      enabled = false
    }

    # No notification channels (Slack/webhook/etc.) configured in v1 — the
    # controller would just idle; skip it to keep the footprint small.
    notifications = {
      enabled = false
    }

    # Modest, homelab-sized requests: this cluster is the full Always Free A1
    # allowance (4 OCPU / 24 GB across 2 nodes), and ArgoCD shares it with
    # every workload it goes on to manage — keep it small, don't
    # over-provision.
    controller = {
      replicas = 1
      resources = {
        requests = {
          cpu    = "100m"
          memory = "256Mi"
        }
      }
    }
    server = {
      resources = {
        requests = {
          cpu    = "50m"
          memory = "128Mi"
        }
      }
    }
    repoServer = {
      resources = {
        requests = {
          cpu    = "50m"
          memory = "128Mi"
        }
      }
    }
    applicationSet = {
      resources = {
        requests = {
          cpu    = "50m"
          memory = "64Mi"
        }
      }
    }
  }
}

# R17: version-pinned ArgoCD install via the argo-cd chart. wait = true blocks
# until the release reports healthy, so anything later in this same apply can
# safely assume ArgoCD's CRDs and Deployments exist. depends_on the node pool
# (not just the cluster): "wait" needs schedulable capacity for ArgoCD's pods
# to reach Ready, and the OKE control plane runs no workloads of its own —
# without this, wait could time out racing a node pool that hasn't finished
# joining yet, even though the cluster resource itself is already "created".
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.1.1" # pinned — see the values-sync contract above
  namespace        = "argocd"
  create_namespace = true

  wait    = true
  timeout = 600

  values = [yamlencode(local.argocd_helm_values)]

  depends_on = [oci_containerengine_node_pool.main]
}

# R18/R21 (revised by ADR 0005): the single bootstrap Application. Applied via
# the kubectl provider (see argocd-providers.tf) so `plan` doesn't need
# argoproj.io CRDs to exist yet — they're installed by helm_release.argocd
# above, at apply time. project: default avoids depending on a custom
# AppProject that would itself have to be ArgoCD-managed from this same repo
# (chicken-and-egg). Points at applicationsets/, a directory of ArgoCD
# ApplicationSets (applicationsets/platform.yaml, applicationsets/workloads.yaml)
# that each discover per-add-on/per-workload chart directories under gitops/ and
# generate one Application apiece — so adding a platform add-on or a workload
# later is a commit under gitops/, never a second `terraform apply` (R21).
resource "kubectl_manifest" "bootstrap" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "bootstrap"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = "HEAD"
        path           = "applicationsets"
        directory = {
          recurse = true
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      # R20: no repository-credential Secret anywhere in this chain — the
      # repo is public (ADR 0003), and every Application in it (this one and
      # its children) pulls over anonymous HTTPS.
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["CreateNamespace=true", "ServerSideApply=true"]
      }
    }
  })

  depends_on = [helm_release.argocd]
}
