FROM alpine:3.19

RUN apk add --no-cache \
        mariadb-client \
        python3 \
        py3-pip \
        dcron \
        bash \
    && python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir awscli

ENV PATH="/opt/venv/bin:$PATH"

COPY backup.sh /usr/local/bin/backup.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/backup.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
