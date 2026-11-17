{{- define "resaflow.fullname" -}}resaflow{{- end -}}

{{- define "resaflow.labels" -}}
app.kubernetes.io/name: resaflow
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: resaflow
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
resaflow.io/environment: {{ .Values.environment }}
{{- end -}}

{{/* Sélecteur stable d'un composant : include "resaflow.selector" (dict "ctx" . "component" "api") */}}
{{- define "resaflow.selector" -}}
app.kubernetes.io/name: resaflow
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "resaflow.image" -}}
{{- $tag := .tag | default .ctx.Values.image.tag -}}
{{- if .ctx.Values.image.registry -}}
{{ printf "%s/%s:%s" .ctx.Values.image.registry .name $tag }}
{{- else -}}
{{ printf "%s:%s" .name $tag }}
{{- end -}}
{{- end -}}

{{/* Durcissement commun des conteneurs (Pod Security Standards "restricted") */}}
{{- define "resaflow.containerSecurity" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  capabilities:
    drop: ["ALL"]
{{- end -}}

{{- define "resaflow.podSecurity" -}}
securityContext:
  runAsNonRoot: true
  runAsUser: {{ .uid | default 10001 }}
  runAsGroup: {{ .uid | default 10001 }}
  fsGroup: {{ .uid | default 10001 }}
  seccompProfile:
    type: RuntimeDefault
{{- end -}}

{{- define "resaflow.secretName" -}}resaflow-secrets{{- end -}}

{{/* Variables d'environnement communes API / worker / beat / jobs */}}
{{- define "resaflow.backendEnv" -}}
envFrom:
  - configMapRef:
      name: resaflow-config
env:
  - name: DATABASE_URL
    valueFrom: { secretKeyRef: { name: {{ include "resaflow.secretName" . }}, key: DATABASE_URL } }
  - name: JWT_SECRET
    valueFrom: { secretKeyRef: { name: {{ include "resaflow.secretName" . }}, key: JWT_SECRET } }
  - name: CELERY_BROKER_URL
    valueFrom: { secretKeyRef: { name: {{ include "resaflow.secretName" . }}, key: CELERY_BROKER_URL } }
{{- end -}}

{{/* Volume CSI Key Vault : le montage déclenche la synchronisation vers le Secret Kubernetes */}}
{{- define "resaflow.kvVolume" -}}
{{- if .Values.keyVault.enabled }}
- name: kv-secrets
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: true
    volumeAttributes:
      secretProviderClass: resaflow-kv
{{- end }}
{{- end -}}

{{- define "resaflow.kvMount" -}}
{{- if .Values.keyVault.enabled }}
- name: kv-secrets
  mountPath: /mnt/secrets
  readOnly: true
{{- end }}
{{- end -}}

{{- define "resaflow.podLabels" -}}
{{- if .ctx.Values.keyVault.enabled }}
azure.workload.identity/use: "true"
{{- end }}
{{- end -}}

{{- define "resaflow.spread" -}}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        {{- include "resaflow.selector" . | nindent 8 }}
{{- end -}}
