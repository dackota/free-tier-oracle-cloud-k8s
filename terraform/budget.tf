# Budget guardrail (R30): a near-zero-threshold OCI budget as the cost
# backstop behind the free-tier tripwires (A1 shape ≤ 4 OCPU/24 GB, ≤ 200 GB
# block storage, 1 load balancer) — if any of those slip and spend occurs,
# this budget's alert rules fire on both forecasted and actual spend.
#
# Ported from repos/infra/oracle-cloud/budget/oci-budget.tf with one
# deviation required by this project's single-config, single-apply shape
# (ADR 0001):
#   - the reference's backend.tf (a Terraform Cloud `cloud { organization =
#     "homelab" }` block, for its own separate TFC workspace) is dropped
#     entirely — this config already declares one S3-compatible backend for
#     the whole project (see versions.tf); a second/conflicting backend block
#     here is not valid.
#
# OCI Budgets are a tenancy-level resource, not a compartment-level one: the
# Budgets API only accepts the tenancy root for both compartment_id (where
# the budget itself lives) and targets (what it tracks) — a dedicated
# sub-compartment is rejected. So both use var.tenancy_ocid, matching the
# reference exactly, which gives the broadest possible cost tripwire:
# detect any spend anywhere in the tenancy beyond the free tier (R30).
#
# Provider schema confirmed against the pinned oracle/oci ~> 7.0 provider
# (v7.32.0): oci_budget_alert_rule.recipients is a plain string (not a list),
# so passing var.budget_alert_email_address directly is correct. message and
# display_name on the alert rule are optional (computed if omitted).
resource "oci_budget_budget" "cost_tripwire_budget" {
  display_name = "free-tier-budget-guardrail"

  amount       = 1
  reset_period = "MONTHLY"

  compartment_id = var.tenancy_ocid
  target_type    = "COMPARTMENT"
  targets        = [var.tenancy_ocid]
}

# Alert on forecasted spend crossing the near-zero threshold — catches a
# runaway trend before it fully materializes.
resource "oci_budget_alert_rule" "forecast" {
  budget_id = oci_budget_budget.cost_tripwire_budget.id

  type           = "FORECAST"
  threshold      = 1
  threshold_type = "PERCENTAGE"

  recipients = var.budget_alert_email_address
}

# Alert on actual spend crossing the near-zero threshold — catches spend
# that has already happened, independent of the forecast rule.
resource "oci_budget_alert_rule" "actual" {
  budget_id = oci_budget_budget.cost_tripwire_budget.id

  type           = "ACTUAL"
  threshold      = 1
  threshold_type = "PERCENTAGE"

  recipients = var.budget_alert_email_address
}
