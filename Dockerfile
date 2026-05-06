FROM nim:2.2-alpine AS builder
WORKDIR /build
COPY baradadb.nimble .
COPY src/ src/
RUN nimble install -d -y || true
RUN nim c -d:release --opt:speed -o:baradadb src/baradadb.nim

FROM alpine:latest
WORKDIR /app
COPY --from=builder /build/baradadb .
RUN mkdir -p /data
ENV BARADB_PORT=9000
ENV BARADB_DATA_DIR=/data
ENV BARADB_HTTP_PORT=8080
ENV BARADB_WS_PORT=8081
EXPOSE 9000 8080 8081
VOLUME ["/data"]
CMD ["./baradadb"]
