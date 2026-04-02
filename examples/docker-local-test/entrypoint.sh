#!/bin/sh
set -eu

if [ ! -f /tmp/tester_key.pub ]; then
	echo "Mount your public key at /tmp/tester_key.pub" >&2
	exit 1
fi

cp /tmp/tester_key.pub /home/tester/.ssh/authorized_keys
chown tester:tester /home/tester/.ssh/authorized_keys
chmod 600 /home/tester/.ssh/authorized_keys

cat >/etc/ssh/sshd_config <<'EOF'
Port 2222
ListenAddress 0.0.0.0
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
X11Forwarding no
AllowTcpForwarding yes
GatewayPorts no
AuthorizedKeysFile .ssh/authorized_keys
PidFile /var/run/sshd.pid
PrintMotd no
Subsystem sftp /usr/lib/ssh/sftp-server
EOF

cat >/srv/http/index.html <<'EOF'
portpal docker local test
EOF

python3 -m http.server 8080 --bind 127.0.0.1 --directory /srv/http &

exec /usr/sbin/sshd -D -e
