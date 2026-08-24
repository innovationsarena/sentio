#!/usr/bin/env bash
# Full round-trip check against a running compose stack.
#
#   docker compose -f docker-compose.yml -f docker-compose.test.yml up -d
#   scripts/e2e/run-e2e.sh
#
# Inbound   host SMTP client ──► sentio :25 ──► pipeline ──► inbound route ──► webhook-sink
# Outbound  host HTTP client ──► API /v1/messages/send ──► relay ──► mailpit
#
# Nothing leaves the docker network: delivery.relay short-circuits MX
# resolution, and the fixtures live under the reserved .test TLD.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SMTP_PORT="$(smtp_port)"
STAMP="$(date +%s)-$$"
IN_SUBJECT="e2e-inbound-$STAMP"
OUT_SUBJECT="e2e-outbound-$STAMP"

preflight() {
    info "preflight"
    local ready
    ready="$(curl -sS -m 10 "$API_BASE/health/ready" || true)"
    if [ "$(printf '%s' "$ready" | jqf "d['status']")" = "ok" ]; then
        pass "api ready: $ready"
    else
        fail "api not ready: ${ready:-<no response>}"; return 1
    fi
    if curl -sS -m 10 -o /dev/null "$MAILPIT_URL/api/v1/messages"; then
        pass "mailpit reachable at $MAILPIT_URL"
    else
        fail "mailpit unreachable at $MAILPIT_URL - is the test overlay up?"; return 1
    fi
    # A relay that is not configured would send real mail to real MX hosts.
    local relay
    relay="$(dc exec -T sentio printenv SENTIO__DELIVERY__RELAY__ENABLED 2>/dev/null || true)"
    if [ "$relay" = "true" ]; then
        pass "outbound relay is enabled (no mail can reach the internet)"
    else
        fail "relay NOT enabled - refusing to run, outbound would hit real MX hosts"; return 1
    fi
}

test_inbound() {
    info "inbound: host :$SMTP_PORT --> $RECV_DOMAIN"
    local cid
    if ! cid="$("$REPO_ROOT/scripts/e2e/smtp-send.py" \
                    --host 127.0.0.1 --port "$SMTP_PORT" \
                    --from "alice@$SEND_DOMAIN" --to "support@$RECV_DOMAIN" \
                    --subject "$IN_SUBJECT" --body 'inbound body from host')"; then
        fail "SMTP send rejected"; return 1
    fi
    pass "message accepted by the MX listener (corr $cid)"

    _stored() {
        api GET "/v1/messages?direction=inbound&limit=25" \
          | python3 -c "
import json,sys
subj=sys.argv[1]
sys.exit(0 if any(m.get('subject')==subj for m in json.load(sys.stdin)['data']) else 1)
" "$IN_SUBJECT"
    }
    if wait_for "inbound message to be stored" 45 _stored; then
        pass "message persisted and visible via GET /v1/messages"
    else
        fail "message never appeared in the API"; return 1
    fi

    if dc logs sentio --since 5m 2>&1 \
         | grep -q 'webhook dispatched successfully'; then
        pass "inbound route dispatched to the webhook sink"
    else
        fail "no successful webhook dispatch in the sentio log"
    fi
}

test_outbound() {
    info "outbound: API --> relay --> mailpit"
    local resp id
    resp="$(api POST /v1/messages/send -d "{
        \"from\":\"alice@$SEND_DOMAIN\",
        \"to\":[\"bob@elsewhere.test\"],
        \"subject\":\"$OUT_SUBJECT\",
        \"text\":\"outbound body via relay\",
        \"metadata\":{\"probe\":\"e2e\"}
    }")"
    id="$(printf '%s' "$resp" | jqf "d['data']['id']")"
    if [ -z "$id" ]; then fail "send rejected: $resp"; return 1; fi
    pass "accepted for delivery (id $id)"

    _in_mailpit() {
        curl -sS -m 10 "$MAILPIT_URL/api/v1/messages" \
          | python3 -c "
import json,sys
subj=sys.argv[1]
sys.exit(0 if any(m['Subject']==subj for m in json.load(sys.stdin)['messages']) else 1)
" "$OUT_SUBJECT"
    }
    if wait_for "mailpit to receive the message" 60 _in_mailpit; then
        pass "mailpit received the outbound message"
    else
        fail "mailpit never received it"
        dc logs sentio --since 3m 2>&1 | grep -iE 'deliver|relay' | tail -5 >&2
        return 1
    fi

    # DKIM proves the signing path ran, not just that bytes moved.
    local mid raw
    mid="$(curl -sS -m 10 "$MAILPIT_URL/api/v1/messages" \
           | python3 -c "
import json,sys
subj=sys.argv[1]
print(next(m['ID'] for m in json.load(sys.stdin)['messages'] if m['Subject']==subj))
" "$OUT_SUBJECT")"
    raw="$(curl -sS -m 10 "$MAILPIT_URL/api/v1/message/$mid/raw" || true)"
    if printf '%s' "$raw" | grep -qi '^DKIM-Signature:'; then
        pass "delivered message carries a DKIM-Signature"
    else
        fail "no DKIM-Signature on the delivered message"
    fi
}


test_attachment() {
    info "attachment: host :$SMTP_PORT --> stored in the object store --> back out"
    local src="/tmp/sentio-e2e-attach-$STAMP.bin"
    head -c 20000 /dev/urandom > "$src"
    local want
    want="$(sha256sum "$src" | cut -d' ' -f1)"

    local subject="e2e-attach-$STAMP"
    if ! "$REPO_ROOT/scripts/e2e/smtp-send.py" \
            --host 127.0.0.1 --port "$SMTP_PORT" \
            --from "alice@$SEND_DOMAIN" --to "support@$RECV_DOMAIN" \
            --subject "$subject" --body 'body with an attachment' \
            --attach "$src" >/dev/null; then
        fail "SMTP rejected a message with an attachment"; rm -f "$src"; return 1
    fi
    pass "message with a 20 kB attachment accepted"

    _find_id() {
        api GET "/v1/messages?direction=inbound&limit=25" | python3 -c "
import json,sys
subj=sys.argv[1]
m=[x['id'] for x in json.load(sys.stdin)['data'] if x.get('subject')==subj]
print(m[0] if m else '', end='')
sys.exit(0 if m else 1)
" "$subject"
    }
    if ! wait_for "the message to be stored" 45 _find_id; then
        fail "message never appeared"; rm -f "$src"; return 1
    fi
    local mid; mid="$(_find_id)"

    # The attachment row proves it was parsed out and scanned; scan_status
    # comes from ClamAV, so a "clean" here also exercises the AV path.
    local meta; meta="$(api GET "/v1/messages/$mid/attachments")"
    local aid size scan
    aid="$(printf '%s' "$meta"  | jqf "d['data'][0]['id']")"
    size="$(printf '%s' "$meta" | jqf "d['data'][0]['size']")"
    scan="$(printf '%s' "$meta" | jqf "d['data'][0]['scan_status']")"
    if [ -z "$aid" ]; then fail "no attachment recorded on the message"; rm -f "$src"; return 1; fi
    pass "attachment recorded (size $size, scan $scan)"

    # Round-trip the bytes. Anything that mangles storage or retrieval - an
    # encoding slip, a truncated upload - shows up as a checksum mismatch.
    local out="/tmp/sentio-e2e-attach-out-$STAMP.bin"
    api GET "/v1/messages/$mid/attachments/$aid" --output "$out" >/dev/null
    local got; got="$(sha256sum "$out" | cut -d' ' -f1)"
    if [ "$want" = "$got" ]; then
        pass "attachment round-tripped byte for byte"
    else
        fail "attachment differs: sent $want, got $got"
    fi

    # store_raw_eml keeps the original alongside the parsed parts.
    local raw="/tmp/sentio-e2e-raw-$STAMP.eml"
    api GET "/v1/messages/$mid/raw" --output "$raw" >/dev/null
    if grep -q 'Content-Transfer-Encoding: base64' "$raw"; then
        pass "raw message archived with the encoded attachment"
    else
        fail "raw message missing or not archived"
    fi
    rm -f "$src" "$out" "$raw"
}


# GTUBE and EICAR are the standard "any scanner must flag these" strings. They
# turn "the container is healthy" into "the scanner is actually consulted",
# which is the distinction that hid a real bug: every message scored -0.1
# because inbound dropped the CRLF ending the last body line.
test_scanning() {
    info "scanning: rspamd scores, ClamAV rejects"

    local gtube='XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X'
    local subject="e2e-gtube-$STAMP"
    "$REPO_ROOT/scripts/e2e/smtp-send.py" --host 127.0.0.1 --port "$SMTP_PORT" \
        --from "spam@$SEND_DOMAIN" --to "support@$RECV_DOMAIN" \
        --subject "$subject" --body "$gtube" >/dev/null || true

    _scored() {
        api GET "/v1/messages?direction=inbound&limit=25" | python3 -c "
import json,sys
subj=sys.argv[1]
m=[x for x in json.load(sys.stdin)['data'] if x.get('subject')==subj]
sys.exit(0 if m and (m[0].get('spam_score') or 0) > 10 else 1)
" "$subject"
    }
    if wait_for "rspamd to score GTUBE" 45 _scored; then
        local score
        score="$(api GET "/v1/messages?direction=inbound&limit=25" | python3 -c "
import json,sys
subj=sys.argv[1]
print([x['spam_score'] for x in json.load(sys.stdin)['data'] if x.get('subject')==subj][0])
" "$subject")"
        pass "GTUBE scored $score (rspamd is consulted, not stubbed)"
    else
        fail "GTUBE did not score above 10 - rspamd is not scoring this message"
    fi

    # EICAR is the one scanner verdict Sentio does enforce: it rejects in-band.
    local eicar_out
    eicar_out="$(python3 - "$SMTP_PORT" "$SEND_DOMAIN" "$RECV_DOMAIN" <<'EOF'
import smtplib, sys
from email.message import EmailMessage
port, sd, rd = int(sys.argv[1]), sys.argv[2], sys.argv[3]
EICAR = r'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'
m = EmailMessage()
m['From'] = f'virus@{sd}'; m['To'] = f'support@{rd}'; m['Subject'] = 'eicar'
m.set_content('x')
m.add_attachment(EICAR.encode(), maintype='application',
                 subtype='octet-stream', filename='eicar.com')
try:
    with smtplib.SMTP('127.0.0.1', port, timeout=45) as s:
        s.send_message(m)
    print('ACCEPTED')
except smtplib.SMTPResponseException as e:
    print(f'REJECTED {e.smtp_code}')
EOF
)"
    case "$eicar_out" in
        REJECTED\ 5*) pass "EICAR rejected in-band (${eicar_out#REJECTED })" ;;
        *)            fail "EICAR was not rejected: $eicar_out" ;;
    esac
}

# The signature is the whole security of the events endpoint. Recomputing it
# over the raw bytes is the only check worth having - comparing against a
# re-serialised body would pass even if the scheme were wrong.
test_webhook_signature() {
    info "event webhook: HMAC over the raw body"
    local gw; gw="$(docker_gateway)"
    if [ -z "$gw" ]; then skip "webhook signature (no docker gateway address)"; return 0; fi

    local cap="/tmp/sentio-e2e-hook-$STAMP"
    rm -f "$cap" "$cap.headers"
    python3 - "$cap" <<'EOF' &
import http.server, json, sys
OUT = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        open(OUT, 'wb').write(raw)
        json.dump({k.lower(): v for k, v in self.headers.items()},
                  open(OUT + '.headers', 'w'))
        self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
    def log_message(self, *a): pass
http.server.HTTPServer(('0.0.0.0', 19999), H).serve_forever()
EOF
    local srv=$!
    sleep 2

    local secret
    secret="$(api POST /v1/webhooks -d "{\"url\":\"http://$gw:19999/\",\"event_types\":[\"queued\",\"delivered\",\"bounced\"]}" \
              | jqf "d['data']['signing_secret']")"
    if [ -z "$secret" ]; then kill "$srv" 2>/dev/null; fail "could not subscribe a webhook"; return 1; fi

    api POST /v1/messages/send -d "{
        \"from\":\"alice@$SEND_DOMAIN\",\"to\":[\"hook@elsewhere.test\"],
        \"subject\":\"e2e-hook-$STAMP\",\"text\":\"x\"}" >/dev/null

    local i=0
    while [ ! -f "$cap" ] && [ "$i" -lt 30 ]; do sleep 2; i=$((i+1)); done
    kill "$srv" 2>/dev/null

    if [ ! -f "$cap" ]; then fail "no webhook delivery captured"; return 1; fi
    if python3 - "$cap" "$secret" <<'EOF'
import json, sys, hmac, hashlib
cap, secret = sys.argv[1], sys.argv[2]
raw = open(cap, 'rb').read()
h = json.load(open(cap + '.headers'))
need = ('x-sentio-event', 'x-sentio-timestamp', 'x-sentio-nonce', 'x-sentio-signature')
if any(k not in h for k in need):
    print('missing headers:', [k for k in need if k not in h]); sys.exit(1)
msg = f"{h['x-sentio-timestamp']}.{h['x-sentio-nonce']}.".encode() + raw
want = hmac.new(secret.encode(), msg, hashlib.sha256).hexdigest()
sys.exit(0 if hmac.compare_digest(want, h['x-sentio-signature']) else 1)
EOF
    then pass "signature recomputes over the raw body"
    else fail "signature did not verify"; fi
    rm -f "$cap" "$cap.headers"
}

# Skipped unless a certificate is mounted, which the default stack does not do.
test_tls_and_auth() {
    info "TLS and SMTP AUTH"
    local sub; sub="$(submission_port)"
    if ! dc exec -T sentio sh -c 'test -r /etc/sentio/tls/cert.pem' 2>/dev/null; then
        skip "TLS and AUTH (no certificate at /etc/sentio/tls - see the README)"
        return 0
    fi

    local user="e2e-auth-$STAMP@$SEND_DOMAIN" pw="pw-$STAMP"
    api POST "/v1/tenants/$TENANT_ID/smtp-credentials" \
        -d "{\"username\":\"$user\",\"password\":\"$pw\"}" >/dev/null

    local out
    out="$(python3 - "$sub" "$user" "$pw" <<'EOF'
import smtplib, ssl, sys
port, user, pw = int(sys.argv[1]), sys.argv[2], sys.argv[3]
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
try:
    with smtplib.SMTP('127.0.0.1', port, timeout=45) as s:
        s.ehlo()
        # Credentials must never be solicited before the channel is encrypted.
        if 'auth' in s.esmtp_features:
            print('AUTH_BEFORE_TLS'); sys.exit(0)
        s.starttls(context=ctx); s.ehlo()
        if 'auth' not in s.esmtp_features:
            print('NO_AUTH_AFTER_TLS'); sys.exit(0)
        s.login(user, pw)
        print('OK')
except Exception as e:
    print(f'ERR {type(e).__name__}: {e}')
EOF
)"
    case "$out" in
        OK)               pass "STARTTLS upgrade and AUTH accepted on $sub" ;;
        AUTH_BEFORE_TLS)  fail "AUTH advertised before STARTTLS - credentials solicited in cleartext" ;;
        *)                fail "STARTTLS/AUTH failed: $out" ;;
    esac
}

# Failed logins must leave a trace, or the ban tier has nothing to act on.
test_abuse_tracking() {
    info "abuse tier: Redis records what it sees"
    local before after
    before="$(redis_cli --scan --pattern 'sentio:smtp:rate:conn:*' --count 500 | wc -l)"
    "$REPO_ROOT/scripts/e2e/smtp-send.py" --host 127.0.0.1 --port "$SMTP_PORT" \
        --from "alice@$SEND_DOMAIN" --to "support@$RECV_DOMAIN" \
        --subject "e2e-abuse-$STAMP" --body x >/dev/null || true
    after="$(redis_cli --scan --pattern 'sentio:smtp:rate:conn:*' --count 500 | wc -l)"
    if [ "$after" -gt 0 ]; then
        pass "connection rate limiter is writing to the KV store ($after key(s))"
    else
        fail "no rate-limit key after a connection (was $before)"
    fi

    local dnsbl
    dnsbl="$(redis_cli --scan --pattern 'sentio:smtp:dnsbl:*' --count 500 | wc -l)"
    if [ "$dnsbl" -gt 0 ]; then
        pass "DNSBL results cached ($dnsbl list(s))"
    else
        skip "no DNSBL cache entries (lists may be disabled)"
    fi
}

main() {
    preflight   || { summary; exit 1; }
    "$REPO_ROOT/scripts/e2e/provision.sh"
    echo
    test_inbound  || true
    echo
    test_outbound || true
    echo
    test_attachment || true
    echo
    test_scanning || true
    echo
    test_webhook_signature || true
    echo
    test_tls_and_auth || true
    echo
    test_abuse_tracking || true
    summary
}

main "$@"
