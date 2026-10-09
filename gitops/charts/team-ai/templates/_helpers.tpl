{{- define "team-ai.labels" -}}
app.kubernetes.io/part-of: team-ai
kubecon-demo/team: {{ .Values.team | quote }}
{{- end -}}

{{- define "team-ai.annotations" -}}
kubecon-demo/requested-by: {{ .Values.requestedBy | quote }}
kubecon-demo/owner: {{ printf "%s <%s>" .Values.ownerName .Values.ownerEmail | quote }}
kubecon-demo/model: {{ .Values.model | quote }}
{{- end -}}
