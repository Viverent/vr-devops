FROM google/cloud-sdk:slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      wget gnupg ca-certificates lsb-release \
    && wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgres.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/postgres.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client-15 \
    && rm -rf /var/lib/apt/lists/*

COPY refresh.sh /usr/local/bin/refresh.sh
RUN chmod +x /usr/local/bin/refresh.sh

ENTRYPOINT ["/usr/local/bin/refresh.sh"]
