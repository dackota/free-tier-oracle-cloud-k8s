# free-tier-oracle-cloud-k8s

A Kubernetes homelab running on Oracle Cloud's Always Free tier: 
provisioned with Terraform and managed by ArgoCD via GitOps.

`terraform apply` builds the OKE cluster and its network, then hands ongoing
reconciliation to ArgoCD (the **Bootstrap** step). From there, adding or
changing what runs on the cluster is a git commit under `gitops/`, not a
`terraform apply`.

## Repo layout

```
terraform/    All Terraform HCL: provider/backend config, VCN, OKE cluster,
              node pool, and the ArgoCD Bootstrap.
gitops/
  bootstrap/  The root app-of-apps ArgoCD Application that Terraform's
              Bootstrap step points at.
  platform/   Platform add-ons ArgoCD manages: the Gateway (Traefik),
              cert-manager, Longhorn, metrics-server, ArgoCD self-management.
  workloads/  User applications, managed by ArgoCD like everything else here.
```

## Prerequisites

1. **An OCI account** (tenancy) with the Always Free resources available
   (region matters — not every region has A1.Flex capacity).
2. **An OCI API signing key** for the OCI Terraform provider:
   - OCI Console → Identity & Security → Users → (your user) → API Keys →
     **Add API Key** → generate a new key pair.
   - Download the private key PEM; note the **fingerprint** shown after
     upload.
   - Note your **tenancy OCID** (Console → Profile → Tenancy) and **user
     OCID** (Console → Profile → User Settings).
   - Keep the private key file outside git — see `.gitignore`.
3. **Backend provisioning** (below) — a separate, one-time manual step,
   completed before the first `terraform init`.
4. **Terraform** >= 1.6 installed locally. Applies are run manually from the
   operator's laptop; there is no CI for this repo.
5. **The OCI CLI** (`oci`) installed and on `PATH` — required at *apply* time,
   not just for convenience. The helm and kubectl providers authenticate to the
   freshly-created cluster by exec'ing `oci ce cluster generate-token`, so
   without the `oci` binary the Bootstrap step fails. The providers pass it
   explicit **API-key** credentials from your `TF_VAR_*` values (see
   `terraform/argocd-providers.tf`), so the provider side is self-configuring —
   but for your own `kubectl` access (below) configure the CLI with the same
   API-key (`oci setup config`, API-key auth). Do **not** leave its `DEFAULT`
   profile pointed at a session token (`oci session authenticate`): OKE rejects
   the tokens a session profile mints, surfacing as
   `the server has asked for the client to provide credentials`.
6. **kubectl** installed locally, to reach the cluster after apply.

## Backend provisioning (one-time, manual)

Terraform state for this project is stored remotely in an **OCI Object
Storage bucket**, reached via Terraform's S3-compatible backend — not in git,
and not on HCP Terraform. A Terraform config cannot create the bucket that
holds its own state, so this step is a manual runbook, run once, **before the
first `terraform init`**:

1. **Create the state bucket** (OCI Console → Storage → Object Storage &
   Archive Storage → Buckets → **Create Bucket**):
   - Name it, e.g. `free-tier-oke-terraform-state`.
   - Set **Versioning: Enabled** — this is the only recovery path for state,
     since there is no state locking (see below).
   - Note the **Object Storage Namespace** shown at the top of the Buckets
     page — you'll need it to construct the S3-compatible endpoint URL.
2. **Create a Customer Secret Key** for backend authentication (OCI Console →
   Identity & Security → Users → (your user) → **Customer Secret Keys** →
   **Generate Secret Key**). This is **distinct from the API signing key**
   above: the OCI *provider* authenticates with the API signing key; the S3
   *backend* authenticates with this Customer Secret Key (access key +
   secret key, S3-compatible). Save both values immediately — the secret key
   is shown only once. Never commit either value.

With the bucket and Customer Secret Key created, proceed to the apply flow
below.

## Apply flow

Export the OCI provider's authentication (API signing key) as `TF_VAR_*`, and
the backend's authentication (Customer Secret Key) as the AWS-named
environment variables the S3 backend reads natively:

```sh
# Provider auth — required for every plan/apply.
export TF_VAR_tenancy_ocid="ocid1.tenancy.oc1..xxxxxxxx"
export TF_VAR_user_ocid="ocid1.user.oc1..xxxxxxxx"
export TF_VAR_fingerprint="aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99"
export TF_VAR_private_key_path="$HOME/.oci/oci_api_key.pem"
export TF_VAR_region="us-ashburn-1"          # tenancy's home region; required, no default
export TF_VAR_compartment_ocid="ocid1.compartment.oc1..xxxxxxxx"

# Backend auth (the Customer Secret Key from backend provisioning above).
export AWS_ACCESS_KEY_ID="<customer-secret-access-key-id>"
export AWS_SECRET_ACCESS_KEY="<customer-secret-key>"

# Required for every plan/apply. Newer AWS SDKs default to computing a flexible
# checksum on PutObject, which forces `Content-Encoding: aws-chunked`. OCI Object
# Storage rejects that with `501 NotImplemented: AWS chunked encoding not
# supported`, breaking state uploads. `when_required` stops the SDK from adding
# it; the backend's `skip_s3_checksum = true` (versions.tf) is the other half —
# both are needed.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
```

The state bucket's name, region, and S3-compatible endpoint are
tenancy-specific, so they are **not** hardcoded in `terraform/versions.tf` —
supply them at `init` time via a local, gitignored backend config file
(`*.tfbackend` files are excluded by `.gitignore`):

```sh
cat > terraform/oci.s3.tfbackend <<EOF
bucket = "free-tier-oke-terraform-state"
region = "us-ashburn-1"
endpoints = {
  s3 = "https://<your-object-storage-namespace>.compat.objectstorage.us-ashburn-1.oraclecloud.com"
}
EOF

cd terraform
terraform init -backend-config=oci.s3.tfbackend
terraform plan
terraform apply
```

Copy `terraform/terraform.tfvars.example` to `terraform/terraform.tfvars`
(gitignored) if you'd rather set the provider variables that way instead of
`TF_VAR_*` env vars — never commit the populated file.

Because there is no state locking (OCI's S3-compatible endpoint has no
DynamoDB equivalent), only run `plan`/`apply` from one place at a time.

The same apply also runs the **Bootstrap** step: it installs ArgoCD via
`helm_release` and applies a single bootstrap ArgoCD Application pointing at
`applicationsets/` in this repo (pulled anonymously over public HTTPS — no
repository credential). That directory holds two ApplicationSets
(`platform.yaml`, `workloads.yaml`); each uses a `*/config.yaml` git-files
generator to discover the per-add-on / per-workload chart directories under
`gitops/platform/` and `gitops/workloads/` and generates one ArgoCD Application
apiece — including ArgoCD managing its own Helm release. Adding a platform
add-on or a workload is a new chart directory committed under `gitops/`, not a
second `terraform apply`. `terraform/variables.tf`'s `gitops_repo_url`
defaults to this repo's own URL; override it if you're running from a fork —
and that fork **must be public**. The bootstrap Application pulls anonymously
over HTTPS with no repository credential, so a private repo never syncs: ArgoCD
reports `failed to list refs: authentication required: Repository not found`
and no child Applications appear.

## Connecting to the cluster

`terraform apply` creates the OKE cluster but does **not** write a kubeconfig —
you generate one with the OCI CLI. Both that step and every later `kubectl`
call ultimately exec `oci ce cluster generate-token`, so the CLI's `DEFAULT`
profile must use **API-key** auth. A session-token profile (from
`oci session authenticate`) mints tokens OKE rejects with
`the server has asked for the client to provide credentials`.

`~/.oci/config`'s `DEFAULT` profile should be a plain API-key profile — the
same key you use for `TF_VAR_*`, and crucially **no `security_token_file`
line**:

```ini
[DEFAULT]
user=ocid1.user.oc1..xxxxxxxx
tenancy=ocid1.tenancy.oc1..xxxxxxxx
fingerprint=aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99
key_file=~/.oci/oci_api_key.pem
region=us-ashburn-1
```

Create it with `oci setup config` (choose API-key auth), or write the file
directly. If `oci session authenticate` was ever run, it moves your API-key
profile to `[DEFAULTBACKUP]` and replaces `[DEFAULT]` with a `security_token_file`
one — restore the API-key values under `[DEFAULT]` and drop that line, or the
CLI signs with the (rejected) session token. Verify with `oci os ns get`, which
should print your Object Storage namespace.

Then get the cluster OCID — from the OCI Console (Developer Services →
Kubernetes Clusters → your cluster → **Access Cluster**, which also prints
these exact commands) or from the CLI:

```sh
oci ce cluster list \
  --compartment-id "$TF_VAR_compartment_ocid" \
  --name k8s-cluster --lifecycle-state ACTIVE \
  --query 'data[0].id' --raw-output
```

Write a kubeconfig for it and point kubectl at the public endpoint:

```sh
oci ce cluster create-kubeconfig \
  --cluster-id <cluster-ocid> \
  --file "$HOME/.kube/config" \
  --region "$TF_VAR_region" \
  --token-version 2.0.0 \
  --kube-endpoint PUBLIC_ENDPOINT

kubectl config get-contexts                # note the generated context name
kubectl --context <ctx> get nodes          # expect 2 A1 nodes, STATUS Ready
```

Every `kubectl --context <ctx> ...` command below uses the context this created.

## Accessing the ArgoCD UI (port-forward only)

The ArgoCD UI/API is **not exposed publicly** — no Gateway, HTTPRoute, Ingress,
or public LoadBalancer fronts it, and the `argocd-server` Service stays
`ClusterIP`. Reach it locally instead:

```sh
kubectl --context <ctx> -n argocd port-forward svc/argocd-server 8080:80
```

Then open `http://localhost:8080`. The initial admin password is the
`argocd-server` pod name-derived secret (see the [ArgoCD getting-started
docs](https://argo-cd.readthedocs.io/en/stable/getting_started/#4-login-using-the-cli)):

```sh
kubectl --context <ctx> -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

## OKE node-cycle / upgrade runbook

OKE node pools are cycled manually, one node at a time, to pick up a new
Kubernetes version or node image without an outage:

1. `kubectl --context <ctx> cordon <node>` the node being replaced, then
   `kubectl --context <ctx> drain <node> --ignore-daemonsets --delete-emptydir-data`.
2. In the OCI Console, open the node pool and **terminate** that node
   (do not delete the whole node pool). OKE brings up a replacement node
   automatically per the node pool's configuration.
3. Wait for the new node to reach `Ready`:
   `kubectl --context <ctx> get nodes -w`.
4. **Wait for Longhorn to finish resyncing replicas** onto the new node
   before touching the next one — check the Longhorn UI (or
   `kubectl --context <ctx> -n longhorn-system get volumes.longhorn.io`) for
   all volumes back to `Healthy`/fully-replicated. Cycling the next node
   before resync completes risks a volume with too few healthy replicas.
5. Repeat steps 1-4 for the remaining node(s), one at a time.

## Security

- `.gitignore` is a security control, not a convenience: it excludes Terraform
  state (`*.tfstate*`, `.terraform/`), tfvars (`*.tfvars`, `*.auto.tfvars`),
  OCI API key material (`*.pem`, `oci_api_key*`), local backend config
  (`*.tfbackend`), and kubeconfig. Verify it with
  `scripts/check-gitignore-control.sh`.
- Region and all OCI credentials are supplied via variables/environment —
  never committed. `terraform/terraform.tfvars.example` holds only
  placeholders.
