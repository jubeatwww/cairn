{{/* The cluster's image. The dump and restore jobs use it too, so their client matches the server. */}}
{{- define "postgres.image" -}}
{{ .Values.image }}
{{- end }}

{{/* The NFS share for the dumps; each cluster writes to <backupPath>/<namespace>/. */}}
{{- define "postgres.nas" -}}
server: {{ required "nas.server is required (site.yaml)" (.Values.nas | default dict).server }}
path: {{ required "postgres.backupPath is required (site.yaml)" (.Values.postgres | default dict).backupPath }}
{{- end }}

{{/* Shell lines for the jobs: wait for the server. A new pod's first connections are refused for a
     few seconds, until k3s's network policy controller adds it to the NetworkPolicy's allowed set. */}}
{{- define "postgres.waitReady" -}}
for _ in $(seq 30); do pg_isready --quiet && break; sleep 1; done
{{- end }}

{{/* libpq settings for the dump and restore jobs: the app owner, through the read-write Service. */}}
{{- define "postgres.pgEnv" -}}
{{- range $var, $key := dict "PGHOST" "host" "PGPORT" "port" "PGDATABASE" "dbname" "PGUSER" "username" "PGPASSWORD" "password" }}
- name: {{ $var }}
  valueFrom:
    secretKeyRef:
      name: postgres-app
      key: {{ $key }}
{{- end }}
{{- end }}
