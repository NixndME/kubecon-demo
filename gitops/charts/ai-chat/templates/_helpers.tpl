{{- define "ai-chat.labels" -}}
app.kubernetes.io/part-of: ai-chat
kubecon-demo/chat: {{ .Values.name | quote }}
{{- /* Team is optional; an empty order field can arrive as null */}}
{{- $team := toString (.Values.team | default "") }}
kubecon-demo/team: {{ printf "%q" (ternary "" $team (eq $team "null")) }}
{{- end -}}

{{- define "ai-chat.annotations" -}}
kubecon-demo/requested-by: {{ .Values.requestedBy | quote }}
kubecon-demo/owner: {{ printf "%s <%s>" .Values.ownerName .Values.ownerEmail | quote }}
kubecon-demo/model: {{ .Values.model | quote }}
{{- end -}}
