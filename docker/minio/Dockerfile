FROM quay.io/minio/mc:latest

# Destination matches the original bind mount, so compose keeps
# entrypoint: ["/bin/sh", "/init.sh"] unchanged.
COPY --chmod=0755 init.sh /init.sh
