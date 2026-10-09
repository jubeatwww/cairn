{{/* Home Assistant's hostname, e.g. ha.example.com. */}}
{{- define "home.haHost" -}}
{{ required "homeAssistant.hostname is required (site.yaml)" .Values.homeAssistant.hostname }}
{{- end }}

{{/* The Traefik middleware reference for LAN-only Ingresses in this namespace. */}}
{{- define "home.lanOnly" -}}
{{ .Release.Namespace }}-lan-only@kubernetescrd
{{- end }}
