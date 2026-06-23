#!/usr/bin/env bash
# WorkInABox host provisioning. Runs once on first boot via cloud-init.
# Config is read from /etc/wiab/provision.env (written by cloud-init).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

set -a
. /etc/wiab/provision.env
set +a

log() { echo "[wiab-provision] $*"; }

# ---------------------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------------------
log "installing packages"
# Wait for the apt/dpkg lock rather than aborting (unattended-upgrades runs at boot).
apt-get -o DPkg::Lock::Timeout=300 update -y
apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends \
  ca-certificates curl jq tar coreutils ufw \
  nginx certbot python3-certbot-nginx \
  qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils cpu-checker \
  libssl3 libopus0 \
  postgresql
update-ca-certificates || true

# ---------------------------------------------------------------------------
# 2. KVM + Firecracker  (nested-virt gate)
# ---------------------------------------------------------------------------
if [ ! -e /dev/kvm ]; then
  log "FATAL: /dev/kvm absent — nested virtualization is not active on this VM"
  exit 1
fi
log "/dev/kvm present"
kvm-ok || true

ARCH="$(uname -m)"
FC_TAG="$(curl -fsSL https://api.github.com/repos/firecracker-microvm/firecracker/releases/latest | jq -r .tag_name)"
log "installing firecracker ${FC_TAG} (${ARCH})"
curl -fsSL -o /tmp/firecracker.tgz \
  "https://github.com/firecracker-microvm/firecracker/releases/download/${FC_TAG}/firecracker-${FC_TAG}-${ARCH}.tgz"
tar -xzf /tmp/firecracker.tgz -C /tmp
install -m 0755 "/tmp/release-${FC_TAG}-${ARCH}/firecracker-${FC_TAG}-${ARCH}" /usr/local/bin/firecracker
if [ -f "/tmp/release-${FC_TAG}-${ARCH}/jailer-${FC_TAG}-${ARCH}" ]; then
  install -m 0755 "/tmp/release-${FC_TAG}-${ARCH}/jailer-${FC_TAG}-${ARCH}" /usr/local/bin/jailer
fi
firecracker --version

log "firecracker microVM boot smoke test"
mkdir -p /opt/wiab/fc-test
curl -fsSL -o /opt/wiab/fc-test/vmlinux "${WIAB_FC_KERNEL_URL}"
curl -fsSL -o /opt/wiab/fc-test/rootfs.ext4 "${WIAB_FC_ROOTFS_URL}"
cat > /opt/wiab/fc-test/config.json <<'JSON'
{
  "boot-source": {
    "kernel_image_path": "/opt/wiab/fc-test/vmlinux",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "/opt/wiab/fc-test/rootfs.ext4",
      "is_root_device": true,
      "is_read_only": true
    }
  ],
  "machine-config": { "vcpu_count": 1, "mem_size_mib": 128 }
}
JSON
# A booted guest kernel prints its "Linux version ..." banner over ttyS0;
# seeing it proves KVM actually executed guest code (true nested virt).
timeout 30 firecracker --no-api --config-file /opt/wiab/fc-test/config.json \
  > /opt/wiab/fc-test/console.log 2>&1 || true
if grep -qi "Linux version" /opt/wiab/fc-test/console.log; then
  log "firecracker smoke test PASSED (guest kernel booted under KVM)"
else
  log "FATAL: firecracker guest kernel did not boot — see /opt/wiab/fc-test/console.log"
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. wiab system user
# ---------------------------------------------------------------------------
id wiab >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin wiab

# ---------------------------------------------------------------------------
# 4. Local PostgreSQL (persistence backend)
# ---------------------------------------------------------------------------
log "configuring local postgresql"
systemctl enable --now postgresql
# Role + database (idempotent); always (re)set the password so it matches config.
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='wiab'" | grep -q 1 \
  || sudo -u postgres psql -c "CREATE ROLE wiab LOGIN"
sudo -u postgres psql -c "ALTER ROLE wiab LOGIN PASSWORD '${WIAB_DB_PASSWORD}'"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='wiab'" | grep -q 1 \
  || sudo -u postgres createdb -O wiab wiab

# ---------------------------------------------------------------------------
# 5. Backend env + systemd service (binary installed by wiab-deploy below)
# ---------------------------------------------------------------------------
mkdir -p /etc/wiab
# Model env vars (WIAB_DATA_DIR + per-role WIAB_<ROLE>_ENABLED/_MODEL_FILE) are synced into
# wiab.env by wiab-deploy, which also fetches the model files. Keep them out of here.
cat > /etc/wiab/wiab.env <<EOF
WIAB_MEDIASOUP_LISTEN_IP=0.0.0.0
WIAB_MEDIASOUP_ANNOUNCED_ADDRESS=${WIAB_ANNOUNCED_ADDRESS}
WIAB_PERSISTENCE=postgres
DATABASE_URL=postgres://wiab:${WIAB_DB_PASSWORD}@localhost:5432/wiab
EOF

cat > /etc/systemd/system/wiab.service <<'EOF'
[Unit]
Description=WorkInABox backend (wiab)
After=network-online.target
Wants=network-online.target

[Service]
User=wiab
EnvironmentFile=/etc/wiab/wiab.env
ExecStart=/usr/local/bin/wiab
Restart=on-failure
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wiab   # started by wiab-deploy once the binary is installed

# ---------------------------------------------------------------------------
# 5. Frontend release dir (content installed by wiab-deploy below)
# ---------------------------------------------------------------------------
mkdir -p /var/www/wiab-releases

# ---------------------------------------------------------------------------
# 6. nginx — serve SPA, proxy /api to backend (prefix-stripped), WS upgrade
# ---------------------------------------------------------------------------
cat > /etc/nginx/conf.d/wiab-upgrade.conf <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF

cat > /etc/nginx/sites-available/wiab <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;

    root /var/www/wiab;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    # Trailing slash on proxy_pass strips the /api prefix:
    #   /api/works  -> https://127.0.0.1:8080/works
    #   /api/signal -> https://127.0.0.1:8080/signal  (WebSocket)
    # The backend serves HTTPS (self-signed); skip upstream verification on the localhost hop.
    location /api/ {
        proxy_pass https://127.0.0.1:8080/;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF
sed -i "s/__DOMAIN__/${WIAB_DOMAIN}/g" /etc/nginx/sites-available/wiab
ln -sf /etc/nginx/sites-available/wiab /etc/nginx/sites-enabled/wiab
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

# ---------------------------------------------------------------------------
# 7. Deploy backend + frontend at the pinned versions and fetch the model set
#    (installs binary/libs, syncs model env into wiab.env, azcopy-fetches enabled
#    models, starts wiab, populates /var/www/wiab). Same script used for later updates.
# ---------------------------------------------------------------------------
wiab-deploy --backend "${WIAB_BACKEND_VERSION}" --frontend "${WIAB_FRONTEND_VERSION}"

# ---------------------------------------------------------------------------
# 8. TLS via Let's Encrypt (non-fatal: needs public DNS + port 80 reachable)
# ---------------------------------------------------------------------------
log "requesting Let's Encrypt certificate for ${WIAB_DOMAIN}"
if certbot --nginx -d "${WIAB_DOMAIN}" -m "${WIAB_LETSENCRYPT_EMAIL}" --agree-tos --redirect -n; then
  log "TLS configured"
else
  log "WARNING: certbot failed (DNS/NAT not ready yet?). Site is HTTP-only."
  log "WARNING: once DNS A record + port-80 NAT are in place, re-run:"
  log "WARNING:   certbot --nginx -d ${WIAB_DOMAIN} -m ${WIAB_LETSENCRYPT_EMAIL} --agree-tos --redirect -n"
fi

# ---------------------------------------------------------------------------
# 9. Firewall
# ---------------------------------------------------------------------------
ufw allow OpenSSH
ufw allow 'Nginx Full'
# WebRTC media. The backend uses mediasoup with an unbounded UDP port range
# (sfu.rs: port_range = None), so a tight rule isn't possible without a backend
# change. Open a pragmatic range; revisit if the backend pins a range later.
ufw allow 10000:59999/udp comment 'WebRTC media (mediasoup)'
ufw --force enable

log "provisioning complete"
