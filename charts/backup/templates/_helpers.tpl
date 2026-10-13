{{/* The NFS share for the backups; this release writes to <backup.path>/<name>/. */}}
{{- define "backup.nas" -}}
server: {{ required "nas.server is required (site.yaml)" (.Values.nas | default dict).server }}
path: {{ required "backup.path is required (site.yaml)" (.Values.backup | default dict).path }}
{{- end }}

{{- define "backup.dir" -}}
/backup/{{ required "name is required (set by helmfile.yaml.gotmpl)" .Values.name }}
{{- end }}

{{/* Shell lines: wait for the Postgres server. A new pod's first connections are refused for a few
     seconds, until k3s's network policy controller adds it to the NetworkPolicy's allowed set. */}}
{{- define "backup.waitReady" -}}
for _ in $(seq 30); do pg_isready --quiet && break; sleep 1; done
{{- end }}

{{/* libpq settings: the app's database owner, through the read-write Service. */}}
{{- define "backup.pgEnv" -}}
{{- range $var, $key := dict "PGHOST" "host" "PGPORT" "port" "PGDATABASE" "dbname" "PGUSER" "username" "PGPASSWORD" "password" }}
- name: {{ $var }}
  valueFrom:
    secretKeyRef:
      name: postgres-app
      key: {{ $key }}
{{- end }}
{{- end }}

{{/* The ClickHouse server's credentials (Secret clickhouse-app, charts/clickhouse). */}}
{{- define "backup.chEnv" -}}
{{- range $var, $key := dict "CH_HOST" "host" "CH_USER" "username" "CH_PASSWORD" "password" "CH_DATABASE" "database" }}
- name: {{ $var }}
  valueFrom:
    secretKeyRef:
      name: clickhouse-app
      key: {{ $key }}
{{- end }}
{{- end }}

{{/* Shell lines: ch, clickhouse-client signed in to the server (the password in a file, written by
     the shell's printf, not in any command's arguments), once the server answers. Without TZ: the
     client takes it for a zone name, and the POSIX form the dates use isn't one. */}}
{{- define "backup.chClient" -}}
printf '<config><host>%s</host><user>%s</user><password>%s</password></config>\n' "$CH_HOST" "$CH_USER" "$CH_PASSWORD" > /tmp/client.xml
ch() { env -u TZ clickhouse-client --config-file=/tmp/client.xml "$@"; }
for _ in $(seq 60); do ch --query 'SELECT 1' > /dev/null 2>&1 && break; sleep 2; done
{{- end }}

{{/* The pod's volumes: each PVC, and the NAS. A backup only reads the PVCs, a restore only reads
     the NAS; the containers' mounts say so. The PVCs themselves stay read-write: an lvm volume is
     mounted per pod from the device, and ext4 refuses a read-only mount of a device its app already
     has mounted read-write. Called with dict "root" $ "restore" bool. */}}
{{- define "backup.volumes" -}}
{{- range $pvc, $_ := .root.Values.volumes }}
- name: {{ $pvc }}
  persistentVolumeClaim:
    claimName: {{ $pvc }}
{{- end }}
- name: nas
  nfs:
    {{- include "backup.nas" .root | nindent 4 }}
    readOnly: {{ $.restore }}
{{- end }}

{{/* Where the pod mounts them: each PVC at /data/<pvc>, the NAS at /backup. */}}
{{- define "backup.mounts" -}}
{{- range $pvc, $_ := .root.Values.volumes }}
- name: {{ $pvc }}
  mountPath: /data/{{ $pvc }}
  readOnly: {{ not $.restore }}
{{- end }}
- name: nas
  mountPath: /backup
  readOnly: {{ $.restore }}
{{- end }}
