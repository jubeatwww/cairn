{{/* Immich's public hostname, e.g. immich.example.com. */}}
{{- define "immich.host" -}}
{{ required "immich.hostname is required (site.yaml)" .Values.immich.hostname }}
{{- end }}

{{/* Settings the server and the database share. */}}
{{- define "immich.dbEnv" -}}
- name: DB_USERNAME
  value: postgres
- name: DB_DATABASE_NAME
  value: immich
{{- end }}
