{{/* Home Assistant's hostname, e.g. ha.example.com. */}}
{{- define "home.haHost" -}}
{{ required "homeAssistant.host is required (site.yaml)" .Values.homeAssistant.host }}.{{ required "domain is required (site.yaml)" .Values.domain }}
{{- end }}

{{/* The Traefik middleware reference for LAN-only Ingresses in this namespace. */}}
{{- define "home.lanOnly" -}}
{{ .Release.Namespace }}-lan-only@kubernetescrd
{{- end }}
