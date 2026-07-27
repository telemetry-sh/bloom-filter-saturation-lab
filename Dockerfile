FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends guile-3.0 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 lab \
    && useradd --system --uid 10001 --gid lab --home-dir /app lab

WORKDIR /app
COPY lab /app/lab
COPY public /app/public
COPY bloom-filter-saturation-lab /app/bloom-filter-saturation-lab

ENV GUILE_AUTO_COMPILE=0
ENV HOST=0.0.0.0
ENV PORT=8080

EXPOSE 8080
USER 10001:10001
ENTRYPOINT ["/app/bloom-filter-saturation-lab"]
