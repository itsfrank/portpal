FROM alpine:3.22

RUN apk add --no-cache openssh bash python3 && \
    adduser -D -s /bin/bash tester && \
    echo 'tester:portpal-local-only' | chpasswd && \
    mkdir -p /home/tester/.ssh /var/run/sshd /srv/http && \
    chown -R tester:tester /home/tester /srv/http && \
    chmod 700 /home/tester/.ssh && \
    ssh-keygen -A

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 2222

CMD ["/entrypoint.sh"]
