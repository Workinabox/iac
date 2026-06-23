#!/usr/bin/env bash
# Deploys the wiab backend and/or frontend from GitHub releases, in place.
# Idempotent (skips if the resolved tag is already deployed). The backend update
# health-checks after restart and auto-rolls-back to the previous build on failure.
#
# Usage: wiab-deploy --backend <version|latest|skip> --frontend <version|latest|skip> [--force]
#
# Repo names come from /etc/wiab/provision.env (WIAB_BACKEND_REPO/WIAB_FRONTEND_REPO).
# Must run as root.
set -euo pipefail

set -a
. /etc/wiab/provision.env
set +a

BACKEND_SPEC="skip"
FRONTEND_SPEC="skip"
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --backend) BACKEND_SPEC="$2"; shift 2 ;;
    --frontend) FRONTEND_SPEC="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    *) echo "wiab-deploy: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

log() { echo "[wiab-deploy] $*"; }

VERSIONS_FILE=/etc/wiab/versions
RELEASES_DIR=/var/www/wiab-releases

# Set by deploy_backend (restarted to a new build) and deploy_models (model set changed),
# so the final step can restart once when models changed but the backend did not.
BACKEND_RESTARTED=0
MODELS_CHANGED=0

TMPDIRS=()
cleanup() { [ ${#TMPDIRS[@]} -gt 0 ] && rm -rf "${TMPDIRS[@]}" || true; }
trap cleanup EXIT
mktmp() { local d; d="$(mktemp -d)"; TMPDIRS+=("$d"); echo "$d"; }

get_recorded() { # $1 = key
  # -f2- (not -f2) so values containing '=' survive (the model fingerprint is role=file pairs).
  [ -f "$VERSIONS_FILE" ] && grep -E "^$1=" "$VERSIONS_FILE" | tail -1 | cut -d= -f2- || true
}
set_recorded() { # $1 = key, $2 = value
  mkdir -p /etc/wiab; touch "$VERSIONS_FILE"
  if grep -qE "^$1=" "$VERSIONS_FILE"; then
    sed -i "s#^$1=.*#$1=$2#" "$VERSIONS_FILE"
  else
    echo "$1=$2" >> "$VERSIONS_FILE"
  fi
}

release_json() { # $1 = repo, $2 = spec (latest|vX.Y.Z)
  local url
  if [ "$2" = "latest" ]; then
    url="https://api.github.com/repos/$1/releases/latest"
  else
    url="https://api.github.com/repos/$1/releases/tags/$2"
  fi
  curl -fsSL "$url"
}

backend_healthy() {
  local i
  for i in $(seq 1 15); do
    curl -fsSk -o /dev/null https://127.0.0.1:8080/health 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

is_enabled() { # $1 = flag value
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_azcopy() {
  command -v azcopy >/dev/null 2>&1 && return 0
  local arch url tmp
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) url="https://aka.ms/downloadazcopy-v10-linux" ;;
    aarch64|arm64) url="https://aka.ms/downloadazcopy-v10-linux-arm64" ;;
    *) log "FATAL: unsupported arch $arch for azcopy"; exit 1 ;;
  esac
  log "installing azcopy"
  tmp="$(mktmp)"
  curl -fsSL -o "$tmp/azcopy.tgz" "$url"
  tar -xzf "$tmp/azcopy.tgz" -C "$tmp"
  install -m 0755 "$tmp"/azcopy_linux_*/azcopy /usr/local/bin/azcopy
  azcopy --version >/dev/null
}

# Build the blob URL for one file by inserting the filename ahead of the SAS query string.
# WIAB_MODELS_URL = https://<acct>.blob.core.windows.net/<container>?<SAS>
models_blob_url() { # $1 = filename
  local file="$1" base sas
  base="${WIAB_MODELS_URL%%\?*}"
  if [ "$base" = "${WIAB_MODELS_URL}" ]; then
    printf '%s/%s' "${base%/}" "$file"          # no SAS query string present
  else
    sas="${WIAB_MODELS_URL#*\?}"
    printf '%s/%s?%s' "${base%/}" "$file" "$sas"
  fi
}

upsert_wiab_env() { # $1=key $2=value — idempotent line in /etc/wiab/wiab.env
  mkdir -p /etc/wiab; touch /etc/wiab/wiab.env
  sed -i "/^$1=/d" /etc/wiab/wiab.env
  echo "$1=$2" >> /etc/wiab/wiab.env
}

# Reconcile the local model set: sync the app-facing model env into wiab.env (so the backend
# resolves the right files), then azcopy-fetch every enabled model into ${WIAB_DATA_DIR}/models.
# Roles are discovered generically from the WIAB_<ROLE>_MODEL_FILE vars sourced from
# provision.env, so any number of model slots works. Idempotent: fetch uses ifSourceNewer, and
# a restart is signalled (MODELS_CHANGED) only when the enabled role=file set changed since the
# last deploy (filenames are immutable, so a name change == a content change).
deploy_models() {
  local data_dir models_dir mfvar role efvar file fingerprint entry
  local enabled=()

  data_dir="${WIAB_DATA_DIR:-/var/lib/wiab}"
  models_dir="$data_dir/models"
  upsert_wiab_env WIAB_DATA_DIR "$data_dir"

  # Purge roles that wiab.env still has but the desired config (provision.env) no longer
  # defines, so a removed model stops being loaded. Keyed on WIAB_<ROLE>_MODEL_FILE, which
  # only model roles have (auth flags are WIAB_AUTH_*_ENABLED, never *_MODEL_FILE).
  if [ -f /etc/wiab/wiab.env ]; then
    for old in $(grep -oE '^WIAB_[A-Z0-9]+_MODEL_FILE=' /etc/wiab/wiab.env | sed -E 's/^WIAB_(.+)_MODEL_FILE=$/\1/'); do
      if ! compgen -A variable | grep -qx "WIAB_${old}_MODEL_FILE"; then
        sed -i "/^WIAB_${old}_ENABLED=/d;/^WIAB_${old}_MODEL_FILE=/d" /etc/wiab/wiab.env
        log "models: removed stale role ${old} from wiab.env"
      fi
    done
  fi

  for mfvar in $(compgen -A variable | grep -E '^WIAB_[A-Z0-9]+_MODEL_FILE$' || true); do
    role="${mfvar#WIAB_}"; role="${role%_MODEL_FILE}"
    efvar="WIAB_${role}_ENABLED"
    file="${!mfvar:-}"
    upsert_wiab_env "WIAB_${role}_ENABLED" "${!efvar:-false}"
    upsert_wiab_env "WIAB_${role}_MODEL_FILE" "$file"
    if is_enabled "${!efvar:-}"; then
      [ -n "$file" ] || { log "FATAL: $role enabled but $mfvar is empty"; exit 1; }
      enabled+=("${role}=${file}")
    fi
  done

  if [ "${#enabled[@]}" -eq 0 ]; then
    fingerprint=""
    log "models: none enabled"
  else
    fingerprint="$(printf '%s\n' "${enabled[@]}" | LC_ALL=C sort | tr '\n' ';')"
    [ -n "${WIAB_MODELS_URL:-}" ] || { log "FATAL: models enabled but WIAB_MODELS_URL unset"; exit 1; }
    ensure_azcopy
    install -d -o wiab -g wiab "$models_dir"
    for entry in "${enabled[@]}"; do
      file="${entry#*=}"
      log "models: fetching $file"
      azcopy copy "$(models_blob_url "$file")" "$models_dir/$file" --overwrite=ifSourceNewer
      chown wiab:wiab "$models_dir/$file"
    done
  fi

  if [ "$FORCE" -ne 1 ] && [ "$(get_recorded WIAB_MODELS_FINGERPRINT)" = "$fingerprint" ]; then
    log "models: set unchanged"
    return 0
  fi
  set_recorded WIAB_MODELS_FINGERPRINT "$fingerprint"
  MODELS_CHANGED=1
  log "models: set changed"
}

deploy_backend() {
  local spec="$1"
  [ "$spec" = "skip" ] && { log "backend: skip"; return 0; }

  local json tag tgz sha tmp bak exp got bn f
  json="$(release_json "$WIAB_BACKEND_REPO" "$spec")"
  tag="$(echo "$json" | jq -r '.tag_name')"
  [ -n "$tag" ] && [ "$tag" != "null" ] || { log "FATAL: backend release '$spec' not found"; exit 1; }
  if [ "$FORCE" -ne 1 ] && [ "$(get_recorded WIAB_BACKEND_VERSION)" = "$tag" ]; then
    log "backend: already $tag, skip"; return 0
  fi

  tgz="$(echo "$json" | jq -r '.assets[] | select(.name|test("x86_64-linux-gnu\\.tar\\.gz$")) | .browser_download_url')"
  sha="$(echo "$json" | jq -r '.assets[] | select(.name|test("x86_64-linux-gnu\\.sha256$")) | .browser_download_url')"
  [ -n "$tgz" ] && [ "$tgz" != "null" ] || { log "FATAL: backend $tag has no tarball asset"; exit 1; }

  tmp="$(mktmp)"
  log "backend: downloading $tag"
  curl -fsSL -o "$tmp/wiab.tar.gz" "$tgz"
  tar -xzf "$tmp/wiab.tar.gz" -C "$tmp"
  if [ -n "$sha" ] && [ "$sha" != "null" ]; then
    curl -fsSL -o "$tmp/wiab.sha256" "$sha"
    exp="$(awk '{print $1}' "$tmp/wiab.sha256")"
    got="$(sha256sum "$tmp/wiab" | awk '{print $1}')"
    [ "$exp" = "$got" ] || { log "FATAL: backend sha256 mismatch"; exit 1; }
  fi

  # Snapshot current build (binary + the lib names this release ships) for rollback.
  bak="$(mktmp)"; mkdir -p "$bak/lib"
  [ -x /usr/local/bin/wiab ] && cp -P /usr/local/bin/wiab "$bak/wiab"
  if ls "$tmp"/lib/*.so* >/dev/null 2>&1; then
    for f in "$tmp"/lib/*.so*; do
      bn="$(basename "$f")"
      [ -e "/usr/local/lib/$bn" ] && cp -P "/usr/local/lib/$bn" "$bak/lib/$bn"
    done
  fi

  install -m 0755 "$tmp/wiab" /usr/local/bin/wiab
  if ls "$tmp"/lib/*.so* >/dev/null 2>&1; then
    cp -P "$tmp"/lib/*.so* /usr/local/lib/; ldconfig
  fi

  log "backend: restarting wiab @ $tag"
  systemctl restart wiab || true
  if backend_healthy; then
    set_recorded WIAB_BACKEND_VERSION "$tag"
    BACKEND_RESTARTED=1
    log "backend: $tag healthy"
  else
    log "ERROR: backend $tag failed health check — rolling back"
    [ -e "$bak/wiab" ] && install -m 0755 "$bak/wiab" /usr/local/bin/wiab
    ls "$bak"/lib/*.so* >/dev/null 2>&1 && { cp -P "$bak"/lib/*.so* /usr/local/lib/; ldconfig; }
    systemctl restart wiab || true
    if backend_healthy; then log "backend: rolled back to previous build"; else log "backend: ROLLBACK ALSO UNHEALTHY — investigate"; fi
    exit 1
  fi
}

deploy_frontend() {
  local spec="$1"
  [ "$spec" = "skip" ] && { log "frontend: skip"; return 0; }

  local json tag tgz sha tmp exp got target tmplink
  json="$(release_json "$WIAB_FRONTEND_REPO" "$spec")"
  tag="$(echo "$json" | jq -r '.tag_name')"
  [ -n "$tag" ] && [ "$tag" != "null" ] || { log "FATAL: frontend release '$spec' not found"; exit 1; }
  if [ "$FORCE" -ne 1 ] && [ "$(get_recorded WIAB_FRONTEND_VERSION)" = "$tag" ]; then
    log "frontend: already $tag, skip"; return 0
  fi

  tgz="$(echo "$json" | jq -r '.assets[] | select(.name|test("dist\\.tar\\.gz$")) | .browser_download_url')"
  sha="$(echo "$json" | jq -r '.assets[] | select(.name|test("dist\\.tar\\.gz\\.sha256$")) | .browser_download_url')"
  [ -n "$tgz" ] && [ "$tgz" != "null" ] || { log "FATAL: frontend $tag has no dist asset"; exit 1; }

  tmp="$(mktmp)"
  log "frontend: downloading $tag"
  curl -fsSL -o "$tmp/dist.tar.gz" "$tgz"
  if [ -n "$sha" ] && [ "$sha" != "null" ]; then
    curl -fsSL -o "$tmp/dist.tar.gz.sha256" "$sha"
    exp="$(awk '{print $1}' "$tmp/dist.tar.gz.sha256")"
    got="$(sha256sum "$tmp/dist.tar.gz" | awk '{print $1}')"
    [ "$exp" = "$got" ] || { log "FATAL: frontend sha256 mismatch"; exit 1; }
  fi
  tar -xzf "$tmp/dist.tar.gz" -C "$tmp"

  mkdir -p "$RELEASES_DIR"
  target="$RELEASES_DIR/$tag"
  rm -rf "$target"; mkdir -p "$target"
  cp -r "$tmp"/dist/* "$target/"
  chown -R www-data:www-data "$target"

  # Atomically point /var/www/wiab at the new release (migrate from a plain dir if needed).
  if [ -d /var/www/wiab ] && [ ! -L /var/www/wiab ]; then rm -rf /var/www/wiab; fi
  tmplink="$(mktemp -u /var/www/.wiab-link.XXXXXX)"
  ln -s "$target" "$tmplink"
  mv -Tf "$tmplink" /var/www/wiab
  nginx -s reload 2>/dev/null || systemctl reload nginx || true
  set_recorded WIAB_FRONTEND_VERSION "$tag"
  log "frontend: $tag deployed"

  # Keep only the 3 most recent release dirs.
  ls -1dt "$RELEASES_DIR"/*/ 2>/dev/null | tail -n +4 | xargs -r rm -rf
}

# Models first, so a new model file + synced env are in place before any backend restart.
deploy_models
deploy_backend "$BACKEND_SPEC"
deploy_frontend "$FRONTEND_SPEC"

# If the model set changed but the backend wasn't restarted by its own deploy, restart now so
# the running process picks up the new model (models load eagerly at startup).
if [ "$MODELS_CHANGED" -eq 1 ] && [ "$BACKEND_RESTARTED" -ne 1 ]; then
  log "models changed without a backend update — restarting wiab"
  systemctl restart wiab || true
  if backend_healthy; then
    log "wiab healthy after model change"
  else
    log "ERROR: wiab unhealthy after model change — investigate"
    exit 1
  fi
fi

log "deploy complete"
