{{/* Solver names in use: every zone's, plus the default. */}}
{{- define "cluster.solversInUse" -}}
{{- $acme := .Values.acme | default dict }}
{{- $used := values ($acme.zones | default dict) }}
{{- with $acme.defaultSolver }}{{ $used = append $used . }}{{ end }}
{{- $used | uniq | sortAlpha | toJson }}
{{- end }}
