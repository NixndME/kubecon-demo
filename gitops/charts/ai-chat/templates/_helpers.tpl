{{- define "ai-chat.labels" -}}
app.kubernetes.io/part-of: ai-chat
kubecon-demo/chat: {{ .Values.name | quote }}
kubecon-demo/team: {{ .Values.team | quote }}
{{- end -}}

{{- define "ai-chat.annotations" -}}
kubecon-demo/requested-by: {{ .Values.requestedBy | quote }}
kubecon-demo/owner: {{ printf "%s <%s>" .Values.ownerName .Values.ownerEmail | quote }}
kubecon-demo/model: {{ .Values.model | quote }}
{{- end -}}
