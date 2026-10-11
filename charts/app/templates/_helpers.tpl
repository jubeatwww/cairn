{{/* Labels selecting one workload's pods. */}}
{{- define "app.selector" -}}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/name: {{ .name }}
{{- end }}

{{/* The Secret with the values from site.secret.yaml. */}}
{{- define "app.secretName" -}}
{{ .Release.Name }}-secrets
{{- end }}

{{/* A workload's hostname, from the app's entry in site.yaml. */}}
{{- define "app.host" -}}
{{ required (printf "apps.%s.hosts.%s is required (site.yaml)" .root.Release.Name .name) (index (.root.Values.hosts | default dict) .name) }}
{{- end }}
