FROM postgres:16

RUN apt-get update \
    && apt-get install -y --no-install-recommends procps iproute2 less vim-tiny \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/role-entrypoint.sh
COPY init/01-schema.sql /init/01-schema.sql
RUN chmod +x /usr/local/bin/role-entrypoint.sh

ENV PGDATA=/var/lib/postgresql/data

ENTRYPOINT ["/usr/local/bin/role-entrypoint.sh"]
CMD ["postgres"]
