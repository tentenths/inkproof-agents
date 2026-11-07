# The gatekeeper: holds the GitHub App's key and acts as the App for the
# coordinator. It never runs agent code, and no agent container mounts its key.
FROM python:3.12-slim-bookworm

ARG USER_UID=1000
ARG USER_GID=1000

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates openssl \
 && rm -rf /var/lib/apt/lists/*

# The UID matches the host user that owns secrets/, so the key is readable.
RUN groupadd -o -g "${USER_GID}" gatekeeper \
 && useradd -o -m -u "${USER_UID}" -g "${USER_GID}" gatekeeper \
 && mkdir /state && chown gatekeeper:gatekeeper /state

COPY gatekeeper.py /usr/local/bin/gatekeeper
RUN chmod 0755 /usr/local/bin/gatekeeper

USER gatekeeper
CMD ["/usr/local/bin/gatekeeper"]
