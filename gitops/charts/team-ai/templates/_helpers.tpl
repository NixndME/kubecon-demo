{{- define "team-ai.labels" -}}
app.kubernetes.io/part-of: team-ai
kubecon-demo/team: {{ .Values.team | quote }}
{{- if .Values.requestedBy }}
kubecon-demo/requested-by: {{ .Values.requestedBy | quote }}
{{- end }}
{{- end -}}
