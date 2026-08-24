# Testing Sentio

## Unit tests

The whole workspace tests without any infrastructure. Anything that would
otherwise need a live service uses an in-tree mock (`MockKv`, `MockBlobStore`).

```bash
cargo test --workspace
```

| Area | Command |
|---|---|
| Email auth (DKIM / SPF / DMARC / ARC) | `cargo test -p sentio-auth` |
| Abuse (rate limit / ban / greylist) | `cargo test -p sentio-abuse` |
| SMTP protocol logic | `cargo test -p sentio-smtp-server -p sentio-smtp-client` |
| Blob store and attachment helpers | `cargo test -p sentio-storage` |
| Config parsing and env overrides | `cargo test -p sentio-core` |

## End-to-end tests

`docker-compose.test.yml` overlays two sinks onto the normal stack and points
outbound delivery at one of them, so a full round trip can be asserted:

```bash
docker compose -f docker-compose.yml -f docker-compose.test.yml up -d
scripts/e2e/run-e2e.sh
```

That runs the published image. To exercise code you have changed, add the build
overlay so the image comes from your checkout:

```bash
docker compose -f docker-compose.yml -f docker-compose.test.yml \
               -f docker-compose.build.yml up -d --build
```

Two flows are exercised:

| Direction | Path |
|---|---|
| Inbound | host SMTP client → `sentio:25` → pipeline → inbound route → `webhook-sink` |
| Outbound | host HTTP client → `POST /v1/messages/send` → relay → `mailpit` |
| Attachment | host SMTP client → parsed and virus-scanned → object store → back out over the API |
| Scanning | GTUBE must score above 10; EICAR must be rejected in-band |
| Event webhook | HMAC recomputed over the raw delivered bytes |
| TLS and AUTH | STARTTLS upgrade, then AUTH - skipped without a certificate |
| Abuse tier | connection rate limiter and DNSBL cache writing to the KV store |

Several of these exist because a healthy container proves nothing about
whether a dependency is actually consulted. rspamd answered every request for
weeks while scoring every message identically, because inbound was dropping the
CRLF that ends the last body line; GTUBE is the assertion that would have
caught it. The webhook check recomputes the signature over the raw bytes rather
than a re-serialised body, since the latter would pass even if the scheme were
wrong.

To include the TLS and AUTH checks, mount a certificate. A self-signed one is
enough locally:

```bash
mkdir -p tls
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout tls/key.pem -out tls/cert.pem -subj "/CN=localhost"
```

then add `- ./tls:/etc/sentio/tls:ro` to the `sentio` service. Without it those
checks report as skipped rather than failing.

The attachment flow sends 20 kB of random bytes and compares the SHA-256 of
what comes back out of `/v1/messages/{id}/attachments/{id}`, so an encoding
slip or a truncated upload fails rather than passing quietly. It also asserts
the attachment's `scan_status`, which comes from ClamAV, and that the raw
message was archived.

The assertions check that mail was *processed*, not merely accepted: the
inbound message must appear via `GET /v1/messages` and produce a successful
webhook dispatch, and the delivered outbound message must carry a
`DKIM-Signature` header - which fails if the signing path is skipped.

Captured mail is browsable at <http://localhost:8025>.

### No mail can reach the internet

Two independent mechanisms, either sufficient on its own:

1. `[delivery.relay]` is enabled in the overlay. That makes the delivery engine
   skip MX resolution entirely and hand every message to the relay host, so no
   code path dials a public MX. `run-e2e.sh` refuses to run if the relay is not
   enabled.
2. All fixtures use `.test` domains. RFC 6761 reserves `.test` as never
   globally resolvable, so even a misconfigured relay fails to resolve rather
   than reaching a real server.

### Scripts

| Script | Purpose |
|---|---|
| `scripts/e2e/run-e2e.sh` | Preflight, provision, then both flows with assertions |
| `scripts/e2e/provision.sh` | Idempotent fixtures: domains, DKIM key, inbound route |
| `scripts/e2e/smtp-send.py` | Standalone SMTP client - useful on its own |
| `scripts/e2e/lib.sh` | Shared config and helpers |

`smtp-send.py` has no dependencies and is handy for poking at any running
server:

```bash
scripts/e2e/smtp-send.py --port 2525 \
    --from alice@sender.test --to support@inbound.test \
    --subject 'hello' --body 'test body' --verbose
```

It prints the server's reply on rejection and exits non-zero, so failures are
diagnosable rather than silent. `--starttls` and `--auth-user`/`--auth-pass`
cover the submission port.

Provisioning marks its `.test` domains verified with a direct `UPDATE` against
the compose database. Real verification requires live DNS that `.test` cannot
satisfy, and this keeps the fixture from weakening the API's verification gate.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `DATABASE_URL` | *(unset)* | Required by the sqlx compile-time query macros when regenerating the cache |
| `SQLX_OFFLINE` | *(unset)* | `true` uses the committed `.sqlx/` cache instead of a live database |
| `RUST_LOG` | *(unset)* | Tracing filter, e.g. `info` or `sentio=debug` |

The e2e scripts additionally honour `SENTIO_API`, `SENTIO_API_KEY`,
`SENTIO_TENANT`, `MAILPIT_URL`, `SEND_DOMAIN`, and `RECV_DOMAIN`.

## Regenerating the sqlx offline cache

Normal builds need no database - they read the committed `.sqlx/`. After
changing any `sqlx::query*!` macro, regenerate it against a live database and
commit the result:

```bash
echo 'DATABASE_URL=postgres://sentio:sentio@localhost:5432/sentio' > .env
cargo sqlx prepare --workspace
```
