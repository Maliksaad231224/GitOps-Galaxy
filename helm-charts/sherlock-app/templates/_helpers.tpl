{{- define "sherlock-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "sherlock-app.labels" -}}
helm.sh/chart: {{ include "sherlock-app.name" . }}
{{ include "sherlock-app.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "sherlock-app.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}