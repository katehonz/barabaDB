# ┌─────────────────────────────────────────────────────────┐
# │ BaraDB — Multimodal Database Engine                     │
# │ Dockerfile (pre-built binary, production-ready)         │
# └─────────────────────────────────────────────────────────┘
#
# Този Dockerfile използва вече компилиран binary от build/.
# За build от source вижте Dockerfile.source
#
# Build:
#   docker build -t baradb:latest .
#
# Run:
#   docker run -d -p 9472:9472 -p 9470:9470 -p 9471:9471 -v baradb_data:/data baradb:latest

FROM debian:bookworm-slim

LABEL maintainer="BaraDB Team"
LABEL description="BaraDB — Multimodal Database Engine"
LABEL version="0.1.0"

# Инсталираме runtime зависимости
# libpcre3 — нужна за Nim regex (зарежда се динамично)
# ca-certificates — за TLS връзки
# wget — за healthcheck
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libpcre3 \
        ca-certificates \
        wget \
        gosu && \
    rm -rf /var/lib/apt/lists/*

# Създаваме dedicated потребител за сигурност
RUN groupadd -r -g 1000 baradb && \
    useradd -r -u 1000 -g baradb baradb

WORKDIR /app

# Копираме компилираните бинарни файлове
COPY build/baradadb /app/baradadb
COPY build/backup /app/backup

# Копираме entrypoint скрипта
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Създаваме data директория и symlink за съвместимост с default dataDir=./data
RUN mkdir -p /data && chown baradb:baradb /data && \
    ln -s /data /app/data && chown -h baradb:baradb /app/data

# Environment variables (defaults)
ENV BARADB_ADDRESS=0.0.0.0
ENV BARADB_PORT=9472
# Note: HTTP port = TCP port + 440 (9912 when TCP=9472)
# Note: WS port   = TCP port + 441 (9913 when TCP=9472)
ENV BARADB_DATA_DIR=/data
ENV BARADB_LOG_LEVEL=info

# Expose ports
# 9472 — Binary wire protocol
# 9912 — HTTP/REST API (9472 + 440)
# 9913 — WebSocket      (9472 + 441)
EXPOSE 9472 9912 9913

# Volume за persistent data
VOLUME ["/data"]

# Healthcheck
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:9912/health >/dev/null 2>&1 || exit 1

# Стартираме чрез entrypoint (който пуска като baradb потребител)
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["./baradadb"]
