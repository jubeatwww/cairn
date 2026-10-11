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
