#!/usr/bin/env bash
# One-time setup of a fresh Ubuntu 22.04 / 24.04 server. Run as root:
#   scp scripts/server-setup.sh root@SERVER_IP:/root/
#   ssh root@SERVER_IP 'bash /root/server-setup.sh "ssh-ed25519 AAAA... github-actions-deploy"'
# The argument is the PUBLIC key that GitHub Actions uses to log in as the deploy user.
set -euo pipefail

DEPLOY_KEY=${1:?Pass the deploy public key as the first argument}
APP_DIR=/opt/viweb

echo "==> System updates and base tools"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get upgrade -yq
apt-get install -yq ca-certificates curl gnupg ufw fail2ban unattended-upgrades rsync

echo "==> Docker Engine + Compose plugin from Docker's apt repository"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -q
apt-get install -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

echo "==> deploy user (runs Docker, owns $APP_DIR, no password)"
id deploy >/dev/null 2>&1 || adduser --disabled-password --gecos "" deploy
usermod -aG docker deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
grep -qxF "$DEPLOY_KEY" /home/deploy/.ssh/authorized_keys 2>/dev/null \
  || echo "$DEPLOY_KEY" >> /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
install -d -m 750 -o deploy -g deploy "$APP_DIR" "$APP_DIR/models" "$APP_DIR/backups"

echo "==> Firewall: only SSH, HTTP and HTTPS"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable

echo "==> Automatic security updates and SSH brute-force protection"
dpkg-reconfigure -f noninteractive unattended-upgrades
systemctl enable --now fail2ban

echo "==> Nightly database backup at 02:30 server time"
cat > /etc/cron.d/viweb-backup <<CRON
30 2 * * * deploy $APP_DIR/scripts/backup.sh >> $APP_DIR/backups/backup.log 2>&1
CRON

echo "==> Docker log rotation defaults"
cat > /etc/docker/daemon.json <<JSON
{ "log-driver": "json-file", "log-opts": { "max-size": "20m", "max-file": "5" } }
JSON
systemctl restart docker

cat <<NEXT

Server ready. Next steps (see README.md):
  1. As deploy: create $APP_DIR/.env from .env.example (chmod 600).
  2. As deploy: docker login ghcr.io -u <github-user>   (token with read:packages)
  3. Point your domain's A record at this server.
  4. Run the Deploy workflow in GitHub (or scripts/deploy.sh on the server).
  5. When you can log in as deploy with your own key, disable root and password SSH:
       PermitRootLogin no / PasswordAuthentication no in /etc/ssh/sshd_config
NEXT
