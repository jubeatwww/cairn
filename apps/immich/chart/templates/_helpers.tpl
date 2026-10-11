{{/* Immich's public hostname, e.g. immich.example.com. */}}
{{- define "immich.host" -}}
{{ required (printf "apps.%s.hostname is required (site.yaml)" .Release.Name) .Values.hostname }}
{{- end }}

{{/* Settings the server and the database share. */}}
{{- define "immich.dbEnv" -}}
- name: DB_USERNAME
  value: postgres
- name: DB_DATABASE_NAME
  value: immich
{{- end }}
