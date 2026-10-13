{{/* The ClickHouse server in this namespace (charts/clickhouse, Secret clickhouse-app), as
     market-tap reads it. */}}
{{- define "aetherium.clickhouseEnv" -}}
{{- range $var, $key := dict "CLICKHOUSE_URL" "url" "CLICKHOUSE_DB" "database" "CLICKHOUSE_USER" "username" "CLICKHOUSE_PASSWORD" "password" }}
- name: {{ $var }}
  valueFrom:
    secretKeyRef:
      name: clickhouse-app
      key: {{ $key }}
{{- end }}
{{- end }}

{{/* The Postgres cluster in this namespace (charts/postgres-cluster). */}}
{{- define "aetherium.databaseEnv" -}}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: postgres-app
      key: uri
{{- end }}

{{/* Shell lines for curl: its credentials for the ClickHouse server from the environment, in a
     config file written by the shell's printf rather than in curl's arguments. */}}
{{- define "aetherium.curlAuth" -}}
printf 'user = "%s:%s"\n' "$CLICKHOUSE_USER" "$CLICKHOUSE_PASSWORD" > /tmp/curlrc
{{- end }}
