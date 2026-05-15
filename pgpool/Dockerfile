FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        pgpool2 \
        postgresql-client-15 \
        netcat-openbsd \
        procps \
        iproute2 \
        less \
        ca-certificates \
        gosu \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/run/pgpool /var/log/pgpool /scripts \
    && chown -R postgres:postgres /var/run/pgpool /var/log/pgpool

COPY pgpool.conf /etc/pgpool2/pgpool.conf
COPY pool_hba.conf /etc/pgpool2/pool_hba.conf
COPY failover.sh /scripts/failover.sh
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh /scripts/failover.sh \
    && chown postgres:postgres /etc/pgpool2/pgpool.conf /etc/pgpool2/pool_hba.conf /scripts/failover.sh

EXPOSE 9999 9898

ENTRYPOINT ["/entrypoint.sh"]
