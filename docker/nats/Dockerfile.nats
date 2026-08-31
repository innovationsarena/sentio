FROM nats:2.11-alpine

# Baked in instead of bind-mounted: Coolify rewrites relative binds to a host
# path it does not populate, so Docker created an empty directory here.
COPY nats-server.conf /etc/nats/nats-server.conf
