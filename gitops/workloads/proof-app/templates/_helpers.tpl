{{/*
Single source-of-truth hostname derived from `baseDomain` (values.yaml). Both
templates/httproute.yaml (routing) and templates/certificate.yaml (the cert's
dnsNames) call this helper so the hostname they key off of can never drift.
*/}}
{{- define "proof-app.host" -}}
proof.{{ .Values.baseDomain }}
{{- end -}}
