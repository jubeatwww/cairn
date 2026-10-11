{{/* The cluster's image. The app's backup dumps and restores with the same one (helmfile.yaml.gotmpl
     passes it on), so pg_dump matches the server. */}}
{{- define "postgres.image" -}}
{{ .Values.image }}
{{- end }}
