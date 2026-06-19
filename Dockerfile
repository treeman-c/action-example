FROM alpine:3.20

ARG TARGETARCH

WORKDIR /app

RUN apk add --no-cache \
    bash curl wget git tar tzdata ca-certificates dos2unix jq dcron openssl coreutils

# cloudflared + komari
RUN if [ "$TARGETARCH" = "arm64" ]; then ARCH="arm64"; else ARCH="amd64"; fi && \
    wget -O /usr/local/bin/cloudflared \
      https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH} && \
    wget -O /usr/local/bin/komari \
      https://github.com/komari-monitor/komari/releases/latest/download/komari-linux-${ARCH} && \
    chmod +x /usr/local/bin/cloudflared /usr/local/bin/komari

COPY entrypoint.sh /entrypoint.sh
COPY backup.sh /backup.sh

RUN dos2unix /entrypoint.sh /backup.sh && \
    chmod +x /entrypoint.sh /backup.sh

EXPOSE 25774

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
