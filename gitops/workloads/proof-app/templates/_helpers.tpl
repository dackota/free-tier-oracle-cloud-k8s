{{/*
Single source-of-truth sslip.io hostname (R28) derived from `lbPublicIp`
(values.yaml). Both templates/httproute.yaml (routing) and
templates/certificate.yaml (the cert's dnsNames) call this helper so the
hostname they key off of can never drift apart.
*/}}
{{- define "proof-app.host" -}}
proof.{{ .Values.lbPublicIp }}.sslip.io
{{- end -}}
