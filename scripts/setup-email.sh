#!/usr/bin/env bash
# Sets up email after terraform/email is applied. Safe to run again.
#   - makes a key for the sender user once and keeps it in the secrets folder (never in the repo)
#   - gives it to the chat mailer in the cluster (secret chat-mailer/ses)
#   - points Morpheus at Amazon SES, sending as noreply@<domain>
#   - asks Amazon to confirm the addresses given (test mode only sends to confirmed addresses)
# Usage: KUBECONFIG=<kubeconfig> scripts/setup-email.sh <morpheus env file> [address ...]
# Optional: DOMAIN (default kubeforge.live), REGION (default us-west-2), SECRETS (default ~/.local/share/kubecon-demo/secrets)
set -euo pipefail

set -a; . "${1:?morpheus env file}"; set +a; shift
DOMAIN="${DOMAIN:-kubeforge.live}"
REGION="${REGION:-us-west-2}"
SECRETS="${SECRETS:-$HOME/.local/share/kubecon-demo/secrets}"
AWS=(aws --profile "${AWS_PROFILE:-kubecon-demo}" --region "$REGION")
M="${MORPHEUS_URL%/}"
ENVF="$SECRETS/ses.env"

if [ ! -s "$ENVF" ]; then
  echo "==> New key for kubecon-demo-mailer"
  key=$("${AWS[@]}" iam create-access-key --user-name kubecon-demo-mailer --output json)
  id=$(jq -r .AccessKey.AccessKeyId <<<"$key"); secret=$(jq -r .AccessKey.SecretAccessKey <<<"$key")
  # SES SMTP password: made from the secret key (AWS SigV4 recipe, version 4)
  smtp=$(SECRET="$secret" REGION="$REGION" python3 - <<'PY'
import base64, hashlib, hmac, os
def sign(k, m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
s = sign(("AWS4" + os.environ["SECRET"]).encode(), "11111111")
for part in (os.environ["REGION"], "ses", "aws4_request", "SendRawEmail"):
    s = sign(s, part)
print(base64.b64encode(b"\x04" + s).decode())
PY
)
  umask 077
  printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\nSMTP_PASSWORD=%s\n' "$id" "$secret" "$smtp" > "$ENVF"
fi
set -a; . "$ENVF"; set +a

echo "==> Key for the chat mailer"
kubectl create namespace chat-mailer --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n chat-mailer create secret generic ses --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n chat-mailer rollout restart deployment chat-mailer >/dev/null 2>&1 || true

echo "==> Morpheus sends mail through SES"
curl -sf -X PUT -H "Authorization: Bearer $MORPHEUS_TOKEN" -H "Content-Type: application/json" "$M/api/appliance-settings" \
  -d "$(jq -n --arg s "email-smtp.$REGION.amazonaws.com" --arg u "$AWS_ACCESS_KEY_ID" --arg p "$SMTP_PASSWORD" --arg f "noreply@$DOMAIN" \
  '{applianceSettings:{smtpServer:$s, smtpPort:"587", smtpTLS:true, smtpSSL:false, smtpUser:$u, smtpPassword:$p, smtpMailFrom:$f}}')" >/dev/null

for a in "$@"; do
  if "${AWS[@]}" sesv2 get-email-identity --email-identity "$a" >/dev/null 2>&1; then
    echo "==> $a: already asked, status $("${AWS[@]}" sesv2 get-email-identity --email-identity "$a" --query VerifiedForSendingStatus --output text)"
  else
    "${AWS[@]}" sesv2 create-email-identity --email-identity "$a" --tags Key=Project,Value=kubecon-demo >/dev/null
    echo "==> $a: Amazon sent a confirm mail, click the link in it"
  fi
done
echo "Done."
