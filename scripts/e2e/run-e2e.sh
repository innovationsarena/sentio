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

main() {
    preflight   || { summary; exit 1; }
    "$REPO_ROOT/scripts/e2e/provision.sh"
    echo
    test_inbound  || true
    echo
    test_outbound || true
    echo
    test_attachment || true
    summary
}

main "$@"
