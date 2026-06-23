data "xenorchestra_template" "ubuntu" {
  name_label = var.template_name
}

data "xenorchestra_network" "net" {
  name_label = var.network_name
}

data "xenorchestra_sr" "sr" {
  name_label = var.storage_repository
}

locals {
  provision_b64   = base64encode(file("${path.module}/scripts/provision.sh"))
  wiab_deploy_b64 = base64encode(file("${path.module}/scripts/wiab-deploy.sh"))
  dns_csv         = join(", ", var.dns_servers)
  mem_bytes       = var.memory_gb * 1024 * 1024 * 1024

  # Federation turns on only when its credentials are fully provided.
  google_enabled = var.google_client_id != "" && var.google_client_secret != ""
  oidc_enabled   = var.oidc_issuer != "" && var.oidc_client_id != "" && var.oidc_client_secret != ""

  # Per-role model env lines (role LLAMA -> WIAB_LLAMA_ENABLED / WIAB_LLAMA_MODEL_FILE),
  # written verbatim into provision.env on first boot and refreshed on each in-place deploy.
  model_env_lines = flatten([
    for role, m in var.models : [
      "WIAB_${role}_ENABLED=${m.enabled}",
      "WIAB_${role}_MODEL_FILE=${m.file}",
    ]
  ])

  cloud_config = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    hostname           = var.hostname
    fqdn               = var.domain
    ssh_authorized_key = var.ssh_authorized_key
    provision_b64      = local.provision_b64
    wiab_deploy_b64    = local.wiab_deploy_b64
    domain             = var.domain
    letsencrypt_email  = var.letsencrypt_email
    announced_address  = var.announced_address
    backend_repo       = var.backend_repo
    frontend_repo      = var.frontend_repo
    backend_version    = var.backend_version
    frontend_version   = var.frontend_version
    fc_kernel_url      = var.fc_test_kernel_url
    fc_rootfs_url      = var.fc_test_rootfs_url
    db_password        = var.db_password
    wiab_data_dir      = var.wiab_data_dir
    wiab_models_url    = var.wiab_models_url
    model_env_lines    = local.model_env_lines
  })

  network_config = templatefile("${path.module}/templates/network-config.yaml.tftpl", {
    host_ip     = var.host_ip
    cidr_prefix = var.cidr_prefix
    gateway     = var.gateway
    dns_csv     = local.dns_csv
  })
}

resource "xenorchestra_vm" "host" {
  name_label       = var.hostname
  name_description = "WorkInABox host (managed by Terraform)"
  template         = data.xenorchestra_template.ubuntu.id

  cpus = var.vcpus
  # Static memory pin (min == max): nested virt rejects ballooning (MAXPIN).
  memory_max = local.mem_bytes
  memory_min = local.mem_bytes

  # Nested virt on XCP-ng 8.3 is platform:nested-virt, which this provider does
  # NOT expose (exp_nested_hvm sets the legacy, ignored key). It is enabled
  # out-of-band by null_resource.enable_nested_virt below — which must run
  # BEFORE first boot so cloud-init's KVM gate passes. So create the VM Halted;
  # that resource flips nestedVirt and starts it. ignore_changes on power_state
  # keeps later applies from fighting the externally-started VM.
  power_state  = "Halted"
  auto_poweron = true

  cloud_config         = local.cloud_config
  cloud_network_config = local.network_config

  network {
    network_id = data.xenorchestra_network.net.id
  }

  disk {
    sr_id      = data.xenorchestra_sr.sr.id
    name_label = "${var.hostname}-root"
    size       = var.disk_gb * 1024 * 1024 * 1024
  }

  lifecycle {
    # power_state: the VM is started out-of-band by enable_nested_virt.
    # cloud_config/cloud_network_config: cloud-init only runs at first boot, so editing
    # provision.sh / the templates must not force-replace the live VM. Existing VMs are
    # updated over SSH (provision_db, deploy_app); fresh VMs get the new cloud-init.
    ignore_changes = [power_state, cloud_config, cloud_network_config]
  }
}

# Enables real nested virtualization (XCP-ng 8.3 platform:nested-virt) and starts
# the VM. Requires xo-cli installed and registered on the machine running
# Terraform (same XO the provider targets). Re-pins memory defensively.
resource "null_resource" "enable_nested_virt" {
  triggers = {
    vm_id = xenorchestra_vm.host.id
    mem   = local.mem_bytes
  }

  provisioner "local-exec" {
    command = "xo-cli vm.set id=${self.triggers.vm_id} memoryMin=${self.triggers.mem} memoryMax=${self.triggers.mem} memoryStaticMax=${self.triggers.mem} nestedVirt=true && xo-cli vm.start id=${self.triggers.vm_id}"
  }
}

# Installs and configures a local PostgreSQL on the existing VM over SSH, and points the
# backend at it (WIAB_PERSISTENCE=postgres + DATABASE_URL in /etc/wiab/wiab.env). Idempotent
# and re-runnable without recreating the VM: bump db_provision_version to re-run. Runs
# before deploy_app so a newly deployed binary boots with the database already present.
resource "null_resource" "provision_db" {
  depends_on = [null_resource.enable_nested_virt]

  triggers = {
    db_provision_version = var.db_provision_version
    db_password          = var.db_password
  }

  connection {
    host        = var.host_ip
    user        = "ubuntu"
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      # terraform remote-exec runs this under /bin/sh (dash), which has no `pipefail`
      # (`set -o pipefail` aborts dash with exit 2). `set -eu` is enough and portable.
      "set -eu",
      "cloud-init status --wait || true",
      # Wait up to 5 min for the apt/dpkg lock (unattended-upgrades runs at boot and
      # periodically; without this, apt aborts with exit 2 when the lock is held).
      "sudo apt-get -o DPkg::Lock::Timeout=300 update -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y postgresql",
      "sudo systemctl enable --now postgresql",
      # Role + database (idempotent). `|| true` swallows the harmless 'already exists'
      # error on re-runs; avoiding a pipe sidesteps the set -o pipefail / SIGPIPE trap.
      # ALTER ROLE always (re)sets the password so it matches config (errors surface).
      "sudo -u postgres psql -c \"CREATE ROLE wiab LOGIN\" || true",
      "sudo -u postgres psql -c \"ALTER ROLE wiab LOGIN PASSWORD '${var.db_password}'\"",
      "sudo -u postgres createdb -O wiab wiab || true",
      # Point the backend at Postgres (merge into wiab.env without clobbering other vars).
      "sudo sed -i '/^WIAB_PERSISTENCE=/d;/^DATABASE_URL=/d' /etc/wiab/wiab.env",
      "echo 'WIAB_PERSISTENCE=postgres' | sudo tee -a /etc/wiab/wiab.env >/dev/null",
      "echo 'DATABASE_URL=postgres://wiab:${var.db_password}@localhost:5432/wiab' | sudo tee -a /etc/wiab/wiab.env >/dev/null",
      "sudo systemctl restart wiab || true",
    ]
  }
}

# Pushes the latest wiab-deploy script and points the nginx /api proxy at the HTTPS
# backend on the EXISTING VM (cloud-init only writes these at first boot). Idempotent;
# re-runs when wiab-deploy.sh changes. Runs before deploy_app so the new health check
# (https) and proxy are in place before the binary is (re)deployed.
resource "null_resource" "reconfigure_proxy" {
  depends_on = [null_resource.enable_nested_virt]

  triggers = {
    wiab_deploy_sha = filesha256("${path.module}/scripts/wiab-deploy.sh")
    proxy_scheme    = "https"
  }

  connection {
    host        = var.host_ip
    user        = "ubuntu"
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/wiab-deploy.sh"
    destination = "/tmp/wiab-deploy"
  }

  provisioner "remote-exec" {
    inline = [
      "set -eu",
      "cloud-init status --wait || true",
      "sudo install -m 0755 /tmp/wiab-deploy /usr/local/bin/wiab-deploy",
      # Point the nginx /api proxy at the HTTPS backend, with verification off for the
      # self-signed localhost hop. Both seds are idempotent (no-op once already https).
      "sudo sed -i 's#proxy_pass http://127.0.0.1:8080/;#proxy_pass https://127.0.0.1:8080/;#g' /etc/nginx/sites-available/wiab",
      "grep -q 'proxy_ssl_verify off' /etc/nginx/sites-available/wiab || sudo sed -i 's#proxy_pass https://127.0.0.1:8080/;#proxy_pass https://127.0.0.1:8080/;\\n        proxy_ssl_verify off;#g' /etc/nginx/sites-available/wiab",
      "sudo nginx -t",
      "sudo systemctl reload nginx",
    ]
  }
}

# Writes the identity/email/git runtime config into /etc/wiab/wiab.env (the systemd
# EnvironmentFile — read literally, NOT shell-sourced) over SSH and restarts wiab.
# In-place updatable: edit any of these variables and apply (no VM rebuild). Google/OIDC
# enable automatically when their credentials are set. Also provisions a durable git root
# (off /tmp) and a persistent git SSH host key so repos and the SSH identity survive reboots.
resource "null_resource" "configure_app" {
  depends_on = [null_resource.provision_db]

  triggers = {
    base_url             = "https://${var.domain}"
    auth_local_signup    = var.auth_local_signup
    email_from           = var.email_from
    resend_api_key       = var.resend_api_key
    google_enabled       = local.google_enabled
    google_client_id     = var.google_client_id
    google_client_secret = var.google_client_secret
    oidc_enabled         = local.oidc_enabled
    oidc_issuer          = var.oidc_issuer
    oidc_client_id       = var.oidc_client_id
    oidc_client_secret   = var.oidc_client_secret
    git_root             = var.git_root
  }

  connection {
    host        = var.host_ip
    user        = "ubuntu"
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "set -eu",
      "cloud-init status --wait || true",
      # Durable git root (off /tmp) owned by the wiab service user; the backend create_dir_all's
      # the leaf itself, this just guarantees the parent exists and is wiab-writable.
      "sudo install -d -o wiab -g wiab /var/lib/wiab /var/lib/wiab/git",
      # Persistent git SSH host key so clients don't see a changing key after each reboot.
      "sudo test -f /etc/wiab/git_ssh_host_key || sudo ssh-keygen -t ed25519 -N '' -C wiab-git -f /etc/wiab/git_ssh_host_key",
      "sudo chown wiab:wiab /etc/wiab/git_ssh_host_key /etc/wiab/git_ssh_host_key.pub",
      "sudo chmod 600 /etc/wiab/git_ssh_host_key",
      # Idempotent: drop the managed keys, then append current values. wiab.env is a systemd
      # EnvironmentFile (read to end-of-line, no shell interpretation), so values are literal.
      "sudo sed -i '/^WIAB_BASE_URL=/d;/^WIAB_AUTH_LOCAL_SIGNUP=/d;/^WIAB_EMAIL_PROVIDER=/d;/^WIAB_EMAIL_FROM=/d;/^RESEND_API_KEY=/d;/^WIAB_AUTH_GOOGLE_ENABLED=/d;/^WIAB_GOOGLE_CLIENT_ID=/d;/^WIAB_GOOGLE_CLIENT_SECRET=/d;/^WIAB_AUTH_OIDC_ENABLED=/d;/^WIAB_OIDC_ISSUER=/d;/^WIAB_OIDC_CLIENT_ID=/d;/^WIAB_OIDC_CLIENT_SECRET=/d;/^WIAB_GIT_ROOT=/d;/^WIAB_GIT_SSH_HOST_KEY=/d' /etc/wiab/wiab.env",
      "echo 'WIAB_BASE_URL=https://${var.domain}' | sudo tee -a /etc/wiab/wiab.env >/dev/null",
      "echo 'WIAB_AUTH_LOCAL_SIGNUP=${var.auth_local_signup}' | sudo tee -a /etc/wiab/wiab.env >/dev/null",
      "echo 'WIAB_EMAIL_PROVIDER=resend' | sudo tee -a /etc/wiab/wiab.env >/dev/null",
      "echo 'WIAB_EMAIL_FROM=${var.email_from}' | sudo tee -a /etc/wiab/wiab.env >/dev/null",
      "echo 'RESEND_API_KEY=${var.resend_api_key}' | sudo tee -a /etc/wiab/wiab.env >/dev/null",
      "echo 'WIAB_AUTH_GOOGLE_ENABLED=${local.google_enabled}' | sudo tee -a /etc/wiab/wiab.env >/dev/null",
      "echo 'WIAB_GOOGLE_CLIENT_ID=${var.google_client_id}' | sudo tee -a /etc/wiab/wiab.env >/dev/null",
      "echo 'WIAB_GOOGLE_CLIENT_SECRET=${var.google_client_secret}' | sudo tee -a /etc/wiab/wiab.env >/dev/null",
      "echo 'WIAB_AUTH_OIDC_ENABLED=${local.oidc_enabled}' | sudo tee -a /etc/wiab/wiab.env >/dev/null",
      "echo 'WIAB_OIDC_ISSUER=${var.oidc_issuer}' | sudo tee -a /etc/wiab/wiab.env >/dev/null",
      "echo 'WIAB_OIDC_CLIENT_ID=${var.oidc_client_id}' | sudo tee -a /etc/wiab/wiab.env >/dev/null",
      "echo 'WIAB_OIDC_CLIENT_SECRET=${var.oidc_client_secret}' | sudo tee -a /etc/wiab/wiab.env >/dev/null",
      "echo 'WIAB_GIT_ROOT=${var.git_root}' | sudo tee -a /etc/wiab/wiab.env >/dev/null",
      "echo 'WIAB_GIT_SSH_HOST_KEY=/etc/wiab/git_ssh_host_key' | sudo tee -a /etc/wiab/wiab.env >/dev/null",
      "sudo systemctl restart wiab || true",
      # Health-gate the restart so a bad identity/email config fails the apply loudly.
      "for i in $(seq 1 15); do curl -fsSk -o /dev/null https://127.0.0.1:8080/health && exit 0; sleep 1; done; echo 'wiab unhealthy after configure_app' >&2; exit 1",
    ]
  }
}

# Deploys the pinned backend/frontend versions AND reconciles the model set over SSH.
# Re-runs whenever a version variable, the `models` map, or the models URL/data dir changes
# (bump/edit and apply) WITHOUT recreating the VM. On first apply it waits for cloud-init to
# finish, then no-ops because wiab-deploy is idempotent (versions + model fingerprint already
# current). The model env is refreshed in provision.env here so wiab-deploy fetches the new set.
resource "null_resource" "deploy_app" {
  depends_on = [
    null_resource.enable_nested_virt,
    null_resource.provision_db,
    null_resource.reconfigure_proxy,
    null_resource.configure_app,
  ]

  triggers = {
    backend_version  = var.backend_version
    frontend_version = var.frontend_version
    models           = jsonencode(var.models)
    models_url       = var.wiab_models_url
    data_dir         = var.wiab_data_dir
  }

  connection {
    host        = var.host_ip
    user        = "ubuntu"
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = concat(
      [
        "set -eu",
        "cloud-init status --wait || true",
        # Refresh model config in provision.env (idempotent: drop old model lines, append
        # current). The role-flag regex only matches single-token model roles (WIAB_LLAMA_*,
        # WIAB_WHISPER_*), not the multi-token auth flags which live in wiab.env/oidc.env.
        "sudo sed -i '/^WIAB_DATA_DIR=/d;/^WIAB_MODELS_URL=/d;/^WIAB_[A-Z0-9]*_ENABLED=/d;/^WIAB_[A-Z0-9]*_MODEL_FILE=/d' /etc/wiab/provision.env",
        "echo 'WIAB_DATA_DIR=${var.wiab_data_dir}' | sudo tee -a /etc/wiab/provision.env >/dev/null",
        "echo \"WIAB_MODELS_URL='${var.wiab_models_url}'\" | sudo tee -a /etc/wiab/provision.env >/dev/null",
      ],
      [for line in local.model_env_lines : "echo '${line}' | sudo tee -a /etc/wiab/provision.env >/dev/null"],
      [
        "sudo wiab-deploy --backend ${var.backend_version} --frontend ${var.frontend_version}",
      ],
    )
  }
}
