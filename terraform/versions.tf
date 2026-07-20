# State backend (ADR 0001): OCI Object Storage, reached via Terraform's
# S3-compatible backend. Backend provisioning (the bucket + Customer Secret
# Key) is a manual, one-time runbook — see README.md — and must happen before
# the first `terraform init` here, because this config cannot create the
# bucket that holds its own state.
#
# `bucket`, `region`, and `endpoints` are tenancy-specific and deliberately
# left out of this committed block; supply them at `terraform init` time via
# `-backend-config` (see README.md for the exact command). The backend's
# credentials (an OCI Customer Secret Key — distinct from the provider's API
# signing key below) come from the AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
# environment variables, which the s3 backend reads natively, and are never
# committed.
terraform {
  required_version = ">= 1.6"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.0"
    }

    # Bootstrap (R17-R19): install and manage ArgoCD on the OKE cluster this
    # same config creates. See argocd-providers.tf for how these two are
    # configured (OKE exec-token auth) and argocd.tf for what they apply.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1"
    }
    # gavinbunney/kubectl (R18), not hashicorp/kubernetes's own manifest
    # resource: it defers CRD schema validation to apply time, so `plan`
    # doesn't fail on a fresh cluster with no argoproj.io CRDs yet.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19"
    }
  }

  backend "s3" {
    key = "terraform.tfstate"

    # OCI's S3-compatible endpoint (R2): path-style addressing, and skip the
    # AWS-specific checks that don't apply to a non-AWS S3-compat provider.
    use_path_style              = true
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true

    # Newer AWS SDKs (bundled since TF ~1.11) compute a flexible checksum on
    # PutObject, which forces `Content-Encoding: aws-chunked`. OCI Object
    # Storage rejects that with `501 NotImplemented: AWS chunked encoding not
    # supported`, so disable the checksum for state uploads. The
    # AWS_REQUEST_CHECKSUM_CALCULATION env var does NOT help — the backend sets
    # the SDK's checksum mode explicitly unless this flag is set.
    skip_s3_checksum = true

    # OCI's S3-compat endpoint doesn't implement AWS STS, which the backend
    # otherwise uses to resolve the caller's account ID.
    skip_requesting_account_id = true

    # No state locking (R2): OCI's S3-compatible endpoint has no DynamoDB
    # equivalent, and this is a single-operator config (ADR 0001) — no
    # dynamodb_table / use_lockfile.
  }
}
