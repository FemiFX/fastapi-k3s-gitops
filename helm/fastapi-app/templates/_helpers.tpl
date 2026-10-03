{{/*
Shared naming and labels. Helm convention: every resource is prefixed with the
release name, so two releases of the same chart can live side by side without
colliding.
*/}}

{{- define "fastapi-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fastapi-app.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "fastapi-app.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "fastapi-app.labels" -}}
app.kubernetes.io/name: {{ include "fastapi-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: fastapi-docker-traefik
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "fastapi-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fastapi-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
