{{/* Chart name (overridable) */}}
{{- define "zomboid.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified app name */}}
{{- define "zomboid.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "zomboid.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels */}}
{{- define "zomboid.labels" -}}
helm.sh/chart: {{ include "zomboid.chart" . }}
{{ include "zomboid.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Selector labels */}}
{{- define "zomboid.selectorLabels" -}}
app.kubernetes.io/name: {{ include "zomboid.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Name of the Secret holding the passwords (user-supplied or chart-managed) */}}
{{- define "zomboid.secretName" -}}
{{- default (include "zomboid.fullname" .) .Values.auth.existingSecret -}}
{{- end -}}

{{/*
Render one scalar as plain text. Bare YAML numbers reach Helm as float64, so a
workshop ID like 2392709985 would otherwise print as 2.392709985e+09.
*/}}
{{- define "zomboid.scalar" -}}
{{- if kindIs "float64" . -}}
{{- if eq (floor .) . -}}{{- int64 . -}}{{- else -}}{{- . -}}{{- end -}}
{{- else -}}
{{- . -}}
{{- end -}}
{{- end -}}

{{/* Workshop item IDs joined with ";" */}}
{{- define "zomboid.workshopIds" -}}
{{- $ids := list -}}
{{- range .Values.mods.workshopIds -}}
{{- $ids = append $ids (include "zomboid.scalar" .) -}}
{{- end -}}
{{- join ";" $ids -}}
{{- end -}}

{{/* server.iniOverrides map -> newline-separated Key=Value lines */}}
{{- define "zomboid.iniOverrides" -}}
{{- $lines := list -}}
{{- range $k, $v := .Values.server.iniOverrides -}}
{{- $lines = append $lines (printf "%s=%s" $k (include "zomboid.scalar" $v)) -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}

{{/* sandbox map -> newline-separated Key=Value lines; one level of nesting becomes Group.Key */}}
{{- define "zomboid.sandboxOverrides" -}}
{{- $lines := list -}}
{{- range $k, $v := .Values.sandbox -}}
{{- if kindIs "map" $v -}}
{{- range $ik, $iv := $v -}}
{{- $lines = append $lines (printf "%s.%s=%s" $k $ik (include "zomboid.scalar" $iv)) -}}
{{- end -}}
{{- else -}}
{{- $lines = append $lines (printf "%s=%s" $k (include "zomboid.scalar" $v)) -}}
{{- end -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}
