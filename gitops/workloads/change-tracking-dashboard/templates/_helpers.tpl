{{/*
Single source-of-truth hostname derived from `baseDomain` (values.yaml). Both
templates/httproute.yaml (routing) and templates/certificate.yaml (the cert's
dnsNames) call this helper so the hostname they key off of can never drift.

Named `ctd.host` (NOT `change-tracking-dashboard.host`): Helm template names are
global across a chart AND its subcharts, and the vendored subchart is also named
`change-tracking-dashboard` — a distinct prefix here avoids any collision with a
subchart helper.
*/}}
{{- define "ctd.host" -}}
changes.{{ .Values.baseDomain }}
{{- end -}}
