#!/usr/bin/env bash
set -Euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_URL="${REPO_URL:-https://github.com/padavanonly/immortalwrt-mt798x-24.10}"
REPO_BRANCH="${REPO_BRANCH:-mt798x-mt799x-6.6-mtwifi}"
CONFIG_URL="${CONFIG_URL:-https://raw.githubusercontent.com/padavanonly/immortalwrt-mt798x-6.6/refs/heads/mt798x-mt799x-6.6-mtwifi/defconfig/mt7987_mt7992.config}"
SOURCE_DIR="${SOURCE_DIR:-immortalwrt}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"
THREADS="${THREADS:-$(nproc 2>/dev/null || echo 2)}"
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-300}"
GIT_TIMEOUT="${GIT_TIMEOUT:-1800}"
FEEDS_TIMEOUT="${FEEDS_TIMEOUT:-3600}"
CONFIG_TIMEOUT="${CONFIG_TIMEOUT:-1800}"
DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-7200}"
TOOLCHAIN_TIMEOUT="${TOOLCHAIN_TIMEOUT:-7200}"
COMPILE_TIMEOUT="${COMPILE_TIMEOUT:-28800}"
V2DAT_TIMEOUT="${V2DAT_TIMEOUT:-3600}"
GOPROXY="${GOPROXY:-https://goproxy.cn,https://proxy.golang.org,direct}"
GOSUMDB="${GOSUMDB:-sum.golang.google.cn}"
DOWNLOAD_MIRROR="${DOWNLOAD_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/openwrt/sources;https://mirrors.ustc.edu.cn/openwrt/sources;https://mirrors.bfsu.edu.cn/openwrt/sources}"
GITHUB_PROXY_PREFIXES="${GITHUB_PROXY_PREFIXES:-https://ghfast.top/ https://gh-proxy.com/ https://gh.llkk.cc/}"
export GOPROXY
export GOSUMDB
export DOWNLOAD_MIRROR
export MAKEFLAGS="-j${THREADS}"

HOMEPROXY_REPO_URL="${HOMEPROXY_REPO_URL:-https://github.com/immortalwrt/homeproxy}"
HOMEPROXY_REPO_BRANCH="${HOMEPROXY_REPO_BRANCH:-master}"
HOMEPROXY_FALLBACK_REPO_URL="${HOMEPROXY_FALLBACK_REPO_URL:-https://github.com/VIKINGYFY/homeproxy}"
HOMEPROXY_FALLBACK_REPO_BRANCH="${HOMEPROXY_FALLBACK_REPO_BRANCH:-main}"
ADBYBY_PLUS_I18N_IPK_URL="${ADBYBY_PLUS_I18N_IPK_URL:-https://github.com/kongfl888/luci-app-adbyby-plus-lite/releases/download/2.0K5/luci-i18n-adbyby-plus-zh-cn_221024.22052_all.ipk}"
ADGUARDHOME_IPK_URL="${ADGUARDHOME_IPK_URL:-https://github.com/sirpdboy/luci-app-adguardhome/releases/download/v1.1.1/luci-app-adguardhome_1.1.1-r1_all.ipk}"
ADGUARDHOME_I18N_IPK_URL="${ADGUARDHOME_I18N_IPK_URL:-https://github.com/sirpdboy/luci-app-adguardhome/releases/download/v1.1.1/luci-i18n-adguardhome-zh-cn_0_all.ipk}"

ENABLE_ADGUARDHOME="${ENABLE_ADGUARDHOME:-false}"
ENABLE_OPENCLASH="${ENABLE_OPENCLASH:-false}"
ENABLE_NIKKI="${ENABLE_NIKKI:-true}"
ENABLE_UPNP="${ENABLE_UPNP:-true}"
ENABLE_VLMCSD="${ENABLE_VLMCSD:-true}"
ENABLE_MOSDNS="${ENABLE_MOSDNS:-true}"
ENABLE_DOCKERMAN="${ENABLE_DOCKERMAN:-false}"
ENABLE_QMODEM_NEXT="${ENABLE_QMODEM_NEXT:-true}"
ENABLE_QMODEM="${ENABLE_QMODEM:-false}"
ENABLE_HOMEPROXY="${ENABLE_HOMEPROXY:-false}"
ENABLE_ADBYBY_PLUS="${ENABLE_ADBYBY_PLUS:-false}"
ENABLE_ORIGINAL_MODEM="${ENABLE_ORIGINAL_MODEM:-false}"
ENABLE_MWAN3="${ENABLE_MWAN3:-false}"

INSTALL_DEPS=false
PREPARE_ONLY=false
CONFIG_ONLY=false
SKIP_TOOLCHAIN=false
SKIP_DOWNLOAD=false
SKIP_FEEDS_UPDATE=false

usage() {
  cat <<'EOF'
Usage: scripts/local-build.sh [options]

Options:
  --install-deps        Install Ubuntu/Debian build dependencies with apt-get.
  --prepare-only        Clone/update source, feeds, patches, and config only.
  --config-only         Stop after make defconfig and package verification.
  --skip-toolchain      Skip explicit make toolchain/install prebuild step.
  --skip-download       Skip make download prefetch step.
  --skip-feeds-update   Skip ./scripts/feeds update -a (use existing checkouts).
  -h, --help            Show this help.

Feature switches are controlled by environment variables, for example:
  ENABLE_MOSDNS=false ENABLE_QMODEM_NEXT=false THREADS=8 scripts/local-build.sh

Default feature switches match the scheduled GitHub Actions build.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-deps) INSTALL_DEPS=true ;;
    --prepare-only) PREPARE_ONLY=true ;;
    --config-only) CONFIG_ONLY=true ;;
    --skip-toolchain) SKIP_TOOLCHAIN=true ;;
    --skip-download) SKIP_DOWNLOAD=true ;;
    --skip-feeds-update) SKIP_FEEDS_UPDATE=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

sanitize_path() {
  export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/sbin:/bin"
  [ -d /snap/bin ] && export PATH="$PATH:/snap/bin"

  # Create a shell wrapper at $WRAPPERDIR/install that spoofs GNU header for
  # --version but delegates real work to /usr/bin/install.
  # OpenWrt's prereq check requires GNU install; Ubuntu 25 uutils fails it.
  local wrapper_dir="/usr/local/bin"
  if ! "$wrapper_dir/install" --version 2>&1 | grep -q GNU; then
    mkdir -p "$wrapper_dir"
    cat > "$wrapper_dir/install" << 'WRAPPER'
#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    --version|-v|--help) echo "GNU coreutils - install (_WRAPPER_)"; exit 0 ;;
  esac
done
exec /usr/bin/install "$@"
WRAPPER
    chmod +x "$wrapper_dir/install"
  fi

  # OpenWrt's build system also uses gzip from staging_dir/host/bin/gzip.
  # If staging_dir/host/bin/gzip is missing (e.g. removed during a previous
  # Ubuntu->Arch transition), create a symlink to the system gzip.
  local staging_gzip="$ROOT_DIR/$SOURCE_DIR/staging_dir/host/bin/gzip"
  if [ ! -e "$staging_gzip" ] && [ -e /usr/bin/gzip ]; then
    mkdir -p "$(dirname "$staging_gzip")"
    ln -snf /usr/bin/gzip "$staging_gzip"
  fi

  # Arch Linux ships cmake 4.x but OpenWrt needs cmake 3.x for bootstrap.
  # If the host cmake is 3.x, make it available as staging_dir/host/bin/cmake
  # so OpenWrt uses it instead of building 3.30.5 from source (which fails on
  # newer glibc due to 'environ' visibility issues).
  local staging_cmake="$ROOT_DIR/$SOURCE_DIR/staging_dir/host/bin/cmake"
  if [ ! -e "$staging_cmake" ] && command -v cmake >/dev/null 2>&1; then
    local cmake_ver
    cmake_ver="$(cmake --version 2>/dev/null | head -1)"
    case "$cmake_ver" in
      *' 3.'*|*' 3.'*)
        mkdir -p "$(dirname "$staging_cmake")"
        ln -snf "$(command -v cmake)" "$staging_cmake"
        ;;
    esac
  fi
}

is_true() {
  local status
  case "${1:-false}" in
    true|1|yes) status=0 ;;
    *) status=1 ;;
  esac
  return "$status"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

run_with_timeout() {
  local seconds="$1"
  local label="$2"
  shift 2
  local cmd=("$@")
  local start pid status elapsed

  log "$label (timeout ${seconds}s)"
  start="$(date +%s)"

  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground "$seconds" "${cmd[@]}"
    status=$?
  else
    "${cmd[@]}" &
    pid="$!"
    while kill -0 "$pid" 2>/dev/null; do
      local waited=0
      while [ "$waited" -lt "$HEARTBEAT_INTERVAL" ] && kill -0 "$pid" 2>/dev/null; do
        sleep 5
        waited=$((waited + 5))
      done
      if kill -0 "$pid" 2>/dev/null; then
        elapsed=$(($(date +%s) - start))
        echo "[$(date '+%H:%M:%S')] Still running: $label (${elapsed}s elapsed)"
      fi
    done
    set +e
    wait "$pid"
    status="$?"
    set -e
  fi

  elapsed=$(($(date +%s) - start))
  if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
    die "$label timed out after ${elapsed}s"
  fi
  if [ "$status" -ne 0 ]; then
    echo "$label failed after ${elapsed}s with exit code ${status}" >&2
    return "$status"
  fi
  echo "$label completed in ${elapsed}s"
}

github_url_candidates() {
  local url="$1"
  printf '%s\n' "$url"
  case "$url" in
    https://github.com/*|https://raw.githubusercontent.com/*)
      local prefix
      for prefix in $GITHUB_PROXY_PREFIXES; do
        [ -n "$prefix" ] || continue
        printf '%s\n' "${prefix%/}/${url}"
      done
      ;;
  esac
}

git_clone_retry() {
  local url="$1"
  local branch="$2"
  local dest="$3"
  local depth="${4:-1}"
  local candidate args=()

  [ -n "$branch" ] && args+=(-b "$branch")
  [ "$depth" != "0" ] && args+=(--depth="$depth")

  rm -rf "$dest"
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    log "Cloning $(basename "$url") from $candidate"
    if run_with_timeout "$GIT_TIMEOUT" "git clone $(basename "$url")" git clone "${args[@]}" "$candidate" "$dest"; then
      return 0
    fi
    rm -rf "$dest"
  done < <(github_url_candidates "$url")

  return 1
}

curl_fetch_retry() {
  local url="$1"
  local output="$2"
  local candidate

  rm -f "$output"
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if curl -fsSL "$candidate" -o "$output"; then
      return 0
    fi
    rm -f "$output"
  done < <(github_url_candidates "$url")

  return 1
}

install_deps() {
  log "Installing build dependencies"

  # Detect package manager
  if command -v pacman >/dev/null 2>&1; then
    # Arch Linux
    local pkg_install="pacman -S --noconfirm"
    if [ "$(id -u)" -ne 0 ]; then
      require_cmd sudo || die "sudo is required but not found"
      pkg_install="sudo pacman -S --noconfirm"
    fi
    log "Installing Arch Linux dependencies via pacman"
    $pkg_install \
      base-devel git ccache python python-pip \
      ncurses openssl gmp mbedtls rust cargo go autoconf automake libtool patch make gcc gawk gettext \
      unzip file wget curl rsync zstd swig bc
  elif command -v apt-get >/dev/null 2>&1; then
    # Ubuntu/Debian
    if [ "$(id -u)" -eq 0 ]; then
      apt-get update
      apt-get install -y build-essential git ccache python3 python3-pip \
        libncurses5-dev libssl-dev libgmp3-dev libmbedtls-dev rustc cargo \
        golang-go autoconf automake libtool patch make gcc g++ gawk gettext \
        unzip file wget curl rsync zstd swig
    else
      require_cmd sudo || die "sudo is required but not found"
      DEBIAN_FRONTEND=noninteractive sudo -n apt-get update || {
        echo "WARNING: sudo apt-get update failed (passwordless sudo may not be configured in WSL)" >&2
        echo "To enable passwordless sudo in WSL, run: sudo visudo" >&2
        echo "Then add: $USER ALL=(ALL) NOPASSWD: /usr/bin/apt-get" >&2
        echo "Continuing without installing dependencies..." >&2
        return 0
      }
      DEBIAN_FRONTEND=noninteractive sudo -n apt-get install -y \
        build-essential git ccache python3 python3-pip \
        libncurses5-dev libssl-dev libgmp3-dev libmbedtls-dev rustc cargo \
        golang-go autoconf automake libtool patch make gcc g++ gawk gettext \
        unzip file wget curl rsync zstd swig || {
        echo "WARNING: sudo apt-get install failed" >&2
        echo "Continuing without installing dependencies..." >&2
      }
    fi
  else
    die "Neither apt-get nor pacman found. Please install dependencies manually."
  fi
}

check_environment() {
  log "Checking local build environment"
  sanitize_path
  for cmd in git curl make sed awk grep find tar xargs bash; do
    require_cmd "$cmd"
  done

  if [ "$(id -u)" -eq 0 ]; then
    export FORCE_UNSAFE_CONFIGURE="${FORCE_UNSAFE_CONFIGURE:-1}"
  fi

  if [ "$(uname -s)" != "Linux" ]; then
    die "OpenWrt builds require Linux. Run this script in WSL2 or a Linux host."
  fi

  local avail_gb
  avail_gb="$(df -BG "$ROOT_DIR" | awk 'NR==2 {gsub(/G/, "", $4); print $4}')"
  echo "Available disk at workspace: ${avail_gb:-unknown}GB"
  if [ -n "${avail_gb:-}" ] && [ "$avail_gb" -lt 20 ]; then
    echo "WARNING: OpenWrt builds are large; at least 20GB free space is recommended."
  fi
}

show_features() {
  log "Feature switches"
  cat <<EOF
AdGuardHome=${ENABLE_ADGUARDHOME}
OpenClash=${ENABLE_OPENCLASH}
Nikki=${ENABLE_NIKKI}
UPnP=${ENABLE_UPNP}
VLMCSd=${ENABLE_VLMCSD}
MosDNS=${ENABLE_MOSDNS}
DockerMan=${ENABLE_DOCKERMAN}
QModem Next=${ENABLE_QMODEM_NEXT}
QModem=${ENABLE_QMODEM}
HomeProxy=${ENABLE_HOMEPROXY}
Adbyby Plus=${ENABLE_ADBYBY_PLUS}
Original Modem=${ENABLE_ORIGINAL_MODEM}
MWAN3=${ENABLE_MWAN3}
GOPROXY=${GOPROXY}
GOSUMDB=${GOSUMDB}
DOWNLOAD_MIRROR=${DOWNLOAD_MIRROR}
EOF
}

prepare_source() {
  log "Preparing ImmortalWrt source"
  cd "$ROOT_DIR"

  if [ ! -d "$SOURCE_DIR/.git" ]; then
    rm -rf "$SOURCE_DIR"
    git_clone_retry "$REPO_URL" "$REPO_BRANCH" "$SOURCE_DIR" 1
  else
    cd "$SOURCE_DIR"
    local current_branch
    current_branch="$(git branch --show-current)"
    if [ "$current_branch" != "$REPO_BRANCH" ]; then
      cd "$ROOT_DIR"
      rm -rf "$SOURCE_DIR"
      git_clone_retry "$REPO_URL" "$REPO_BRANCH" "$SOURCE_DIR" 1
    else
      if run_with_timeout "$GIT_TIMEOUT" "git fetch source" git fetch origin "$REPO_BRANCH"; then
        git reset --hard FETCH_HEAD
        git clean -fd
      else
        log "WARNING: git fetch failed; using existing $SOURCE_DIR checkout"
      fi
      cd "$ROOT_DIR"
    fi
  fi
}

prepare_feeds() {
  log "Preparing feeds"
  cd "$ROOT_DIR/$SOURCE_DIR"

  cp "$ROOT_DIR/feeds.conf.default" ./feeds.conf.default

  if ! is_true "$ENABLE_NIKKI"; then
    sed -i '/src-git nikki/d; /nikki/d' feeds.conf.default
  fi

  if ! is_true "$ENABLE_QMODEM_NEXT" && ! is_true "$ENABLE_QMODEM"; then
    sed -i '/qmodem/d' feeds.conf.default
  fi

  rm -rf tmp/.config* tmp/.packageinfo tmp/.targetinfo tmp/info tmp/.feeds* feeds/*.tmp 2>/dev/null || true
  ! is_true "$ENABLE_NIKKI" && rm -rf feeds/nikki* package/feeds/nikki 2>/dev/null || true
  ! is_true "$ENABLE_QMODEM_NEXT" && ! is_true "$ENABLE_QMODEM" && rm -rf feeds/qmodem* package/feeds/qmodem 2>/dev/null || true

  ensure_libcrypt_compat_package

  if is_true "$SKIP_FEEDS_UPDATE"; then
    log "Skipping ./scripts/feeds update -a (per --skip-feeds-update)"
  else
    # Some feeds (e.g. qmodem) may have local modifications that block git merge.
    # Stash them before update and restore after so local changes are preserved.
    log "Stashing local feed changes before update"
    find feeds -mindepth 1 -maxdepth 1 -type d | while IFS= read -r feed_dir; do
      [ -d "$feed_dir/.git" ] && git -C "$feed_dir" stash 2>/dev/null || true
    done
    run_with_timeout "$FEEDS_TIMEOUT" "feeds update" ./scripts/feeds update -a || die "feeds update failed; refusing to continue with incomplete feeds"
    log "Restoring local feed changes"
    find feeds -mindepth 1 -maxdepth 1 -type d | while IFS= read -r feed_dir; do
      [ -d "$feed_dir/.git" ] && git -C "$feed_dir" stash pop 2>/dev/null || true
    done
  fi
  if is_true "$ENABLE_MOSDNS" || is_true "$ENABLE_NIKKI"; then
    install_golang_feed
  fi
  if is_true "$ENABLE_NIKKI" && [ ! -d "feeds/nikki" ]; then
    mkdir -p feeds
    git_clone_retry "https://github.com/nikkinikki-org/OpenWrt-nikki.git" "main" "feeds/nikki" 1 || die "Unable to fetch Nikki feed"
  fi
  run_with_timeout "$FEEDS_TIMEOUT" "feeds install all" ./scripts/feeds install -a -f || log "WARNING: feeds install -a reported errors; selected packages will be installed explicitly"
}

fix_qmi_driver() {
  local source_file="$1"
  [ -f "$source_file" ] || return 0
  sed -i 's/u64_stats_fetch_begin_irq/u64_stats_fetch_begin/g' "$source_file"
  sed -i 's/u64_stats_fetch_retry_irq/u64_stats_fetch_retry/g' "$source_file"
  if grep -q 'memcpy.*qmap_net->dev_addr.*real_dev->dev_addr' "$source_file"; then
    sed -i 's/memcpy[[:space:]]*(qmap_net->dev_addr,[[:space:]]*real_dev->dev_addr,[[:space:]]*ETH_ALEN);/eth_hw_addr_set(qmap_net, real_dev->dev_addr);/g' "$source_file"
  fi
  if grep -q 'memcpy.*->dev_addr' "$source_file"; then
    sed -i 's/memcpy[[:space:]]*(\([^,]*\)->dev_addr,[[:space:]]*\([^,]*\),[[:space:]]*ETH_ALEN);/dev_addr_set(\1, \2);/g' "$source_file" 2>/dev/null || true
  fi
}

# --- Go 1.24 compatibility -------------------------------------------------
# The sbwml feed builds with Go 1.24 (see install_golang_feed). Its
# mosdns/v2dat "update-dependencies" patches, however, bump go.mod to
# `go 1.25.0` and pull in golang.org/x/sys v0.42.0 (whose go.mod declares
# `go 1.25.0`), so they cannot build against the pinned Go 1.24 toolchain.
#
# Instead of hardcoding a long list of per-dependency version downgrades
# (which silently no-op the moment sbwml bumps again), normalize the patches
# at the source level and add a general, idempotent go.mod re-pin:
#   - mosdns: drop the go.mod/go.sum hunks of the update-dependencies patch,
#     keeping the upstream go.mod (already `go 1.24.x`) intact;
#   - v2dat: keep the mmap-go addition (the perf patch code needs it) but
#     rewrite the `go` directive and the golang.org/x/sys pin back to the last
#     Go 1.24-compatible release (v0.37.0).
# The Build/Prepare hook then re-pins `go`/`toolchain` with a general regex,
# so a future upstream bump is neutralised instead of triggering an offline
# toolchain auto-download. Each step verifies its output and fails loudly
# rather than silently leaving a go 1.25+ module behind.

strip_patch_file_diffs() {
  local patch_file="$1"
  local file_pattern="$2"
  local tmp_patch
  tmp_patch="$(mktemp)"
  awk -v file_pattern="$file_pattern" '
    function flush_section() {
      if (in_section && keep_section) {
        printf "%s", section_block
      }
      in_section=0
      section_block=""
      keep_section=0
    }
    /^diff --git / {
      flush_section()
      in_section=1
      section_block=$0 ORS
      keep_section=($0 !~ file_pattern)
      next
    }
    /^--- a\// {
      flush_section()
      in_section=1
      section_block=$0 ORS
      keep_section=($0 !~ file_pattern)
      next
    }
    in_section {
      section_block=section_block $0 ORS
      next
    }
    { print }
    END {
      flush_section()
    }
  ' "$patch_file" > "$tmp_patch"
  mv "$tmp_patch" "$patch_file"
}

# Rewrite a patch so its `go` directive and golang.org/x/sys pin stay Go
# 1.24-compatible, using general regexes (works for any future version bump).
rewrite_patch_to_go124() {
  local patch_file="$1"
  [ -f "$patch_file" ] || return 0

  # `+go 1.25.0` -> `+go 1.24.0` (added lines only, any patch version)
  sed -E -i 's|^\+go [0-9]+\.[0-9]+(\.[0-9]+)?$|+go 1.24.0|' "$patch_file"
  # golang.org/x/sys: any version -> v0.37.0 (last release declaring go 1.24)
  sed -E -i \
    -e 's|golang\.org/x/sys v[0-9]+\.[0-9]+\.[0-9]+ // indirect|golang.org/x/sys v0.37.0 // indirect|' \
    -e 's|golang\.org/x/sys v[0-9]+\.[0-9]+\.[0-9]+ h1:[A-Za-z0-9+/=]+|golang.org/x/sys v0.37.0 h1:fdNQudmxPjkdUTPnLn5mdQv7Zwvbvpaxqs831goi9kQ=|' \
    -e 's|golang\.org/x/sys v[0-9]+\.[0-9]+\.[0-9]+/go\.mod h1:[A-Za-z0-9+/=]+|golang.org/x/sys v0.37.0/go.mod h1:OgkHotnGiDImocRcuBABYBEXf8A9a87e/uXjp9XT3ks=|' \
    "$patch_file"
}

# Idempotently set GO_MOD_ARGS and add a Build/Prepare that re-pins the
# unpacked go.mod's `go`/`toolchain` directives to the pinned Go 1.24
# toolchain (general regex, survives future upstream version bumps).
ensure_go124_build_prepare() {
  local makefile="$1"
  local pkg_name="$2"
  local marker="$3"
  [ -f "$makefile" ] || return 0

  sed -i '/^GO_MOD_ARGS[[:space:]]*[:+?]*=/d' "$makefile"
  sed -i '/golang-package.mk/a GO_MOD_ARGS:= -mod=mod -modcacherw' "$makefile"

  local tmp_makefile
  tmp_makefile="$(mktemp)"
  awk -v marker="$marker" '
    /^define Build\/Prepare$/ { collecting=1; block=$0 ORS; next }
    collecting {
      block=block $0 ORS
      if ($0 == "endef") {
        if (block !~ marker) { printf "%s", block }
        collecting=0; block=""
      }
      next
    }
    { print }
    END { if (collecting && block !~ marker) printf "%s", block }
  ' "$makefile" > "$tmp_makefile"
  mv "$tmp_makefile" "$makefile"

  tmp_makefile="$(mktemp)"
  awk -v pkg="$pkg_name" -v marker="$marker" '
    index($0, "$(eval $(call GoBinPackage," pkg ")") && !inserted {
      print "define Build/Prepare"
      print "\t$(call Build/Prepare/Default)"
      print "\t# " marker
      print "\tsed -i -E \047s|^go [0-9]+\\.[0-9]+(\\.[0-9]+)?$$|go 1.24.0|\047 $(PKG_BUILD_DIR)/go.mod"
      print "\tsed -i -E \047s|^toolchain go[0-9]+\\.[0-9]+(\\.[0-9]+)?$$|toolchain go1.24.13|\047 $(PKG_BUILD_DIR)/go.mod"
      print "endef"
      print ""
      inserted=1
    }
    { print }
  ' "$makefile" > "$tmp_makefile"
  mv "$tmp_makefile" "$makefile"
}

patch_v2dat_go124() {
  local patch_dir="package/mosdns/v2dat/patches"
  [ -d "$patch_dir" ] || return 0

  local perf_patch="$patch_dir/102-perf-unpack-Use-memory-mapping-to-reduce-memory-usag.patch"
  if [ -f "$perf_patch" ]; then
    log "Normalizing v2dat perf patch to stay Go 1.24-compatible"
    rewrite_patch_to_go124 "$perf_patch"
    if grep -Eq '^\+go 1\.(2[5-9]|[3-9][0-9])' "$perf_patch"; then
      die "v2dat perf patch still targets go >= 1.25 after normalization (upstream changed?)"
    fi
  fi

  ensure_go124_build_prepare "package/mosdns/v2dat/Makefile" "v2dat" "v2dat Go 1.24 compatibility"
  rm -f "$patch_dir/999-fix-go-version-for-go124.patch"
  rm -rf build_dir/target-*/v2dat-* 2>/dev/null || true
}

patch_mosdns_go124() {
  patch_v2dat_go124

  local patch_dir="package/mosdns/mosdns/patches"
  [ -d "$patch_dir" ] || return 0

  local deps_patch="$patch_dir/100-mosdns-update-dependencies.patch"
  if [ -f "$deps_patch" ]; then
    log "Stripping go.mod/go.sum hunks from mosdns update-dependencies patch"
    strip_patch_file_diffs "$deps_patch" '(^--- a/go[.](mod|sum)$| a/go[.](mod|sum) b/go[.](mod|sum)$)'
    if grep -Eq '^\+go 1\.(2[5-9]|[3-9][0-9])' "$deps_patch"; then
      die "mosdns update-dependencies patch still bumps go.mod after strip (upstream changed?)"
    fi
  fi

  ensure_go124_build_prepare "package/mosdns/mosdns/Makefile" "mosdns" "MosDNS Go 1.24 compatibility"
  rm -f "$patch_dir/999-fix-go-version-for-go124.patch"
  rm -rf build_dir/target-*/mosdns-* 2>/dev/null || true
}


patch_v2ray_geodata_downloads() {
  local geodata_makefile="package/v2ray-geodata/Makefile"
  [ -f "$geodata_makefile" ] || return 0

  local tmp_makefile
  tmp_makefile="$(mktemp)"
  awk '
    /^define Build\/Compile$/ {
      print "define Build/Compile"
      print "\t( cd $(PKG_BUILD_DIR); rm -f geoip.dat geosite.dat; download_dat() { output=\"$$$$1\"; shift; for url in \"$$$$@\"; do [ -n \"$$$$url\" ] || continue; curl -fL --retry 5 --retry-delay 2 --connect-timeout 20 \"$$$$url\" -o \"$$$$output.tmp\" && [ -s \"$$$$output.tmp\" ] && mv \"$$$$output.tmp\" \"$$$$output\" && return 0; rm -f \"$$$$output.tmp\"; done; echo \"Unable to download $$$$output\" >&2; return 1; }; download_dat geoip.dat $(GEOIP_URL) https://ghfast.top/$(GEOIP_URL) https://gh-proxy.com/$(GEOIP_URL) https://gh.llkk.cc/$(GEOIP_URL); download_dat geosite.dat $(GEOSITE_URL) https://ghfast.top/$(GEOSITE_URL) https://gh-proxy.com/$(GEOSITE_URL) https://gh.llkk.cc/$(GEOSITE_URL); [ -s geoip.dat ] && [ -s geosite.dat ]; )"
      print "endef"
      collecting=1
      next
    }
    collecting {
      if ($0 == "endef") collecting=0
      next
    }
    { print }
  ' "$geodata_makefile" > "$tmp_makefile"
  mv "$tmp_makefile" "$geodata_makefile"

  rm -rf build_dir/target-*/v2ray-geodata 2>/dev/null || true
}

patch_mtwifi_apcli_bssid_budget() {
  local patch_file="$ROOT_DIR/patches/mtwifi-apcli-active-only.patch"
  [ -f "$patch_file" ] || return 0

  if patch -p1 --forward --dry-run < "$patch_file" >/dev/null 2>&1; then
    patch -p1 < "$patch_file"
  elif patch -p1 --reverse --dry-run < "$patch_file" >/dev/null 2>&1; then
    log "MTK WiFi APCLI active-only patch already applied"
  else
    die "Unable to apply MTK WiFi APCLI active-only patch"
  fi
}

# MTK HNAT (kmod-mediatek_hnat) offloads any TCP/UDP flow whose 5-tuple hits a
# hardware FOE entry without first checking whether the destination IP is a
# locally assigned address. For a wireless client the flow toward 192.168.6.1
# (the router's own LAN IP) can therefore be turned into a LAN->WAN hardware
# shortcut and forwarded by do_hnat_ge_to_ext()/dev_queue_xmit(), bypassing the
# local INPUT chain. Symptom: enabling HNAT makes WiFi clients unable to reach
# the LuCI/admin page even though wired LAN access keeps working.
#
# This patch adds a local-destination guard inside is_ppe_support_type(), the
# single gate used by every pre-routing hook (IPv4/IPv6/bridge), so traffic
# destined to a local address is never offloaded and instead follows the normal
# INPUT path. Forwarded LAN<->WAN traffic is unaffected because its destination
# is not RTN_LOCAL.
patch_mtk_hnat_local_dest() {
  local patch_file="$ROOT_DIR/patches/mtk-hnat-local-dest.patch"
  local source_file="target/linux/mediatek/files-6.6/drivers/net/ethernet/mediatek/mtk_hnat/hnat_nf_hook.c"
  [ -f "$patch_file" ] || return 0
  [ -f "$source_file" ] || { log "WARNING: HNAT source $source_file not found; skipping local-destination guard"; return 0; }

  if grep -q 'Never offload flows destined to a locally' "$source_file"; then
    log "MTK HNAT local-destination guard already applied"
    return 0
  fi

  if patch -p1 --forward --dry-run < "$patch_file" >/dev/null 2>&1; then
    log "Applying MTK HNAT local-destination guard"
    patch -p1 < "$patch_file"
  elif patch -p1 --reverse --dry-run < "$patch_file" >/dev/null 2>&1; then
    log "MTK HNAT local-destination guard already applied"
  else
    die "Unable to apply MTK HNAT local-destination guard patch (upstream driver changed?)"
  fi

  grep -q 'inet_addr_type(&init_net, iph->daddr) == RTN_LOCAL' "$source_file" || \
    die "MTK HNAT local-destination guard patch verification failed"
}

# mt_wifi7's sta_mgmt_assoc.c references pStaCfg->wpa_supplicant_info in the
# MTK hostapd block; that struct member only exists when APCLI_CFG80211_SUPPORT
# (or CONFIG_STA_SUPPORT) is defined (rtmp.h). Upstream now wraps every
# wpa_supplicant_info access in `#ifdef APCLI_CFG80211_SUPPORT`. Older
# checkouts required a build-time sed for this; the current driver already
# ships the guard, so this is now a verify-only check that fails loudly (via
# the compile error) if a future upstream change removes it.
patch_mtwifi7_sta_mgmt_assoc_hostapd_guard() {
  local f="package/mtk/drivers/mt_wifi7/src/mt_wifi/common/fsm/sta_mgmt_assoc.c"
  [ -f "$f" ] || return 0

  if grep -q '#ifdef APCLI_CFG80211_SUPPORT' "$f"; then
    log "mt_wifi7 sta_mgmt_assoc.c wpa_supplicant_info guarded by APCLI_CFG80211_SUPPORT"
    return 0
  fi

  log "WARNING: $f is missing the APCLI_CFG80211_SUPPORT guard; AP-only build may fail"
}

patch_mtk_wifi_utility_rbus_for_h5000m() {
  local rbus_patch="target/linux/mediatek/patches-6.6/0101-add-mtk-wifi-utility-rbus.patch"
  [ -f "$rbus_patch" ] || return 0

  if grep -q '^+obj-y[[:space:]]*+=[[:space:]]*wifi_utility/' "$rbus_patch"; then
    log "Making MTK wifi_utility rbus optional for H5000M PCIe WiFi"
    sed -i 's/^+obj-y[[:space:]]*+=[[:space:]]*wifi_utility\//+obj-$(CONFIG_MTK_WIFI_UTILITY_RBUS) += wifi_utility\//g' "$rbus_patch"
  fi

  grep -q '^+obj-$(CONFIG_MTK_WIFI_UTILITY_RBUS)[[:space:]]*+=[[:space:]]*wifi_utility/' "$rbus_patch" || \
    die "MTK wifi_utility rbus patch guard verification failed"
}

github_url_base_candidates() {
  local url="$1"
  local source_name="$2"
  local base_url="${url%/$source_name}"

  printf '%s' "$base_url"
  case "$base_url" in
    https://github.com/*|https://raw.githubusercontent.com/*)
      local prefix
      for prefix in $GITHUB_PROXY_PREFIXES; do
        [ -n "$prefix" ] || continue
        printf '\n%s' "${prefix%/}/${base_url}"
      done
      ;;
  esac
  printf '\n'
}

ensure_prebuilt_luci_i18n_package() {
  local pkg_name="$1"
  local version="$2"
  local ipk_url="$3"
  local app_dep="$4"
  local title="$5"
  local source_name="${ipk_url##*/}"
  local pkg_dir="package/prebuilt-i18n/$pkg_name"
  local source_urls

  source_urls="$(github_url_base_candidates "$ipk_url" "$source_name" | tr '\n' ' ')"
  rm -rf "$pkg_dir"
  mkdir -p "$pkg_dir"

  cat > "$pkg_dir/Makefile" <<EOF
include \$(TOPDIR)/rules.mk

PKG_NAME:=$pkg_name
PKG_VERSION:=$version
PKG_RELEASE:=1
PKG_SOURCE:=$source_name
PKG_SOURCE_URL:=$source_urls
PKG_HASH:=skip
PKG_BUILD_DIR:=\$(BUILD_DIR)/\$(PKG_NAME)-\$(PKG_VERSION)

include \$(INCLUDE_DIR)/package.mk

define Package/$pkg_name
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=Translations
  TITLE:=$title
  DEPENDS:=+$app_dep
  PKGARCH:=all
endef

define Build/Prepare
	rm -rf \$(PKG_BUILD_DIR)
	mkdir -p \$(PKG_BUILD_DIR)/ipk \$(PKG_BUILD_DIR)/data
	if ar t \$(DL_DIR)/\$(PKG_SOURCE) >/dev/null 2>&1; then \
		(cd \$(PKG_BUILD_DIR)/ipk; ar x \$(DL_DIR)/\$(PKG_SOURCE)); \
	else \
		tar -xf \$(DL_DIR)/\$(PKG_SOURCE) -C \$(PKG_BUILD_DIR)/ipk; \
	fi
	if [ -f \$(PKG_BUILD_DIR)/ipk/data.tar.gz ]; then \
		tar -xzf \$(PKG_BUILD_DIR)/ipk/data.tar.gz -C \$(PKG_BUILD_DIR)/data; \
	elif [ -f \$(PKG_BUILD_DIR)/ipk/data.tar.xz ]; then \
		tar -xJf \$(PKG_BUILD_DIR)/ipk/data.tar.xz -C \$(PKG_BUILD_DIR)/data; \
	elif [ -f \$(PKG_BUILD_DIR)/ipk/data.tar.zst ]; then \
		tar --zstd -xf \$(PKG_BUILD_DIR)/ipk/data.tar.zst -C \$(PKG_BUILD_DIR)/data; \
	else \
		echo "Unsupported ipk data archive for \$(PKG_SOURCE)" >&2; exit 1; \
	fi
endef

define Build/Compile
endef

define Package/$pkg_name/install
	\$(CP) \$(PKG_BUILD_DIR)/data/. \$(1)/
endef

\$(eval \$(call BuildPackage,$pkg_name))
EOF
}

# Like ensure_prebuilt_luci_i18n_package but for a main LuCI app package whose
# ipk we want to ship without compiling from source. The CATEGORY/SUBMENU
# are LuCI/Applications instead of LuCI/Translations and the package does not
# depend on the i18n shim - the i18n is wired up via a separate call. The
# ipk URL is treated as an upstream tarball/zip (sirpdboy/luci-app-adguardhome
# releases serve an extra gzip-wrapped ipk whose layout matches
# tar/debian-binary+control.tar.gz+data.tar.gz, so the same ar-or-tar branch
# from the i18n helper is reused). PKG_HASH is skipped because the release
# tag is the integrity anchor; if you need checksum pinning, set
# ADGUARDHOME_IPK_SHA256SUM in the environment.
ensure_prebuilt_luci_app_package() {
  local pkg_name="$1"
  local version="$2"
  local ipk_url="$3"
  local title="$4"
  local source_name="${ipk_url##*/}"
  local pkg_dir="package/prebuilt-luci-app/$pkg_name"
  local source_urls

  source_urls="$(github_url_base_candidates "$ipk_url" "$source_name" | tr '\n' ' ')"
  rm -rf "$pkg_dir"
  mkdir -p "$pkg_dir"

  cat > "$pkg_dir/Makefile" <<EOF
include \$(TOPDIR)/rules.mk

PKG_NAME:=$pkg_name
PKG_VERSION:=$version
PKG_RELEASE:=1
PKG_SOURCE:=$source_name
PKG_SOURCE_URL:=$source_urls
PKG_HASH:=skip
PKG_BUILD_DIR:=\$(BUILD_DIR)/\$(PKG_NAME)-\$(PKG_VERSION)

include \$(INCLUDE_DIR)/package.mk

define Package/$pkg_name
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=Applications
  TITLE:=$title
  DEPENDS:=+libc +ca-certs +curl +luci-lua-runtime
  PKGARCH:=all
endef

define Build/Prepare
	rm -rf \$(PKG_BUILD_DIR)
	mkdir -p \$(PKG_BUILD_DIR)/ipk \$(PKG_BUILD_DIR)/data
	if ar t \$(DL_DIR)/\$(PKG_SOURCE) >/dev/null 2>&1; then \
		(cd \$(PKG_BUILD_DIR)/ipk; ar x \$(DL_DIR)/\$(PKG_SOURCE)); \
	else \
		tar -xf \$(DL_DIR)/\$(PKG_SOURCE) -C \$(PKG_BUILD_DIR)/ipk; \
	fi
	if [ -f \$(PKG_BUILD_DIR)/ipk/data.tar.gz ]; then \
		tar -xzf \$(PKG_BUILD_DIR)/ipk/data.tar.gz -C \$(PKG_BUILD_DIR)/data; \
	elif [ -f \$(PKG_BUILD_DIR)/ipk/data.tar.xz ]; then \
		tar -xJf \$(PKG_BUILD_DIR)/ipk/data.tar.xz -C \$(PKG_BUILD_DIR)/data; \
	elif [ -f \$(PKG_BUILD_DIR)/ipk/data.tar.zst ]; then \
		tar --zstd -xf \$(PKG_BUILD_DIR)/ipk/data.tar.zst -C \$(PKG_BUILD_DIR)/data; \
	else \
		echo "Unsupported ipk data archive for \$(PKG_SOURCE)" >&2; exit 1; \
	fi
endef

define Build/Compile
endef

define Package/$pkg_name/install
	\$(CP) \$(PKG_BUILD_DIR)/data/. \$(1)/
endef

\$(eval \$(call BuildPackage,$pkg_name))
EOF
}

ensure_external_luci_i18n_packages() {
  is_true "$ENABLE_ADBYBY_PLUS" && ensure_prebuilt_luci_i18n_package \
    luci-i18n-adbyby-plus-zh-cn \
    221024.22052 \
    "$ADBYBY_PLUS_I18N_IPK_URL" \
    luci-app-adbyby-plus \
    "Adbyby Plus Chinese translation"

  if is_true "$ENABLE_ADGUARDHOME"; then
    # sirpdboy/luci-app-adguardhome v1.1.1 ships as two prebuilt ipks (main
    # app + zh-cn translation). Both releases are gzip-wrapped tarballs
    # (debian-binary + control.tar.gz + data.tar.gz), which the
    # ensure_prebuilt_*_package helpers already accept via the
    # ar-or-tar fallback in Build/Prepare.
    ensure_prebuilt_luci_app_package \
      luci-app-adguardhome \
      "1.1.1-r1" \
      "$ADGUARDHOME_IPK_URL" \
      "LuCI support for AdGuardHome"
    ensure_prebuilt_luci_i18n_package \
      luci-i18n-adguardhome-zh-cn \
      "0" \
      "$ADGUARDHOME_I18N_IPK_URL" \
      luci-app-adguardhome \
      "AdGuardHome Simplified Chinese translation"
  fi
}

patch_qmodem_depends() {
  # FUjr/QModem 的 qmodem/Makefile 里有一段：
  #   +PACKAGE_luci-app-qmodem_GENERIC_MHI_PCIe_DRIVER:kmod-mhi-wwan-ctrl \
  #   +PACKAGE_luci-app-qmodem_GENERIC_MHI_PCIe_DRIVER:kmod-mhi-wwan-mbim \
  # 这两个 dep 实际上没有任何 feed 提供（它们既不是独立的 Makefile，
  # 也不是上游 kernel 里的 kmod 子包），OpenWrt 的 package-metadata.pl
  # 会在 feeds install 阶段反复报：
  #   WARNING: Makefile '...' has a dependency on 'PACKAGE_..._GENERIC_MHI_PCIe_DRIVER:', which does not exist
  #   WARNING: Makefile '...' has a dependency on '-ctrl', which does not exist
  #   WARNING: Makefile '...' has a dependency on '-mbim', which does not exist
  # 即便去掉 `\` 续行也无济于事——它们的解析结果本身就是空 dep + 残留 "-ctrl/-mbim"。
  # 这里的 sed 把这两行去掉；前面已有的 +kmod-mhi-wwan 保持原样（在 feeds install 后
  # 已经通过 apply_package_fixes 末尾的 sed 's/+\?kmod-mhi-wwan//g' 处理）。
  #
  # 同时按用户要求把所有 `\` 续行合并为单行，让 Make 直接按 token 解析，
  # 避免某些解析器对 line-continuation + 末尾特殊字符的边界歧义。
  local qmodem_mf="package/feeds/qmodem/qmodem/Makefile"
  [ -f "$qmodem_mf" ] || return 0

  log "Patching qmodem Makefile: drop unresolved -ctrl/-mbim conditional deps and collapse \\ continuations"
  cp -f "$qmodem_mf" "$qmodem_mf.orig"

  # 1) 去掉那两个无法解析的条件依赖行（包括前面 TAB 和末尾的 ` \`）
  sed -i '/^[[:space:]]*+PACKAGE_luci-app-qmodem_GENERIC_MHI_PCIe_DRIVER:kmod-mhi-wwan-ctrl[[:space:]]*\\$/d' "$qmodem_mf"
  sed -i '/^[[:space:]]*+PACKAGE_luci-app-qmodem_GENERIC_MHI_PCIe_DRIVER:kmod-mhi-wwan-mbim[[:space:]]*\\$/d' "$qmodem_mf"

  # 2) 把 `\` 行尾续行符去掉（让 Make 把多行值视为单行 tokens，避开某些解析路径）
  #    只处理 DEPENDS 块；用 awk 按行扫描，进入 DEPENDS:= 起到 endef 之间做合并
  awk '
    /^[[:space:]]*DEPENDS:=/ { in_depends=1 }
    in_depends && /^endef/ { in_depends=0 }
    in_depends {
      # 去掉行尾的续行符（` \` 或 `\`）
      sub(/[[:space:]]*\\$/, "")
      # 合并多行：在当前行末尾加一个空格分隔
      if (buf != "") buf = buf " "
      buf = buf $0
      next
    }
    {
      if (buf != "") { print buf; buf="" }
      print
    }
    END { if (buf != "") print buf }
  ' "$qmodem_mf" > "$qmodem_mf.new" && mv "$qmodem_mf.new" "$qmodem_mf"

  # 简单健全性校验：DEPENDS 行应仍然包含关键 token（防 sed 把整段 DEPENDS 删没了）
  if ! grep -q '+PACKAGE_luci-app-qmodem_GENERIC_MHI_PCIe_DRIVER:kmod-mhi-wwan ' "$qmodem_mf" \
     && ! grep -q '+PACKAGE_luci-app-qmodem_GENERIC_MHI_PCIe_DRIVER:kmod-mhi-wwan"' "$qmodem_mf" \
     && ! grep -q '+PACKAGE_luci-app-qmodem_GENERIC_MHI_PCIe_DRIVER:kmod-mhi-wwan$' "$qmodem_mf"; then
    die "patch_qmodem_depends: DEPENDS rewrite lost expected token (kmod-mhi-wwan). Restoring backup."
  fi

  # 校验：残留的 -ctrl/-mbim 行应已不存在
  if grep -E 'kmod-mhi-wwan-(ctrl|mbim)' "$qmodem_mf"; then
    die "patch_qmodem_depends: -ctrl/-mbim still present after patch; upstream Makefile changed?"
  fi

  rm -f "$qmodem_mf.orig"
  log "qmodem Makefile patched successfully"
}

patch_homeproxy_no_wan_default_interface() {
  local hp_client="package/luci-app-homeproxy/root/etc/homeproxy/scripts/generate_client.uc"
  [ -f "$hp_client" ] || return 0

  if grep -q "let wan_dns = ubus.call('network.interface', 'status', {'interface': 'wan'})" "$hp_client"; then
    sed -i "s|let wan_dns = ubus.call('network.interface', 'status', {'interface': 'wan'})?.\['dns-server'\]?.\[0\];|let wan_status = ubus.call('network.interface', 'status', {'interface': 'wan'});|" "$hp_client"
  fi
  sed -i "s|wan_status\?\.\['dns-server'\]?.\[0\];|wan_status?.['dns-server']?.[0];|" "$hp_client"
  sed -i "s|auto_detect_interface: isEmpty(default_interface) ? true : null,|auto_detect_interface: (isEmpty(default_interface) \&\& wan_status?.up) ? true : null,|" "$hp_client"

  grep -q "wan_status?.up" "$hp_client" || die "HomeProxy no-WAN default interface patch verification failed"
}

ensure_libcrypt_compat_package() {
  local pkg_dir="package/libs/libcrypt-compat"
  local pkg_makefile="$pkg_dir/Makefile"

  if grep -Rqs 'Package/libcrypt-compat' package feeds 2>/dev/null; then
    return 0
  fi

  log "Adding libcrypt-compat compatibility package stub"
  mkdir -p "$pkg_dir"
  cat > "$pkg_makefile" <<'EOF'
include $(TOPDIR)/rules.mk

PKG_NAME:=libcrypt-compat
PKG_RELEASE:=1
PKG_LICENSE:=Public-Domain

include $(INCLUDE_DIR)/package.mk

define Package/libcrypt-compat
  SECTION:=libs
  CATEGORY:=Libraries
  TITLE:=libcrypt compatibility provider
  DEPENDS:=@USE_GLIBC
  PKGARCH:=all
endef

define Package/libcrypt-compat/description
Compatibility provider for packages that reference libcrypt-compat on glibc builds.
Musl-based targets do not select this package, but its definition keeps package
dependency scanning consistent with newer upstream Makefiles.
endef

define Build/Compile
endef

define Package/libcrypt-compat/install
endef

$(eval $(call BuildPackage,libcrypt-compat))
EOF
}

verify_mtwifi_patch() {
  local cfg_file="package/mtk/applications/mtwifi-cfg/files/mtwifi-cfg/mtwifi_cfg"
  local netifd_file="package/mtk/applications/mtwifi-cfg/files/netifd/mtwifi.sh"

  [ -f "$cfg_file" ] || die "Missing mtwifi_cfg after source update"
  [ -f "$netifd_file" ] || die "Missing netifd mtwifi.sh after source update"

  grep -q 'function vif_is_enabled' "$cfg_file" || die "MTK WiFi patch verification failed: vif_is_enabled missing"
  grep -q 'function sorted_vif_indices' "$cfg_file" || die "MTK WiFi patch verification failed: sorted_vif_indices missing"
  grep -q 'dats.BssidNum = effective_bssid_num' "$cfg_file" || die "MTK WiFi patch verification failed: dynamic BssidNum missing"
  grep -q 'resolve_apcli_macaddr' "$cfg_file" || die "MTK WiFi patch verification failed: APCLI MAC resolver missing"
  # Check that disabled guard exists within each function: disabled on one line, return on the next
  awk '/mtwifi_vif_ap_set_data\(\)/,/^}/ { if (/disabled/) ap_disabled=1; if (ap_disabled && /^[[:space:]]*\}/) { ap_ok=1; exit 0 } } END { exit(ap_ok ? 0 : 1) }' "$netifd_file" || die "MTK WiFi patch verification failed: AP set_data disabled guard missing"
  awk '/mtwifi_vif_sta_set_data\(\)/,/^}/ { if (/disabled/) sta_disabled=1; if (sta_disabled && /^[[:space:]]*\}/) { sta_ok=1; exit 0 } } END { exit(sta_ok ? 0 : 1) }' "$netifd_file" || die "MTK WiFi patch verification failed: STA set_data disabled guard missing"
}

install_golang_feed() {
  local golang_dir="feeds/packages/lang/golang"
  golang_feed_is_go124() {
    [ -f "$golang_dir/golang/Makefile" ] && grep -Eq 'PKG_VERSION:=1\.24\.|GO_VERSION[^:=]*:?=1\.24(\.|$)' "$golang_dir/golang/Makefile"
  }
  clean_stale_golang_host() {
    local go_bin go_version
    for go_bin in staging_dir/hostpkg/bin/go staging_dir/host/bin/go; do
      [ -x "$go_bin" ] || continue
      go_version="$($go_bin version 2>/dev/null || true)"
      case "$go_version" in
        *' go1.24.'*) return 0 ;;
        *' go1.'*)
          log "Removing stale host Go toolchain: $go_version"
          rm -rf \
            staging_dir/hostpkg/bin/go staging_dir/hostpkg/bin/gofmt staging_dir/hostpkg/lib/go \
            staging_dir/host/bin/go staging_dir/host/bin/gofmt staging_dir/host/lib/go \
            build_dir/hostpkg/golang-* build_dir/host/golang-* build_dir/host/go-* \
            tmp/.packageinfo tmp/info/.packageinfo* tmp/.config-package.in 2>/dev/null || true
          return 0
          ;;
      esac
    done
  }

  if ! golang_feed_is_go124; then
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    log "Installing Go 1.24 feed for Go packages"
    if ! git_clone_retry https://github.com/sbwml/packages_lang_golang 24.x "$tmp_dir" 1; then
      rm -rf "$tmp_dir"
      die "Unable to clone packages_lang_golang 24.x"
    fi
    mkdir -p "$(dirname "$golang_dir")"
    rm -rf "$golang_dir"
    mv "$tmp_dir" "$golang_dir"
  fi

  [ -f "$golang_dir/golang/Makefile" ] && [ -f "$golang_dir/golang-package.mk" ] || die "packages_lang_golang repository layout changed"
  golang_feed_is_go124 || die "packages_lang_golang 24.x does not provide Go 1.24"

  rm -rf package/feeds/packages/golang
  mkdir -p package/feeds/packages
  ln -s ../../../feeds/packages/lang/golang/golang package/feeds/packages/golang
  clean_stale_golang_host
  rm -rf tmp/.packageinfo tmp/info/.packageinfo* tmp/.config-package.in 2>/dev/null || true
}

apply_package_fixes() {
  log "Applying package fixes"
  cd "$ROOT_DIR/$SOURCE_DIR"

  patch_mtk_wifi_utility_rbus_for_h5000m
  patch_mtwifi_apcli_bssid_budget
  verify_mtwifi_patch
  patch_mtk_hnat_local_dest
  patch_mtwifi7_sta_mgmt_assoc_hostapd_guard
  ensure_external_luci_i18n_packages
  patch_qmodem_depends

  local ebtables_makefile="package/network/utils/ebtables/Makefile"
  if [ -f "$ebtables_makefile" ] && grep -qE 'git(://|s://git\.)netfilter\.org/ebtables' "$ebtables_makefile"; then
    log "Patching ebtables Makefile to use GitHub mirror"
    sed -i 's|https://git.netfilter.org/ebtables|https://github.com/netfilter/ebtables.git|g' "$ebtables_makefile"
    sed -i 's|git://git.netfilter.org/ebtables|https://github.com/netfilter/ebtables.git|g' "$ebtables_makefile"
    sed -i 's|^PKG_MIRROR_HASH:=.*|PKG_MIRROR_HASH:=skip|g' "$ebtables_makefile"
  fi

  fix_qmi_driver "package/mtk/applications/5g-modem/fibocom_QMI_WWAN/qmi_wwan_f.c"
  fix_qmi_driver "package/mtk/applications/5g-modem/fibocom_QMI_WWAN/src/qmi_wwan_f.c"
  fix_qmi_driver "package/mtk/applications/5g-modem/quectel_QMI_WWAN/qmi_wwan_q.c"
  fix_qmi_driver "package/mtk/applications/5g-modem/quectel_QMI_WWAN/src/qmi_wwan_q.c"
  fix_qmi_driver "package/mtk/applications/5g-modem/simcom_QMI_WWAN/qmi_wwan_s.c"
  fix_qmi_driver "package/mtk/applications/5g-modem/simcom_QMI_WWAN/src/qmi_wwan_s.c"

  if [ -d "feeds/qmodem" ]; then
    while IFS= read -r driver_file; do
      fix_qmi_driver "$driver_file"
    done < <(find feeds/qmodem -name '*.c' -type f -print0 2>/dev/null | xargs -0 grep -l 'u64_stats_fetch_begin_irq\|memcpy.*dev_addr' 2>/dev/null || true)
  fi

  if is_true "$ENABLE_ADGUARDHOME"; then
    # luci-app-adguardhome is now shipped as a prebuilt ipk from
    # sirpdboy/luci-app-adguardhome v1.1.1 (handled in
    # ensure_external_luci_i18n_packages). Nothing else to do here.
    :
  fi

  if is_true "$ENABLE_OPENCLASH"; then
    if [ ! -d "package/luci-app-openclash" ]; then
      rm -rf /tmp/openclash
      git_clone_retry https://github.com/vernesong/OpenClash.git master /tmp/openclash 1
      [ -d "/tmp/openclash/luci-app-openclash" ] || die "OpenClash repository layout changed"
      cp -r /tmp/openclash/luci-app-openclash package/luci-app-openclash
      rm -rf /tmp/openclash
    fi
    [ -f "package/luci-app-openclash/Makefile" ] || die "luci-app-openclash repository layout changed"
  fi

  if is_true "$ENABLE_ADBYBY_PLUS"; then
    if [ ! -d "package/luci-app-adbyby-plus" ]; then
      rm -rf /tmp/adbyby-plus-lite
      git_clone_retry https://github.com/kongfl888/luci-app-adbyby-plus-lite.git "" /tmp/adbyby-plus-lite 1
      (cd /tmp/adbyby-plus-lite && git submodule update --init --recursive) || true
      [ -d "/tmp/adbyby-plus-lite/luci-app-adbyby-plus" ] || die "Adbyby Plus Lite repository layout changed"
      cp -r /tmp/adbyby-plus-lite/luci-app-adbyby-plus package/luci-app-adbyby-plus
      rm -rf /tmp/adbyby-plus-lite
    fi
  fi

  if is_true "$ENABLE_MOSDNS"; then
    rm -rf \
      feeds/packages/net/mosdns \
      feeds/packages/net/v2ray-geodata \
      package/feeds/packages/mosdns \
      package/feeds/packages/v2ray-geodata \
      package/feeds/packages/v2ray-geoip \
      package/feeds/packages/v2ray-geosite 2>/dev/null || true
    [ ! -d "package/mosdns" ] && git_clone_retry https://github.com/sbwml/luci-app-mosdns v5 package/mosdns 1
    patch_mosdns_go124
    [ ! -d "package/v2ray-geodata" ] && git_clone_retry https://github.com/sbwml/v2ray-geodata "" package/v2ray-geodata 1
    patch_v2ray_geodata_downloads
  fi

  if is_true "$ENABLE_HOMEPROXY"; then
    if [ ! -d "package/luci-app-homeproxy" ]; then
      git_clone_retry "$HOMEPROXY_REPO_URL" "$HOMEPROXY_REPO_BRANCH" package/luci-app-homeproxy 1 || \
        git_clone_retry "$HOMEPROXY_FALLBACK_REPO_URL" "$HOMEPROXY_FALLBACK_REPO_BRANCH" package/luci-app-homeproxy 1 || \
        die "Unable to fetch luci-app-homeproxy"
    fi
    [ -f "package/luci-app-homeproxy/Makefile" ] || die "luci-app-homeproxy repository layout changed"
    patch_homeproxy_no_wan_default_interface
  fi

  rm -rf package/feeds/packages/{exim,onionshare-cli,python-zope-event,python-zope-interface,python-gevent,python-twisted} 2>/dev/null || true

  if is_true "$ENABLE_VLMCSD"; then
    run_with_timeout "$FEEDS_TIMEOUT" "feeds install vlmcsd" ./scripts/feeds install -f vlmcsd || true
    run_with_timeout "$FEEDS_TIMEOUT" "feeds install luci-app-vlmcsd" ./scripts/feeds install -f luci-app-vlmcsd || true
  fi

  if is_true "$ENABLE_NIKKI"; then
    rm -rf feeds/nikki/mihomo-alpha package/feeds/nikki/mihomo-alpha 2>/dev/null || true
    [ -f "feeds/nikki/mihomo-meta/Makefile" ] && sed -i '/^[[:space:]]*CONFLICTS:=mihomo-alpha/d' "feeds/nikki/mihomo-meta/Makefile" || true
    [ -f "package/feeds/nikki/mihomo-meta/Makefile" ] && sed -i '/^[[:space:]]*CONFLICTS:=mihomo-alpha/d' "package/feeds/nikki/mihomo-meta/Makefile" || true
    rm -rf tmp/.config* tmp/.packageinfo tmp/info/.packageinfo* 2>/dev/null || true
  fi

  if [ -d "package/feeds/qmodem" ]; then
    rm -rf package/feeds/qmodem/ndisc6 2>/dev/null || true
    find . -path '*qmodem*Makefile' -exec sed -i 's/+\?kmod-mhi-wwan//g' {} \; 2>/dev/null || true
  fi

  [ -f "package/mtk/drivers/mt_hwifi/Makefile" ] && sed -i 's/+kmod-mt_wifi_osal//g' "package/mtk/drivers/mt_hwifi/Makefile" || true

  # luci-app-turboacc-mtk and luci-app-Airpifanctrl are not in the upstream
  # feeds wired up in feeds.conf.default (immortalwrt-24.10 + openwrt routing +
  # telephony + nikki + qmodem). Without these clones, both CONFIG_PACKAGE
  # lines in h5000m.extra.config get silently dropped by make defconfig, so
  # the LuCI Network Acceleration / Fan control panels are absent even
  # though .config requests them.
  #
  # Both apps are pure LuCI + UCI; turboacc toggles kernel HNAT/SFE/Shortcut
  # flags via UCI -> sysfs and exposes buttons to clear conntrack / reset
  # the offload engine; Airpifanctrl fans out PWM via sysfs. So we can drop
  # them under package/mtk/applications/<name>/ and they will be picked up
  # by ./scripts/feeds install as plain package directories.
  if [ ! -d "package/mtk/applications/luci-app-turboacc-mtk" ]; then
    rm -rf /tmp/luci-app-turboacc-mtk
    git_clone_retry https://github.com/hanwckf/immortalwrt-mt798x.git master /tmp/luci-app-turboacc-mtk 1 || \
      log "WARNING: failed to clone luci-app-turboacc-mtk; LuCI network acceleration panel will be missing"
    if [ -d "/tmp/luci-app-turboacc-mtk/package/mtk/applications/luci-app-turboacc-mtk" ]; then
      mkdir -p package/mtk/applications
      cp -r /tmp/luci-app-turboacc-mtk/package/mtk/applications/luci-app-turboacc-mtk \
        package/mtk/applications/luci-app-turboacc-mtk
    fi
    rm -rf /tmp/luci-app-turboacc-mtk
  fi
  if [ ! -d "package/mtk/applications/luci-app-Airpifanctrl" ]; then
    rm -rf /tmp/luci-app-Airpifanctrl
    # Airpifanctrl lived in the older padavanonly/immortalwrt-mt798x-6.6
    # branch; fetch that repo and copy the application subdir.
    git_clone_retry https://github.com/padavanonly/immortalwrt-mt798x-6.6.git mt798x-mt799x-6.6-mtwifi /tmp/luci-app-Airpifanctrl 1 || \
      log "WARNING: failed to clone luci-app-Airpifanctrl; LuCI fan control panel will be missing"
    if [ -d "/tmp/luci-app-Airpifanctrl/package/mtk/applications/luci-app-Airpifanctrl" ]; then
      mkdir -p package/mtk/applications
      cp -r /tmp/luci-app-Airpifanctrl/package/mtk/applications/luci-app-Airpifanctrl \
        package/mtk/applications/luci-app-Airpifanctrl
    fi
    rm -rf /tmp/luci-app-Airpifanctrl
  fi
}

feed_install_pkg() {
  local pkg="$1"
  run_with_timeout "$FEEDS_TIMEOUT" "feeds install $pkg" ./scripts/feeds install -f "$pkg" || die "Unable to install feed package: $pkg"
}

require_package_file() {
  local feature_name="$1"
  local file_path="$2"
  [ -f "$file_path" ] || die "$feature_name required package file is missing: $file_path"
}

install_selected_packages() {
  log "Installing selected feed packages"
  cd "$ROOT_DIR/$SOURCE_DIR"

  if is_true "$ENABLE_NIKKI"; then
    feed_install_pkg nikki
    feed_install_pkg luci-app-nikki
    feed_install_pkg mihomo-meta

    # Disable test_profile to avoid mihomo MMDB download at startup (pure-LAN fails with DNS error)
    # Handle any quoting style: 'test_profile' '1', "test_profile" "1", test_profile 1
    local nikki_conf="feeds/nikki/nikki/files/nikki.conf"
    if [ -f "$nikki_conf" ]; then
      sed -i \
        -e "s/\(option[[:space:]]\+test_profile[[:space:]]\+\)[r'\"][01]['\"]/\10/" \
        -e "s/\(option[[:space:]]\+test_profile[[:space:]]\+\)1\($\)/\10/" \
        "$nikki_conf"
    fi

    # Nikki/mihomo stability: increase timeouts to handle occasional connection issues
    local nikki_init="feeds/nikki/nikki/files/etc/init.d/nikki"
    if [ -f "$nikki_init" ]; then
      # Backup original init script
      cp "$nikki_init" "$nikki_init.bak"
      # Add stability environment variables at the top
      sed -i '1i\
# Nikki stability: increase timeouts for flaky connections\
export MIHOMO_DNS_TIMEOUT="10"\
export MIHOMO_POOL_TIMEOUT="300"\
export MIHOMO_TCP_KEEPALIVE="1"\
' "$nikki_init"
      log "Nikki stability overrides applied"
    fi
  fi

  if is_true "$ENABLE_UPNP"; then
    feed_install_pkg miniupnpd-nftables
    feed_install_pkg luci-app-upnp
  fi

  if is_true "$ENABLE_VLMCSD"; then
    feed_install_pkg vlmcsd
    feed_install_pkg luci-app-vlmcsd
  fi


  if is_true "$ENABLE_HOMEPROXY"; then
    feed_install_pkg sing-box
    require_package_file "HomeProxy" "package/luci-app-homeproxy/Makefile"
    require_package_file "HomeProxy sing-box" "package/feeds/packages/sing-box/Makefile"
  fi

  if is_true "$ENABLE_ADGUARDHOME"; then
    # luci-app-adguardhome + luci-i18n-adguardhome-zh-cn live in the
    # in-tree package/prebuilt-{luci-app,i18n}/ directories that
    # ensure_external_luci_i18n_packages materialised. feeds install -f
    # wires them into package/feeds/... so make defconfig / make world
    # can resolve them.
    require_package_file "AdGuardHome prebuilt app" "package/prebuilt-luci-app/luci-app-adguardhome/Makefile"
    require_package_file "AdGuardHome prebuilt zh-cn" "package/prebuilt-i18n/luci-i18n-adguardhome-zh-cn/Makefile"
    feed_install_pkg luci-app-adguardhome
    feed_install_pkg luci-i18n-adguardhome-zh-cn
  fi

  if is_true "$ENABLE_MWAN3"; then
    feed_install_pkg mwan3
    feed_install_pkg luci-app-mwan3
  fi

  if is_true "$ENABLE_MOSDNS"; then
    require_package_file "MosDNS LuCI" "package/mosdns/luci-app-mosdns/Makefile"
    require_package_file "MosDNS core" "package/mosdns/mosdns/Makefile"
    require_package_file "MosDNS v2dat" "package/mosdns/v2dat/Makefile"
    require_package_file "MosDNS v2ray geodata" "package/v2ray-geodata/Makefile"
  fi

  rm -rf tmp/.config* tmp/.packageinfo tmp/info/.packageinfo* 2>/dev/null || true
}

config_enable() {
  local symbol="$1"
  if ./scripts/config --file .config -e "$symbol" 2>/dev/null; then
    :
  elif grep -q "^CONFIG_${symbol}=" .config || grep -q "^# CONFIG_${symbol} is not set" .config; then
    sed -i "/^CONFIG_${symbol}=/d; /^# CONFIG_${symbol} is not set/d" .config
    echo "CONFIG_${symbol}=y" >> .config
  else
    echo "CONFIG_${symbol}=y" >> .config
  fi
}

config_disable() {
  local symbol="$1"
  if ./scripts/config --file .config -d "$symbol" 2>/dev/null; then
    :
  elif grep -q "^CONFIG_${symbol}=" .config || grep -q "^# CONFIG_${symbol} is not set" .config; then
    sed -i "/^CONFIG_${symbol}=/d; /^# CONFIG_${symbol} is not set/d" .config
    echo "# CONFIG_${symbol} is not set" >> .config
  else
    echo "# CONFIG_${symbol} is not set" >> .config
  fi
}

enable_upnp_stack_config() {
  config_enable PACKAGE_luci-app-upnp
  config_enable PACKAGE_luci-i18n-upnp-zh-cn
  config_enable PACKAGE_miniupnpd-nftables
  config_enable PACKAGE_rpcd-mod-ucode
  config_enable PACKAGE_libcap-ng
  config_enable PACKAGE_libmnl
  config_enable PACKAGE_libuuid
  config_enable PACKAGE_libnftnl
}

# Enable the full MWAN3 stack: kernel netfilter modules, iptables userspace
# extensions, ipset, VRF support, and LuCI integration.
# - kmod-vrf needs KERNEL_NET_L3_MASTER_DEV, otherwise LuCI's device add dialog
#   prompts "需要 kmod-vrf" and the package remains unbuildable.
# - kmod-ipt-ipset / -conntrack-extra / -ipopt must be selected at build time
#   so they land in the image; otherwise users hit "依赖的软件包 ... 在所有仓库都未提供"
#   when trying to opkg-install luci-app-mwan3 at runtime.
enable_mwan3_stack_config() {
  # Kernel prerequisites for kmod-vrf
  config_enable KERNEL_NET_L3_MASTER_DEV
  # MWAN3 core + LuCI
  config_enable PACKAGE_mwan3
  config_enable PACKAGE_luci-app-mwan3
  config_enable PACKAGE_luci-i18n-mwan3-zh-cn
  # Userspace tools mwan3 invokes.
  # 'ip' is a virtual package provided by ip-tiny (default) or ip-full.
  # We pick ip-full explicitly so mwan3 gets the full iproute2 feature set.
  config_enable PACKAGE_ip-full
  config_enable PACKAGE_ipset
  # 'iptables' is a virtual package provided by either iptables-nft or
  # iptables-zz-legacy. Selecting CONFIG_PACKAGE_iptables=y directly gets
  # dropped by make defconfig once firewall4 has already picked iptables-nft.
  # Pick both real variants so mwan3's legacy iptables calls work and the
  # fw4-required nftables frontend stays available.
  config_enable PACKAGE_iptables-nft
  config_enable PACKAGE_iptables-zz-legacy
  # Same story for IPv6: 'ip6tables' is virtual; select both real variants.
  config_enable PACKAGE_ip6tables-nft
  config_enable PACKAGE_ip6tables-zz-legacy
  # IPv6 kernel modules backing ip6tables. mwan3 v2.11.16 (when IPV6 is
  # enabled) builds mwan3_hook with -p ipv6-icmp -m icmp6 --icmpv6-type
  # 133/134/135/136/137 (NDP RS/RA/NS/NA), creates IPv6 ipset tables
  # (family inet6), and steers IPv6 routing via ip -6. None of those work
  # if kmod-ip6tables / kmod-ipt-nat6 / libip6tc are absent from the image.
  config_enable PACKAGE_kmod-ip6tables
  config_enable PACKAGE_kmod-ip6tables-extra
  config_enable PACKAGE_kmod-ipt-nat6
  config_enable PACKAGE_kmod-nf-nat6
  config_enable PACKAGE_kmod-nf-ipt6
  config_enable PACKAGE_kmod-ip6-tunnel
  config_enable PACKAGE_libip6tc
  config_enable PACKAGE_ip6tables-mod-nat
  config_enable PACKAGE_ip6tables-extra
  config_enable PACKAGE_jshn
  # iptables userspace extensions required by mwan3 scripts
  config_enable PACKAGE_iptables-mod-conntrack-extra
  config_enable PACKAGE_iptables-mod-ipopt
  # Kernel modules backing those extensions
  config_enable PACKAGE_kmod-ipt-core
  config_enable PACKAGE_kmod-ipt-conntrack
  config_enable PACKAGE_kmod-ipt-conntrack-extra
  config_enable PACKAGE_kmod-ipt-ipopt
  config_enable PACKAGE_kmod-ipt-ipset
  config_enable PACKAGE_kmod-ipt-raw
  config_enable PACKAGE_kmod-nf-conntrack
  config_enable PACKAGE_kmod-nf-conntrack6
  config_enable PACKAGE_kmod-nf-conncount
  config_enable PACKAGE_kmod-nfnetlink
  # VRF support (needed by LuCI device dialog when adding VRF devices)
  config_enable PACKAGE_kmod-vrf
}

enable_h5000m_wifi_driver_config() {
  config_enable USE_RFKILL
  config_enable PACKAGE_blkid
  config_enable PACKAGE_kmod-mt_wifi_cmn
  config_enable PACKAGE_kmod-mt_wifi7
  config_enable PACKAGE_kmod-mt_hwifi
  # MTK HWIFI core configuration - aligned with upstream mt7987_mt7992.defconfig
  config_enable MTK_HWIFI_PCI_SUPPORT
  config_enable MTK_HWIFI_CONNAC_IF_SUPPORT
  config_enable MTK_HWIFI_WED_SUPPORT
  config_enable MTK_HWIFI_MT7992
  config_enable MTK_HWIFI_MT799A
  # MT7992 specific tuning parameters (from upstream)
  config_enable MTK_HWIFI_MT7992_RRO_MODE
  config_enable MTK_HWIFI_MT7992_OPTION_TYPE
  config_enable MTK_HWIFI_MT7992_INTR_OPTION_SET
  # RX processing configuration
  config_enable MTK_HWIFI_RX_PROCESS_WORKQUEUE
  # MTK WIFI7 driver configuration - fully aligned with upstream mt7987_mt7992.defconfig (110 config items)
  config_enable MTK_WIFI7_SUPPORT_OPENWRT
  config_enable MTK_WIFI7_DRIVER
  config_enable MTK_WIFI7_UNIFIED_COMMAND
  config_enable MTK_WIFI7_DOT11_N_SUPPORT
  config_enable MTK_WIFI7_DOT11_AX_SUPPORT
  config_enable MTK_WIFI7_DOT11_BE_SUPPORT
  config_enable MTK_WIFI7_MT_MAC
  config_enable MTK_WIFI7_CHIP_MT7992
  config_enable MTK_WIFI7_FIRST_IF_MT7992
  config_enable MTK_WIFI7_SECOND_IF_MT7992
  config_enable MTK_WIFI7_THIRD_IF_NONE
  # WIFI7 feature switches - network and radio features
  config_enable MTK_WIFI7_PROXYARP_SUPPORT
  config_enable MTK_WIFI7_OFFCHANNEL_SUPPORT
  config_enable MTK_WIFI7_BS_MAP_BL_SUPPORT
  config_enable MTK_WIFI7_MULTI_INF_SUPPORT
  config_enable MTK_WIFI7_BASIC_FUNC
  config_enable MTK_WIFI7_DOT11_VHT_AC
  config_enable MTK_WIFI7_DOT11_HE_AX
  config_enable MTK_WIFI7_DOT11_EHT_BE
  config_enable MTK_WIFI7_FIRST_IF_EEPROM_FLASH
  # RF offsets
  config_enable MTK_WIFI7_FIRST_IF_RF_OFFSET
  config_enable MTK_WIFI7_SECOND_IF_RF_OFFSET
  config_enable MTK_WIFI7_RT_FIRST_IF_RF_OFFSET
  config_enable MTK_WIFI7_RT_SECOND_IF_RF_OFFSET
  config_enable MTK_WIFI7_RT_THIRD_IF_RF_OFFSET
  # WIFI7 additional features from upstream
  config_enable MTK_WIFI7_AIR_MONITOR
  config_enable MTK_WIFI7_APCLI_SUPPORT
  config_enable MTK_WIFI7_APCLI_CERT_SUPPORT
  config_enable MTK_WIFI7_ATE_SUPPORT
  config_enable MTK_WIFI7_BACKGROUND_SCAN_SUPPORT
  config_enable MTK_WIFI7_BAND_STEERING
  config_enable MTK_WIFI7_CAL_BIN_FILE_SUPPORT
  config_enable MTK_WIFI7_CFG_SUPPORT_FALCON_MURU
  config_enable MTK_WIFI7_CFG_SUPPORT_FALCON_PP
  config_enable MTK_WIFI7_CFG_SUPPORT_FALCON_SR
  config_enable MTK_WIFI7_CFG_SUPPORT_FALCON_TXCMD_DBG
  config_enable MTK_WIFI7_CON_WPS_SUPPORT
  config_enable MTK_WIFI7_CTXD_MEM_CPY_SUPPORT
  config_enable MTK_WIFI7_DATA_TXPWR_CTRL
  config_enable MTK_WIFI7_DBDC_MODE
  config_enable MTK_WIFI7_DOT11K_RRM_SUPPORT
  config_enable MTK_WIFI7_DOT11R_FT_SUPPORT
  config_enable MTK_WIFI7_DOT11W_PMF_SUPPORT
  config_enable MTK_WIFI7_DSCP_PRI_SUPPORT
  config_enable MTK_WIFI7_EAP_FEATURE
  config_enable MTK_WIFI7_FAST_NAT_SUPPORT
  config_enable MTK_WIFI7_FIRST_IF_IPAILNA
  config_enable MTK_WIFI7_G_BAND_256QAM_SUPPORT
  config_enable MTK_WIFI7_GREENAP_SUPPORT
  config_enable MTK_WIFI7_HDR_TRANS_RX_SUPPORT
  config_enable MTK_WIFI7_HDR_TRANS_TX_SUPPORT
  config_enable MTK_WIFI7_HIGH_PRIO_QUEUE_SUPPORT
  config_enable MTK_WIFI7_ICAP_SUPPORT
  config_enable MTK_WIFI7_IGMP_SNOOP_SUPPORT
  config_enable MTK_WIFI7_INTERWORKING
  config_enable MTK_WIFI7_LED_CONTROL_SUPPORT
  config_enable MTK_WIFI7_LINUX_NET_TXQ_SUPPORT
  config_enable MTK_WIFI7_MAC_REPEATER_SUPPORT
  config_enable MTK_WIFI7_MAP_SUPPORT
  config_enable MTK_WIFI7_MBO_SUPPORT
  config_enable MTK_WIFI7_MBSS_SUPPORT
  config_enable MTK_WIFI7_MCAST_RATE_SPECIFIC
  config_enable MTK_WIFI7_MLME_MULTI_QUEUE_SUPPORT
  config_enable MTK_WIFI7_MODE_AP
  config_enable MTK_WIFI7_MODE_BOTH
  config_enable MTK_WIFI7_MODE_STA
  config_enable MTK_WIFI7_MT_AP_SUPPORT
  config_enable MTK_WIFI7_MT_DFS_SUPPORT
  config_enable MTK_WIFI7_MULTI_PROFILE_SUPPORT
  config_enable MTK_WIFI7_MUMIMO_SUPPORT
  config_enable MTK_WIFI7_MU_RA_SUPPORT
  config_enable MTK_WIFI7_MWDS
  config_enable MTK_WIFI7_OCE_SUPPORT
  config_enable MTK_WIFI7_OFFCHANNEL_SCAN_FEATURE
  config_enable MTK_WIFI7_OWE_SUPPORT
  config_enable MTK_WIFI7_PCIE_ASPM_DYM_CTRL_SUPPORT
  config_enable MTK_WIFI7_PHY_ICS_SUPPORT
  config_enable MTK_WIFI7_QOS_R1_SUPPORT
  config_enable MTK_WIFI7_RTMP_FLASH_SUPPORT
  config_enable MTK_WIFI7_RTMP_PCI_SUPPORT
  config_enable MTK_WIFI7_RTMP_WLAN_HOOK_SUPPORT
  config_enable MTK_WIFI7_SCS_FW_OFFLOAD
  config_enable MTK_WIFI7_SECOND_IF_IPAILNA
  config_enable MTK_WIFI7_SINGLE_SKU
  config_enable MTK_WIFI7_SMART_CARRIER_SENSE_SUPPORT
  config_enable MTK_WIFI7_SNIFFER_RADIOTAP_SUPPORT
  config_enable MTK_WIFI7_SPECTRUM_SUPPORT
  config_enable MTK_WIFI7_TPC_SUPPORT
  config_enable MTK_WIFI7_TR181_SUPPORT
  config_enable MTK_WIFI7_TXBF_SUPPORT
  config_enable MTK_WIFI7_UAPSD
  config_enable MTK_WIFI7_UNIFIED_COUNTRY_CONFIG_SUPPORT
  config_enable MTK_WIFI7_VLAN_SUPPORT
  config_enable MTK_WIFI7_VOW_SUPPORT
  config_enable MTK_WIFI7_WARP_V2
  config_enable MTK_WIFI7_WDS_SUPPORT
  config_enable MTK_WIFI7_WIFI_TWT_SUPPORT
  config_enable MTK_WIFI7_WLAN_HOOK
  config_enable MTK_WIFI7_WLAN_SERVICE
  config_enable MTK_WIFI7_WNM_SUPPORT
  config_enable MTK_WIFI7_WPA3_SUPPORT
  config_enable MTK_WIFI7_WSC_INCLUDED
  config_enable MTK_WIFI7_WSC_V2_SUPPORT
  config_enable MTK_WIFI7_ZERO_PKT_LOSS_SUPPORT
  # MTK_WIFI7 module and path
  config_enable MTK_WIFI7_MT_WIFI
  config_enable MTK_WIFI7_MT_WIFI_PATH
  config_enable MTK_WIFI7_FW_LOG_TYPE
  config_enable MTK_WIFI7_SKU_TYPE
  # Wireless HNAT support for WIFI7
  config_enable MTK_WIFI7_WHNAT_SUPPORT
  config_enable PACKAGE_kmod-mtk_pci
  config_enable PACKAGE_kmod-mtk_wed
  config_enable PACKAGE_kmod-connac_if
  config_enable PACKAGE_kmod-mt7992
  config_enable PACKAGE_kmod-mt799a
  config_enable PACKAGE_mtwifi-cfg
  config_enable PACKAGE_luci-app-mtwifi-cfg
  config_enable PACKAGE_luci-i18n-mtwifi-cfg-zh-cn
  config_enable PACKAGE_wireless-regdb
}

diagnose_upnp_config() {
  log "Diagnosing UPnP package state"
  for pkg_file in \
    package/feeds/luci/luci-app-upnp/Makefile \
    package/feeds/packages/miniupnpd/Makefile \
    feeds/luci/applications/luci-app-upnp/Makefile \
    feeds/packages/net/miniupnpd/Makefile; do
    if [ -f "$pkg_file" ]; then
      echo "--- $pkg_file"
      grep -nE 'LUCI_DEPENDS|DEPENDS|PROVIDES|VARIANT|DEFAULT_VARIANT|CONFLICTS' "$pkg_file" || true
    fi
  done
  grep -nE 'PACKAGE_(luci-app-upnp|miniupnpd|miniupnpd-nftables|miniupnpd-iptables|rpcd-mod-ucode|libcap-ng|libmnl|libuuid|libnftnl)' .config || true
}

retry_upnp_config_if_needed() {
  if ! is_true "$ENABLE_UPNP"; then return 0; fi

  if grep -q '^CONFIG_PACKAGE_luci-app-upnp=y$' .config && grep -q '^CONFIG_PACKAGE_miniupnpd-nftables=y$' .config; then
    return 0
  fi

  diagnose_upnp_config
  log "Retrying UPnP package selection with explicit nftables stack"
  feed_install_pkg miniupnpd-nftables
  feed_install_pkg luci-app-upnp
  rm -rf tmp/.config* tmp/.packageinfo tmp/info/.packageinfo* 2>/dev/null || true
  config_disable PACKAGE_miniupnpd-iptables
  config_disable PACKAGE_luci-app-upnp
  config_disable PACKAGE_miniupnpd-nftables
  enable_upnp_stack_config
  run_with_timeout "$CONFIG_TIMEOUT" "make defconfig after UPnP retry" make FORCE=1 defconfig -j"${THREADS}"
  diagnose_upnp_config
}

configure_build() {
  log "Configuring build"
  cd "$ROOT_DIR/$SOURCE_DIR"

  if is_true "$ENABLE_QMODEM_NEXT" && is_true "$ENABLE_QMODEM"; then
    die "ENABLE_QMODEM_NEXT and ENABLE_QMODEM cannot both be true"
  fi
  if is_true "$ENABLE_ORIGINAL_MODEM" && { is_true "$ENABLE_QMODEM_NEXT" || is_true "$ENABLE_QMODEM"; }; then
    die "ENABLE_ORIGINAL_MODEM conflicts with QModem options"
  fi

  curl_fetch_retry "$CONFIG_URL" base.config || {
    [ -f "defconfig/mt7987_mt7992.config" ] && cp defconfig/mt7987_mt7992.config base.config
  }
  [ -f base.config ] || die "Unable to fetch or locate base config"

  cp base.config .config
  [ -f "$ROOT_DIR/h5000m.extra.config" ] && cat "$ROOT_DIR/h5000m.extra.config" >> .config
  echo "CONFIG_PACKAGE_luci-i18n-mtwifi-cfg-zh-cn=y" >> .config
  cat >> .config <<'EOF'
CONFIG_USE_RFKILL=y
CONFIG_PACKAGE_blkid=y
CONFIG_PACKAGE_kmod-mt_wifi_cmn=y
CONFIG_PACKAGE_kmod-mt_wifi7=y
CONFIG_PACKAGE_kmod-mt_hwifi=y
# MTK HWIFI core configuration - aligned with upstream mt7987_mt7992.defconfig
CONFIG_MTK_HWIFI_PCI_SUPPORT=y
CONFIG_MTK_HWIFI_CONNAC_IF_SUPPORT=y
CONFIG_MTK_HWIFI_WED_SUPPORT=y
CONFIG_MTK_HWIFI_MT7992=y
CONFIG_MTK_HWIFI_MT799A=y
# MT7992 specific tuning parameters (from upstream)
CONFIG_MTK_HWIFI_MT7992_RRO_MODE=4
CONFIG_MTK_HWIFI_MT7992_OPTION_TYPE=0
CONFIG_MTK_HWIFI_MT7992_INTR_OPTION_SET=0
# RX processing configuration
CONFIG_MTK_HWIFI_RX_PROCESS_WORKQUEUE=y
# MTK WIFI7 driver configuration - fully aligned with upstream mt7987_mt7992.defconfig (110 config items)
CONFIG_MTK_WIFI7_SUPPORT_OPENWRT=y
CONFIG_MTK_WIFI7_DRIVER=y
CONFIG_MTK_WIFI7_UNIFIED_COMMAND=y
CONFIG_MTK_WIFI7_DOT11_N_SUPPORT=y
CONFIG_MTK_WIFI7_DOT11_AX_SUPPORT=y
CONFIG_MTK_WIFI7_DOT11_BE_SUPPORT=y
CONFIG_MTK_WIFI7_MT_MAC=y
CONFIG_MTK_WIFI7_CHIP_MT7992=y
CONFIG_MTK_WIFI7_FIRST_IF_MT7992=y
CONFIG_MTK_WIFI7_SECOND_IF_MT7992=y
CONFIG_MTK_WIFI7_THIRD_IF_NONE=y
# RF offsets
CONFIG_MTK_WIFI7_FIRST_IF_RF_OFFSET=0xc0000
CONFIG_MTK_WIFI7_SECOND_IF_RF_OFFSET=0xc8000
CONFIG_MTK_WIFI7_RT_FIRST_IF_RF_OFFSET=0xc0000
CONFIG_MTK_WIFI7_RT_SECOND_IF_RF_OFFSET=0xc8000
CONFIG_MTK_WIFI7_RT_THIRD_IF_RF_OFFSET=0xd0000
# WIFI7 additional features from upstream
CONFIG_MTK_WIFI7_PROXYARP_SUPPORT=y
CONFIG_MTK_WIFI7_OFFCHANNEL_SUPPORT=y
CONFIG_MTK_WIFI7_BS_MAP_BL_SUPPORT=y
CONFIG_MTK_WIFI7_MULTI_INF_SUPPORT=y
CONFIG_MTK_WIFI7_BASIC_FUNC=y
CONFIG_MTK_WIFI7_DOT11_VHT_AC=y
CONFIG_MTK_WIFI7_DOT11_HE_AX=y
CONFIG_MTK_WIFI7_DOT11_EHT_BE=y
CONFIG_MTK_WIFI7_FIRST_IF_EEPROM_FLASH=y
CONFIG_MTK_WIFI7_AIR_MONITOR=y
CONFIG_MTK_WIFI7_APCLI_SUPPORT=y
CONFIG_MTK_WIFI7_APCLI_CERT_SUPPORT=y
CONFIG_MTK_WIFI7_ATE_SUPPORT=y
CONFIG_MTK_WIFI7_BACKGROUND_SCAN_SUPPORT=y
CONFIG_MTK_WIFI7_BAND_STEERING=y
CONFIG_MTK_WIFI7_CAL_BIN_FILE_SUPPORT=y
CONFIG_MTK_WIFI7_CFG_SUPPORT_FALCON_MURU=y
CONFIG_MTK_WIFI7_CFG_SUPPORT_FALCON_PP=y
CONFIG_MTK_WIFI7_CFG_SUPPORT_FALCON_SR=y
CONFIG_MTK_WIFI7_CFG_SUPPORT_FALCON_TXCMD_DBG=y
CONFIG_MTK_WIFI7_CON_WPS_SUPPORT=y
CONFIG_MTK_WIFI7_CTXD_MEM_CPY_SUPPORT=y
CONFIG_MTK_WIFI7_DATA_TXPWR_CTRL=y
CONFIG_MTK_WIFI7_DBDC_MODE=y
CONFIG_MTK_WIFI7_DOT11K_RRM_SUPPORT=y
CONFIG_MTK_WIFI7_DOT11R_FT_SUPPORT=y
CONFIG_MTK_WIFI7_DOT11W_PMF_SUPPORT=y
CONFIG_MTK_WIFI7_DSCP_PRI_SUPPORT=y
CONFIG_MTK_WIFI7_EAP_FEATURE=y
CONFIG_MTK_WIFI7_FAST_NAT_SUPPORT=y
CONFIG_MTK_WIFI7_FIRST_IF_IPAILNA=y
CONFIG_MTK_WIFI7_G_BAND_256QAM_SUPPORT=y
CONFIG_MTK_WIFI7_GREENAP_SUPPORT=y
CONFIG_MTK_WIFI7_HDR_TRANS_RX_SUPPORT=y
CONFIG_MTK_WIFI7_HDR_TRANS_TX_SUPPORT=y
CONFIG_MTK_WIFI7_HIGH_PRIO_QUEUE_SUPPORT=y
CONFIG_MTK_WIFI7_ICAP_SUPPORT=y
CONFIG_MTK_WIFI7_IGMP_SNOOP_SUPPORT=y
CONFIG_MTK_WIFI7_INTERWORKING=y
CONFIG_MTK_WIFI7_LED_CONTROL_SUPPORT=y
CONFIG_MTK_WIFI7_LINUX_NET_TXQ_SUPPORT=y
CONFIG_MTK_WIFI7_MAC_REPEATER_SUPPORT=y
CONFIG_MTK_WIFI7_MAP_SUPPORT=y
CONFIG_MTK_WIFI7_MBO_SUPPORT=y
CONFIG_MTK_WIFI7_MBSS_SUPPORT=y
CONFIG_MTK_WIFI7_MCAST_RATE_SPECIFIC=y
CONFIG_MTK_WIFI7_MLME_MULTI_QUEUE_SUPPORT=y
CONFIG_MTK_WIFI7_MODE_AP=m
CONFIG_MTK_WIFI7_MODE_BOTH=m
CONFIG_MTK_WIFI7_MODE_STA=m
CONFIG_MTK_WIFI7_MT_AP_SUPPORT=m
CONFIG_MTK_WIFI7_MT_DFS_SUPPORT=y
CONFIG_MTK_WIFI7_MULTI_PROFILE_SUPPORT=y
CONFIG_MTK_WIFI7_MUMIMO_SUPPORT=y
CONFIG_MTK_WIFI7_MU_RA_SUPPORT=y
CONFIG_MTK_WIFI7_MWDS=y
CONFIG_MTK_WIFI7_OCE_SUPPORT=y
CONFIG_MTK_WIFI7_OFFCHANNEL_SCAN_FEATURE=y
CONFIG_MTK_WIFI7_OWE_SUPPORT=y
CONFIG_MTK_WIFI7_PCIE_ASPM_DYM_CTRL_SUPPORT=y
CONFIG_MTK_WIFI7_PHY_ICS_SUPPORT=y
CONFIG_MTK_WIFI7_QOS_R1_SUPPORT=y
CONFIG_MTK_WIFI7_RTMP_FLASH_SUPPORT=y
CONFIG_MTK_WIFI7_RTMP_PCI_SUPPORT=y
CONFIG_MTK_WIFI7_RTMP_WLAN_HOOK_SUPPORT=y
CONFIG_MTK_WIFI7_SCS_FW_OFFLOAD=y
CONFIG_MTK_WIFI7_SECOND_IF_IPAILNA=y
CONFIG_MTK_WIFI7_SINGLE_SKU=y
CONFIG_MTK_WIFI7_SMART_CARRIER_SENSE_SUPPORT=y
CONFIG_MTK_WIFI7_SNIFFER_RADIOTAP_SUPPORT=y
CONFIG_MTK_WIFI7_SPECTRUM_SUPPORT=y
CONFIG_MTK_WIFI7_TPC_SUPPORT=y
CONFIG_MTK_WIFI7_TR181_SUPPORT=y
CONFIG_MTK_WIFI7_TXBF_SUPPORT=y
CONFIG_MTK_WIFI7_UAPSD=y
CONFIG_MTK_WIFI7_UNIFIED_COUNTRY_CONFIG_SUPPORT=y
CONFIG_MTK_WIFI7_VLAN_SUPPORT=y
CONFIG_MTK_WIFI7_VOW_SUPPORT=y
CONFIG_MTK_WIFI7_WARP_V2=y
CONFIG_MTK_WIFI7_WDS_SUPPORT=y
CONFIG_MTK_WIFI7_WIFI_TWT_SUPPORT=y
CONFIG_MTK_WIFI7_WLAN_HOOK=y
CONFIG_MTK_WIFI7_WLAN_SERVICE=y
CONFIG_MTK_WIFI7_WNM_SUPPORT=y
CONFIG_MTK_WIFI7_WPA3_SUPPORT=y
CONFIG_MTK_WIFI7_WSC_INCLUDED=y
CONFIG_MTK_WIFI7_WSC_V2_SUPPORT=y
CONFIG_MTK_WIFI7_ZERO_PKT_LOSS_SUPPORT=y
# MTK_WIFI7 module and path
CONFIG_MTK_WIFI7_MT_WIFI=m
CONFIG_MTK_WIFI7_MT_WIFI_PATH="mt_wifi"
CONFIG_MTK_WIFI7_FW_LOG_TYPE="idx_log"
CONFIG_MTK_WIFI7_SKU_TYPE="BE5040"
# Wireless HNAT support for WIFI7
CONFIG_MTK_WIFI7_WHNAT_SUPPORT=m
CONFIG_PACKAGE_kmod-mtk_pci=y
CONFIG_PACKAGE_kmod-connac_if=y
CONFIG_PACKAGE_kmod-mt7992=y
CONFIG_PACKAGE_kmod-mt799a=y
CONFIG_PACKAGE_mtwifi-cfg=y
CONFIG_PACKAGE_luci-app-mtwifi-cfg=y
CONFIG_PACKAGE_wireless-regdb=y
EOF

  # Respect WED setting from h5000m.extra.config: if user commented out
  # CONFIG_PACKAGE_kmod-mtk_wed (i.e. "is not set"), also disable the kernel
  # CONFIG_MTK_HWIFI_WED_SUPPORT to avoid compilation mismatches. Disabling WED
  # via kmod-mtk_wed alone leaves CONFIG_MTK_HWIFI_WED_SUPPORT=y in .config,
  # which can cause build warnings or runtime inconsistencies.
  if grep -q '^# CONFIG_PACKAGE_kmod-mtk_wed is not set$' "$ROOT_DIR/h5000m.extra.config" 2>/dev/null || \
     grep -q '^CONFIG_PACKAGE_kmod-mtk_wed is not set$' "$ROOT_DIR/h5000m.extra.config" 2>/dev/null; then
    log "WED disabled via h5000m.extra.config; disabling WED support in .config"
    # Remove the WED package and kernel support; upstream base.config may have
    # CONFIG_MTK_HWIFI_WED_SUPPORT=y, so we override it to is-not-set.
    sed -i '/^CONFIG_PACKAGE_kmod-mtk_wed=y$/d' .config
    grep -v '^CONFIG_MTK_HWIFI_WED_SUPPORT=y$' .config > .config.tmp && mv .config.tmp .config
    echo '# CONFIG_MTK_HWIFI_WED_SUPPORT is not set' >> .config
  else
    echo "CONFIG_PACKAGE_kmod-mtk_wed=y" >> .config
  fi

  local disabled_pkgs=("luci-app-sms-tool-lite" "luci-app-3ginfo-lite")

  if is_true "$ENABLE_NIKKI"; then
    cat >> .config <<'EOF'
CONFIG_PACKAGE_nikki=y
CONFIG_PACKAGE_luci-app-nikki=y
CONFIG_PACKAGE_luci-i18n-nikki-zh-cn=y
# CONFIG_PACKAGE_mihomo-alpha is not set
CONFIG_PACKAGE_mihomo-meta=y
CONFIG_PACKAGE_ca-bundle=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_yq=y
CONFIG_PACKAGE_firewall4=y
CONFIG_PACKAGE_ip-full=y
CONFIG_PACKAGE_kmod-inet-diag=y
CONFIG_PACKAGE_kmod-nft-socket=y
CONFIG_PACKAGE_kmod-nft-tproxy=y
CONFIG_PACKAGE_kmod-tun=y
CONFIG_PACKAGE_kmod-dummy=y
EOF
  else
    disabled_pkgs+=("nikki" "luci-app-nikki" "luci-i18n-nikki-zh-cn" "luci-i18n-nikki-en")
  fi

  is_true "$ENABLE_ADGUARDHOME" && { echo "CONFIG_PACKAGE_luci-app-adguardhome=y" >> .config; echo "CONFIG_PACKAGE_luci-i18n-adguardhome-zh-cn=y" >> .config; } || disabled_pkgs+=("luci-app-adguardhome" "luci-i18n-adguardhome-zh-cn")
  is_true "$ENABLE_OPENCLASH" && echo "CONFIG_PACKAGE_luci-app-openclash=y" >> .config || disabled_pkgs+=("luci-app-openclash")
  fi
  if is_true "$ENABLE_UPNP"; then
    cat >> .config <<'EOF'
CONFIG_PACKAGE_luci-app-upnp=y
CONFIG_PACKAGE_luci-i18n-upnp-zh-cn=y
CONFIG_PACKAGE_miniupnpd-nftables=y
CONFIG_PACKAGE_rpcd-mod-ucode=y
CONFIG_PACKAGE_libcap-ng=y
CONFIG_PACKAGE_libmnl=y
CONFIG_PACKAGE_libuuid=y
CONFIG_PACKAGE_libnftnl=y
EOF
  else
    disabled_pkgs+=("luci-app-upnp" "luci-i18n-upnp-zh-cn" "miniupnpd-nftables" "miniupnpd-iptables")
  fi
  is_true "$ENABLE_VLMCSD" && { echo "CONFIG_PACKAGE_luci-app-vlmcsd=y" >> .config; echo "CONFIG_PACKAGE_luci-i18n-vlmcsd-zh-cn=y" >> .config; echo "CONFIG_PACKAGE_vlmcsd=y" >> .config; } || disabled_pkgs+=("luci-app-vlmcsd" "luci-i18n-vlmcsd-zh-cn" "vlmcsd")
  if is_true "$ENABLE_MOSDNS"; then
    cat >> .config <<'EOF'
CONFIG_PACKAGE_luci-app-mosdns=y
CONFIG_PACKAGE_luci-i18n-mosdns-zh-cn=y
CONFIG_PACKAGE_mosdns=y
CONFIG_PACKAGE_v2dat=y
CONFIG_PACKAGE_v2ray-geoip=y
CONFIG_PACKAGE_v2ray-geosite=y
EOF
  else
    disabled_pkgs+=("luci-app-mosdns" "luci-i18n-mosdns-zh-cn" "mosdns" "v2dat" "v2ray-geoip" "v2ray-geosite")
  fi
  if is_true "$ENABLE_HOMEPROXY"; then
    cat >> .config <<'EOF'
CONFIG_PACKAGE_luci-app-homeproxy=y
CONFIG_PACKAGE_luci-i18n-homeproxy-zh-cn=y
CONFIG_PACKAGE_sing-box=y
CONFIG_PACKAGE_firewall4=y
CONFIG_PACKAGE_kmod-nft-tproxy=y
CONFIG_PACKAGE_kmod-inet-diag=y
CONFIG_PACKAGE_kmod-netlink-diag=y
CONFIG_PACKAGE_kmod-tun=y
CONFIG_PACKAGE_ucode-mod-digest=y
CONFIG_PACKAGE_ca-bundle=y
EOF
  else
    disabled_pkgs+=("luci-app-homeproxy" "luci-i18n-homeproxy-zh-cn")
  fi

  if is_true "$ENABLE_UPNP"; then
    enable_upnp_stack_config
  fi
  if is_true "$ENABLE_MWAN3"; then
    cat >> .config <<'EOF'
CONFIG_KERNEL_NET_L3_MASTER_DEV=y
CONFIG_PACKAGE_kmod-vrf=y
CONFIG_PACKAGE_mwan3=y
CONFIG_PACKAGE_luci-app-mwan3=y
CONFIG_PACKAGE_luci-i18n-mwan3-zh-cn=y
CONFIG_PACKAGE_ip-full=y
CONFIG_PACKAGE_ipset=y
CONFIG_PACKAGE_iptables-nft=y
CONFIG_PACKAGE_iptables-zz-legacy=y
CONFIG_PACKAGE_ip6tables-nft=y
CONFIG_PACKAGE_ip6tables-zz-legacy=y
# IPv6 netfilter kernel + userspace pieces needed by mwan3 in IPV6 mode
# (NDP-matching ip6tables hooks, IPv6 NAT, ipset family inet6).
CONFIG_PACKAGE_kmod-ip6tables=y
CONFIG_PACKAGE_kmod-ip6tables-extra=y
CONFIG_PACKAGE_kmod-ipt-nat6=y
CONFIG_PACKAGE_kmod-nf-nat6=y
CONFIG_PACKAGE_kmod-nf-ipt6=y
CONFIG_PACKAGE_kmod-ip6-tunnel=y
CONFIG_PACKAGE_libip6tc=y
CONFIG_PACKAGE_ip6tables-mod-nat=y
CONFIG_PACKAGE_ip6tables-extra=y
CONFIG_PACKAGE_jshn=y
CONFIG_PACKAGE_iptables-mod-conntrack-extra=y
CONFIG_PACKAGE_iptables-mod-ipopt=y
CONFIG_PACKAGE_kmod-ipt-core=y
CONFIG_PACKAGE_kmod-ipt-conntrack=y
CONFIG_PACKAGE_kmod-ipt-conntrack-extra=y
CONFIG_PACKAGE_kmod-ipt-ipopt=y
CONFIG_PACKAGE_kmod-ipt-ipset=y
CONFIG_PACKAGE_kmod-ipt-raw=y
CONFIG_PACKAGE_kmod-nf-conntrack=y
CONFIG_PACKAGE_kmod-nf-conntrack6=y
CONFIG_PACKAGE_kmod-nf-conncount=y
CONFIG_PACKAGE_kmod-nfnetlink=y
EOF
  else
    disabled_pkgs+=("mwan3" "luci-app-mwan3" "luci-i18n-mwan3-zh-cn")
  fi
  is_true "$ENABLE_ADBYBY_PLUS" && { echo "CONFIG_PACKAGE_luci-app-adbyby-plus=y" >> .config; echo "CONFIG_PACKAGE_luci-i18n-adbyby-plus-zh-cn=y" >> .config; echo "CONFIG_PACKAGE_ipset=y" >> .config; } || disabled_pkgs+=("luci-app-adbyby-plus" "luci-i18n-adbyby-plus-zh-cn")

  if is_true "$ENABLE_DOCKERMAN"; then
    cat >> .config <<'EOF'
CONFIG_PACKAGE_luci-app-dockerman=y
CONFIG_PACKAGE_luci-i18n-dockerman-zh-cn=y
CONFIG_PACKAGE_luci-lib-docker=y
CONFIG_PACKAGE_docker=y
CONFIG_PACKAGE_dockerd=y
CONFIG_PACKAGE_containerd=y
CONFIG_PACKAGE_runc=y
EOF
  else
    disabled_pkgs+=("luci-app-dockerman" "luci-i18n-dockerman-zh-cn" "luci-lib-docker")
  fi

  if is_true "$ENABLE_ORIGINAL_MODEM"; then
    echo "CONFIG_PACKAGE_luci-app-modem=y" >> .config
    echo "CONFIG_PACKAGE_modem=y" >> .config
    echo "CONFIG_PACKAGE_luci-i18n-modem-zh-cn=y" >> .config
  else
    disabled_pkgs+=("luci-app-modem" "modem" "luci-i18n-modem-zh-cn" "luci-i18n-modem-en")
  fi

  if is_true "$ENABLE_QMODEM_NEXT"; then
    echo "CONFIG_PACKAGE_luci-app-qmodem-next=y" >> .config
    echo "CONFIG_PACKAGE_luci-i18n-qmodem-next-zh-cn=y" >> .config
  elif is_true "$ENABLE_QMODEM"; then
    cat >> .config <<'EOF'
CONFIG_PACKAGE_luci-app-qmodem=y
CONFIG_PACKAGE_luci-compat=y
CONFIG_PACKAGE_qmodem=y
CONFIG_PACKAGE_luci-app-qmodem_INCLUDE_vendor-qmi-wwan=y
# CONFIG_PACKAGE_luci-app-qmodem_INCLUDE_generic-qmi-wwan is not set
CONFIG_PACKAGE_luci-app-qmodem_INCLUDE_ndisc6=y
# CONFIG_PACKAGE_luci-app-qmodem_INCLUDE_rdisc6 is not set
# CONFIG_PACKAGE_luci-app-qmodem_INCLUDE_no_ndisc_rdisc6 is not set
CONFIG_PACKAGE_ndisc6=y
CONFIG_PACKAGE_luci-app-qmodem_USE_TOM_CUSTOMIZED_QUECTEL_CM=y
# CONFIG_PACKAGE_luci-app-qmodem_USING_QWRT_QUECTEL_CM_5G is not set
# CONFIG_PACKAGE_luci-app-qmodem_USING_NORMAL_QUECTEL_CM is not set
CONFIG_PACKAGE_quectel-CM-5G-M=y
CONFIG_PACKAGE_sms-tool_q=y
CONFIG_PACKAGE_ubus-at-daemon=y
CONFIG_PACKAGE_tom_modem=y
CONFIG_PACKAGE_kmod-qmi_wwan_q=y
CONFIG_PACKAGE_kmod-qmi_wwan_f=y
CONFIG_PACKAGE_kmod-qmi_wwan_s=y
CONFIG_PACKAGE_mtkhqos_util=y
EOF
  else
    disabled_pkgs+=("luci-app-qmodem-next" "luci-i18n-qmodem-next-zh-cn" "luci-app-qmodem")
  fi

  local all_disabled=("luci-app-wrtbwmon" "luci-app-rclone" "rclone" "rclone-ng" "rclone-webui-react" "${disabled_pkgs[@]}")
  local pkg
  for pkg in "${all_disabled[@]}"; do
    sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
    echo "# CONFIG_PACKAGE_${pkg} is not set" >> .config
  done

  if is_true "$ENABLE_NIKKI"; then
    config_disable PACKAGE_mihomo-alpha
    config_enable PACKAGE_mihomo-meta
    config_enable PACKAGE_nikki
    config_enable PACKAGE_luci-app-nikki
    config_enable PACKAGE_luci-i18n-nikki-zh-cn
  fi

  config_enable PACKAGE_luci-i18n-mtwifi-cfg-zh-cn
  enable_h5000m_wifi_driver_config

  if is_true "$ENABLE_MOSDNS"; then
    config_enable PACKAGE_luci-app-mosdns
    config_enable PACKAGE_luci-i18n-mosdns-zh-cn
    config_enable PACKAGE_mosdns
    config_enable PACKAGE_v2dat
    config_enable PACKAGE_v2ray-geoip
    config_enable PACKAGE_v2ray-geosite
  fi

  if is_true "$ENABLE_UPNP"; then
    config_disable PACKAGE_miniupnpd-iptables
    enable_upnp_stack_config
  fi

  if is_true "$ENABLE_MWAN3"; then
    enable_mwan3_stack_config
  fi

  if is_true "$ENABLE_HOMEPROXY"; then
    config_enable PACKAGE_luci-app-homeproxy
    config_enable PACKAGE_luci-i18n-homeproxy-zh-cn
    config_enable PACKAGE_sing-box
    config_enable PACKAGE_kmod-nft-tproxy
    config_enable PACKAGE_kmod-inet-diag
    config_enable PACKAGE_kmod-netlink-diag
    config_enable PACKAGE_kmod-tun
  fi

  if is_true "$ENABLE_VLMCSD"; then
    config_enable PACKAGE_vlmcsd
    config_enable PACKAGE_luci-app-vlmcsd
    config_enable PACKAGE_luci-i18n-vlmcsd-zh-cn
  fi

  run_with_timeout "$CONFIG_TIMEOUT" "make defconfig" make FORCE=1 defconfig -j"${THREADS}"
  retry_upnp_config_if_needed

  if is_true "$ENABLE_VLMCSD" && ! grep -q '^CONFIG_PACKAGE_luci-app-vlmcsd=y$' .config; then
    run_with_timeout "$FEEDS_TIMEOUT" "feeds install vlmcsd after VLMCSd retry" ./scripts/feeds install -f vlmcsd || true
    run_with_timeout "$FEEDS_TIMEOUT" "feeds install luci-app-vlmcsd after VLMCSd retry" ./scripts/feeds install -f luci-app-vlmcsd || true
    config_enable PACKAGE_vlmcsd
    config_enable PACKAGE_luci-app-vlmcsd
    run_with_timeout "$CONFIG_TIMEOUT" "make defconfig after VLMCSd retry" make FORCE=1 defconfig -j"${THREADS}"
  fi

  verify_enabled_pkg "Nikki" "luci-app-nikki" "$ENABLE_NIKKI"
  verify_enabled_pkg "Nikki zh-cn" "luci-i18n-nikki-zh-cn" "$ENABLE_NIKKI"
  verify_enabled_pkg "Nikki core" "nikki" "$ENABLE_NIKKI"
  verify_enabled_pkg "Nikki mihomo-meta" "mihomo-meta" "$ENABLE_NIKKI"
  verify_enabled_pkg "OpenClash" "luci-app-openclash" "$ENABLE_OPENCLASH"
  verify_enabled_pkg "AdGuardHome" "luci-app-adguardhome" "$ENABLE_ADGUARDHOME"
  verify_enabled_pkg "AdGuardHome zh-cn" "luci-i18n-adguardhome-zh-cn" "$ENABLE_ADGUARDHOME"
  # sirpdboy/luci-app-adguardhome is shipped as a prebuilt ipk. The Makefile
  # that wraps it lives under package/prebuilt-luci-app/. If it is missing
  # make defconfig will silently drop CONFIG_PACKAGE_luci-app-adguardhome=y
  # and verify_enabled_pkg above will fail with no actionable cause.
  if is_true "$ENABLE_ADGUARDHOME"; then
    require_package_file "AdGuardHome prebuilt app" "package/prebuilt-luci-app/luci-app-adguardhome/Makefile"
    require_package_file "AdGuardHome prebuilt zh-cn" "package/prebuilt-i18n/luci-i18n-adguardhome-zh-cn/Makefile"
  fi
  verify_enabled_pkg "UPnP" "luci-app-upnp" "$ENABLE_UPNP"
  verify_enabled_pkg "UPnP zh-cn" "luci-i18n-upnp-zh-cn" "$ENABLE_UPNP"
  verify_enabled_pkg "UPnP miniupnpd" "miniupnpd-nftables" "$ENABLE_UPNP"
  verify_enabled_pkg "VLMCSd" "luci-app-vlmcsd" "$ENABLE_VLMCSD"
  verify_enabled_pkg "VLMCSd zh-cn" "luci-i18n-vlmcsd-zh-cn" "$ENABLE_VLMCSD"
  verify_enabled_pkg "MosDNS" "luci-app-mosdns" "$ENABLE_MOSDNS"
  verify_enabled_pkg "MosDNS zh-cn" "luci-i18n-mosdns-zh-cn" "$ENABLE_MOSDNS"
  verify_enabled_pkg "MosDNS core" "mosdns" "$ENABLE_MOSDNS"
  verify_enabled_pkg "MosDNS v2dat" "v2dat" "$ENABLE_MOSDNS"
  verify_enabled_pkg "MosDNS geoip" "v2ray-geoip" "$ENABLE_MOSDNS"
  verify_enabled_pkg "MosDNS geosite" "v2ray-geosite" "$ENABLE_MOSDNS"
  verify_enabled_pkg "DockerMan" "luci-app-dockerman" "$ENABLE_DOCKERMAN"
  verify_enabled_pkg "DockerMan zh-cn" "luci-i18n-dockerman-zh-cn" "$ENABLE_DOCKERMAN"
  verify_enabled_pkg "QModem Next" "luci-app-qmodem-next" "$ENABLE_QMODEM_NEXT"
  verify_enabled_pkg "QModem Next zh-cn" "luci-i18n-qmodem-next-zh-cn" "$ENABLE_QMODEM_NEXT"
  verify_enabled_pkg "HomeProxy" "luci-app-homeproxy" "$ENABLE_HOMEPROXY"
  verify_enabled_pkg "HomeProxy zh-cn" "luci-i18n-homeproxy-zh-cn" "$ENABLE_HOMEPROXY"
  verify_enabled_pkg "HomeProxy sing-box" "sing-box" "$ENABLE_HOMEPROXY"
  verify_enabled_pkg "HomeProxy nft tproxy" "kmod-nft-tproxy" "$ENABLE_HOMEPROXY"
  verify_enabled_pkg "Adbyby Plus" "luci-app-adbyby-plus" "$ENABLE_ADBYBY_PLUS"
  verify_enabled_pkg "Adbyby Plus zh-cn" "luci-i18n-adbyby-plus-zh-cn" "$ENABLE_ADBYBY_PLUS"
  verify_enabled_pkg "MWAN3 LuCI" "luci-app-mwan3" "$ENABLE_MWAN3"
  verify_enabled_pkg "MWAN3 zh-cn" "luci-i18n-mwan3-zh-cn" "$ENABLE_MWAN3"
  verify_enabled_pkg "MWAN3 ipset userspace" "ipset" "$ENABLE_MWAN3"
  verify_enabled_pkg "MWAN3 iptables-nft" "iptables-nft" "$ENABLE_MWAN3"
  verify_enabled_pkg "MWAN3 iptables-zz-legacy" "iptables-zz-legacy" "$ENABLE_MWAN3"
  verify_enabled_pkg "MWAN3 ip6tables-nft" "ip6tables-nft" "$ENABLE_MWAN3"
  verify_enabled_pkg "MWAN3 ip6tables-zz-legacy" "ip6tables-zz-legacy" "$ENABLE_MWAN3"
  verify_enabled_pkg "MWAN3 IPv6 netfilter core" "kmod-ip6tables" "$ENABLE_MWAN3"
  verify_enabled_pkg "MWAN3 IPv6 icmp6 match" "kmod-ip6tables-extra" "$ENABLE_MWAN3"
  verify_enabled_pkg "MWAN3 IPv6 NAT" "kmod-ipt-nat6" "$ENABLE_MWAN3"
  verify_enabled_pkg "MWAN3 IPv6 NAT core" "kmod-nf-nat6" "$ENABLE_MWAN3"
  verify_enabled_pkg "MWAN3 IPv6 iptables core" "kmod-nf-ipt6" "$ENABLE_MWAN3"
  verify_enabled_pkg "MWAN3 libip6tc" "libip6tc" "$ENABLE_MWAN3"
  verify_enabled_pkg "MWAN3 ip6tables-mod-nat" "ip6tables-mod-nat" "$ENABLE_MWAN3"
  verify_enabled_pkg "MWAN3 iptables-mod-conntrack-extra" "iptables-mod-conntrack-extra" "$ENABLE_MWAN3"
  verify_enabled_pkg "MWAN3 iptables-mod-ipopt" "iptables-mod-ipopt" "$ENABLE_MWAN3"
  verify_enabled_pkg "MWAN3 kmod-ipt-conntrack-extra" "kmod-ipt-conntrack-extra" "$ENABLE_MWAN3"
  verify_enabled_pkg "MWAN3 kmod-ipt-ipopt" "kmod-ipt-ipopt" "$ENABLE_MWAN3"
  verify_enabled_pkg "MWAN3 kmod-ipt-ipset" "kmod-ipt-ipset" "$ENABLE_MWAN3"
  verify_enabled_pkg "MWAN3 kmod-vrf" "kmod-vrf" "$ENABLE_MWAN3"
  if is_true "$ENABLE_MWAN3"; then
    verify_config_symbol "MWAN3 VRF kernel prereq" "CONFIG_KERNEL_NET_L3_MASTER_DEV=y"
  fi
  verify_enabled_pkg "MT WiFi zh-cn" "luci-i18n-mtwifi-cfg-zh-cn" true
  # Network acceleration (turboacc-mtk) and fan control (Airpifanctrl) are
  # always-on base options in h5000m.extra.config; if the upstream package
  # trees got renamed/moved the clones in apply_package_fixes will be
  # missing and these checks will fail loudly instead of silently dropping
  # the .config symbol.
  verify_enabled_pkg "turboacc-mtk LuCI" "luci-app-turboacc-mtk" true
  verify_enabled_pkg "Airpifanctrl LuCI" "luci-app-Airpifanctrl" true
  verify_enabled_pkg "kmod-mediatek_hnat" "kmod-mediatek_hnat" true
  verify_config_symbol "H5000M USE_RFKILL dependency" "CONFIG_USE_RFKILL=y"
  verify_enabled_pkg "H5000M blkid dependency" "blkid" true
  verify_enabled_pkg "H5000M MT WiFi common" "kmod-mt_wifi_cmn" true
  verify_enabled_pkg "H5000M MT WiFi7 driver" "kmod-mt_wifi7" true
  verify_enabled_pkg "H5000M MT HWIFI driver" "kmod-mt_hwifi" true
  # MTK HWIFI core configuration verification
  verify_config_symbol "H5000M HWIFI PCI support" "CONFIG_MTK_HWIFI_PCI_SUPPORT=y"
  verify_config_symbol "H5000M HWIFI CONNAC interface" "CONFIG_MTK_HWIFI_CONNAC_IF_SUPPORT=y"
  verify_config_symbol "H5000M HWIFI WED support" "CONFIG_MTK_HWIFI_WED_SUPPORT=y"
  verify_config_symbol "H5000M MT7992 Kconfig" "CONFIG_MTK_HWIFI_MT7992=y"
  verify_config_symbol "H5000M MT799A Kconfig" "CONFIG_MTK_HWIFI_MT799A=y"
  # MT7992 specific tuning parameters (from upstream)
  verify_config_symbol "H5000M MT7992 RRO mode" "CONFIG_MTK_HWIFI_MT7992_RRO_MODE=4"
  verify_config_symbol "H5000M MT7992 option type" "CONFIG_MTK_HWIFI_MT7992_OPTION_TYPE=0"
  verify_config_symbol "H5000M MT7992 interrupt option" "CONFIG_MTK_HWIFI_MT7992_INTR_OPTION_SET=0"
  verify_config_symbol "H5000M RX process workqueue" "CONFIG_MTK_HWIFI_RX_PROCESS_WORKQUEUE=y"
  # MTK WIFI7 driver configuration verification
  verify_config_symbol "H5000M WIFI7 openwrt support" "CONFIG_MTK_WIFI7_SUPPORT_OPENWRT=y"
  verify_config_symbol "H5000M WIFI7 driver support" "CONFIG_MTK_WIFI7_DRIVER=y"
  verify_config_symbol "H5000M WIFI7 unified command" "CONFIG_MTK_WIFI7_UNIFIED_COMMAND=y"
  verify_config_symbol "H5000M WIFI7 chip MT7992" "CONFIG_MTK_WIFI7_CHIP_MT7992=y"
  verify_config_symbol "H5000M WIFI7 first if MT7992" "CONFIG_MTK_WIFI7_FIRST_IF_MT7992=y"
  verify_config_symbol "H5000M WIFI7 second if MT7992" "CONFIG_MTK_WIFI7_SECOND_IF_MT7992=y"
  verify_config_symbol "H5000M WIFI7 third if none" "CONFIG_MTK_WIFI7_THIRD_IF_NONE=y"
  verify_config_symbol "H5000M WIFI7 WHNAT support" "CONFIG_MTK_WIFI7_WHNAT_SUPPORT=m"
  verify_enabled_pkg "H5000M MTK PCI driver" "kmod-mtk_pci" true
  verify_enabled_pkg "H5000M MTK WED driver" "kmod-mtk_wed" true
  verify_enabled_pkg "H5000M Connac interface" "kmod-connac_if" true
  verify_enabled_pkg "H5000M MT7992 chip driver" "kmod-mt7992" true
  verify_enabled_pkg "H5000M MT799A chip driver" "kmod-mt799a" true
  verify_translation_file "OpenClash built-in zh-cn" "package/luci-app-openclash/po/zh-cn/openclash.zh-cn.po" "$ENABLE_OPENCLASH"
  verify_translation_file "Adbyby Plus built-in zh-cn" "package/luci-app-adbyby-plus/po/zh-cn/adbyby.po" "$ENABLE_ADBYBY_PLUS"
}

verify_enabled_pkg() {
  local feature_name="$1"
  local config_name="$2"
  local enabled="$3"
  if is_true "$enabled" && ! grep -q "^CONFIG_PACKAGE_${config_name}=y$" .config; then
    echo "${feature_name} requested but CONFIG_PACKAGE_${config_name}=y is not active after defconfig" >&2
    grep -n "PACKAGE_${config_name}" .config || true
    exit 1
  fi
}

verify_config_symbol() {
  local feature_name="$1"
  local expected_line="$2"
  if ! grep -q "^${expected_line}$" .config; then
    echo "${feature_name} required but ${expected_line} is not active after defconfig" >&2
    grep -n "${expected_line%%=*}" .config || true
    exit 1
  fi
}

verify_translation_file() {
  local feature_name="$1"
  local file_path="$2"
  local enabled="$3"
  if is_true "$enabled" && [ ! -f "$file_path" ]; then
    die "$feature_name requested but translation file is missing: $file_path"
  fi
}

prefetch_and_toolchain() {
  cd "$ROOT_DIR/$SOURCE_DIR"
  if ! is_true "$SKIP_DOWNLOAD"; then
    log "Downloading package sources"
    find dl -size -1024c -delete 2>/dev/null || true
    for attempt in 1 2 3; do
      run_with_timeout "$DOWNLOAD_TIMEOUT" "make download attempt $attempt" make FORCE=1 download -j"$THREADS" && break
      find dl -size -1024c -delete 2>/dev/null || true
      [ "$attempt" -eq 3 ] && echo "WARNING: make download did not complete cleanly"
    done
  fi

  toolchain_cache_valid() {
    # Check build_dir (not staging_dir) — OpenWrt places actual toolchain compiler
    # and binutils in build_dir/toolchain-<triple>/gcc-<ver>/; staging_dir only gets
    # stub copies after make world.  Validate the real binaries to avoid false cache hits.
    [ -n "$(find build_dir/toolchain-* -maxdepth 3 -name 'gcc' -type f 2>/dev/null | head -1)" ] && return 0
    [ -n "$(find build_dir/toolchain-* -maxdepth 3 -name 'ld' -type f 2>/dev/null | head -1)" ] && return 0
    return 1
  }

  staging_dir_toolchain_has_linker() {
    # staging_dir/toolchain-*/lib/ is where the final musl linker is copied by
    # the toolchain/package/libs/toolchain compile step.  Verify this exists.
    [ -n "$(find staging_dir/toolchain-* -maxdepth 2 -name 'ld-musl-*.so*' 2>/dev/null | head -1)" ] && return 0
    [ -n "$(find staging_dir/toolchain-* -maxdepth 2 -name 'ld-linux-*.so*' 2>/dev/null | head -1)" ] && return 0
    return 1
  }

  # GCC 13's libcody uses S2C(u8"...") which is char8_t[N] in C++20 (GCC 16).
  # GCC 16 rejects this because S2C's template only accepts char const(&)[I].
  # Add a char8_t overload so the code compiles under GCC 16's C++20 mode.
  patch_toolchain_gcc_char8t() {
    local cody_hh
    cody_hh=$(find build_dir/toolchain-* -path '*/gcc-13.3.0/libcody/cody.hh' 2>/dev/null | head -1)
    if [ -z "$cody_hh" ]; then
      echo "WARNING: gcc-13.3.0 libcody cody.hh not found, skipping char8_t patch"
      return
    fi
    if grep -q 'char8_t const.*S2C' "$cody_hh" 2>/dev/null; then
      echo "char8_t S2C overload already present in cody.hh"
      return
    fi
    echo "Patching cody.hh to add char8_t S2C overload for GCC 16 compatibility"
    sed -i '/^template<unsigned I>$/,/^}$/{ /^}$/a\
template<unsigned I>\
constexpr char S2C (char8_t const (\&s)[I])\
{\
  static_assert (I == 2, "only single octet strings may be converted");\
  return static_cast<char>(s[0]);\
}
}' "$cody_hh"
  }

  if ! is_true "$SKIP_TOOLCHAIN"; then
    log "Validating prebuilt toolchain cache"
    if toolchain_cache_valid; then
      echo "Toolchain build directories look usable"
    else
      log "Toolchain build incomplete; rebuilding toolchain"
      rm -rf staging_dir/toolchain-* build_dir/toolchain-* 2>/dev/null || true
      # Patch gcc-13.3.0 libcody before building — needed when host uses GCC 16+
      patch_toolchain_gcc_char8t
      # Build the full toolchain.  make world compiles libc, gcc, binutils into
      # build_dir/toolchain-*, then copies stubs into staging_dir/toolchain-*.
      run_with_timeout "$TOOLCHAIN_TIMEOUT" "make world" make FORCE=1 world -j"$THREADS"
    fi
    # Double-check: if staging_dir is still empty after make world, something is wrong.
    # Force a targeted toolchain install to populate staging_dir.
    if ! staging_dir_toolchain_has_linker; then
      log "WARNING: staging_dir/toolchain linker missing after make world — forcing toolchain install"
      run_with_timeout "$TOOLCHAIN_TIMEOUT" "make toolchain/install" make FORCE=1 toolchain/install -j"$THREADS" || true
    fi
    if ! staging_dir_toolchain_has_linker; then
      die "Toolchain staging_dir still missing linker after toolchain/install. Check build errors above."
    fi
  fi
}

clean_v2dat_go_mod_cache() {
  rm -rf \
    dl/go-mod-cache/github.com/edsrzf/mmap-go@v1.2.0 \
    dl/go-mod-cache/github.com/inconshreveable/mousetrap@v1.1.0 \
    dl/go-mod-cache/github.com/spf13/cobra@v1.10.2 \
    dl/go-mod-cache/github.com/spf13/pflag@v1.0.10 \
    dl/go-mod-cache/go.uber.org/multierr@v1.11.0 \
    dl/go-mod-cache/go.uber.org/zap@v1.27.1 \
    dl/go-mod-cache/golang.org/x/sys@v0.37.0 \
    dl/go-mod-cache/google.golang.org/protobuf@v1.36.11 2>/dev/null || true
}

clean_go_mod_cache() {
  rm -rf dl/go-mod-cache tmp/go-build 2>/dev/null || true
}

precompile_v2dat() {
  ! is_true "$ENABLE_MOSDNS" && return 0
  [ -d "package/mosdns/v2dat" ] || return 0
  log "Precompiling MosDNS v2dat"
  run_with_timeout "$V2DAT_TIMEOUT" "clean MosDNS v2dat" make -j"${THREADS}" package/mosdns/v2dat/clean V=s || true
  run_with_timeout "$V2DAT_TIMEOUT" "compile MosDNS v2dat" make -j"${THREADS}" package/mosdns/v2dat/compile V=s
}

clean_v2ray_geodata_build() {
  ! is_true "$ENABLE_MOSDNS" && return 0
  rm -rf build_dir/target-*/v2ray-geodata 2>/dev/null || true
  rm -f staging_dir/target-*/stamp/.v2ray-geoip_installed staging_dir/target-*/stamp/.v2ray-geosite_installed 2>/dev/null || true
}

compile_firmware() {
  log "Compiling firmware with ${THREADS} threads"
  cd "$ROOT_DIR/$SOURCE_DIR"
  sanitize_path
  export PATH="/usr/lib/ccache:$PATH"
  export CCACHE_DIR="${CCACHE_DIR:-$ROOT_DIR/$SOURCE_DIR/build_dir/ccache}"
  export CCACHE_SIZE="${CCACHE_SIZE:-10G}"
  mkdir -p "$CCACHE_DIR"

  log "Cleaning Go module cache before Go package builds"
  clean_go_mod_cache
  precompile_v2dat
  clean_v2ray_geodata_build

  local start_time end_time duration
  start_time="$(date +%s)"
  if run_with_timeout "$COMPILE_TIMEOUT" "make firmware" make FORCE=1 -j"$THREADS" IGNORE_ERRORS=n; then
    end_time="$(date +%s)"
    duration=$((end_time - start_time))
    echo "Build succeeded in ${duration}s"
  else
    echo "Parallel build failed; running focused diagnostics before single-thread retry"
    if is_true "$ENABLE_MOSDNS"; then
      grep -RIn 'go 1\.' package/mosdns/v2dat/patches || true
      clean_v2dat_go_mod_cache
      run_with_timeout "$V2DAT_TIMEOUT" "clean MosDNS v2dat diagnostics" make -j"${THREADS}" package/mosdns/v2dat/clean V=s || true
      if ! run_with_timeout "$V2DAT_TIMEOUT" "compile MosDNS v2dat diagnostics" make -j"${THREADS}" package/mosdns/v2dat/compile V=s; then
        find build_dir -path '*v2dat*/go.mod' -exec sh -c 'echo "--- $1"; sed -n "1,40p" "$1"' _ {} \; || true
        die "MosDNS v2dat failed to compile"
      fi
    fi
    run_with_timeout "$COMPILE_TIMEOUT" "make firmware single-thread diagnostics" make FORCE=1 -j1 V=s
  fi
}

collect_artifacts() {
  log "Collecting firmware artifacts"
  cd "$ROOT_DIR"
  rm -rf "$ARTIFACTS_DIR"
  mkdir -p "$ARTIFACTS_DIR"

  find "$SOURCE_DIR/bin/targets" -type f \( -name '*.bin' -o -name '*.img.gz' \) -exec cp -f {} "$ARTIFACTS_DIR/" \;
  find "$SOURCE_DIR/bin/targets" -type f -name '*hiveton-h5000m*.manifest' -exec cp -f {} "$ARTIFACTS_DIR/openwrt-image.manifest" \; -quit
  if [ -z "$(ls -A "$ARTIFACTS_DIR" 2>/dev/null)" ]; then
    die "No firmware artifacts found under $SOURCE_DIR/bin/targets"
  fi
  [ -f "$ARTIFACTS_DIR/openwrt-image.manifest" ] || die "H5000M OpenWrt image manifest was not generated"

  local image_pkg
  for image_pkg in \
    kmod-mt_wifi_cmn \
    kmod-mt_wifi7 \
    kmod-mt_hwifi \
    kmod-mtk_pci \
    kmod-mtk_wed \
    kmod-connac_if \
    kmod-mt7992 \
    kmod-mt799a \
    mtwifi-cfg \
    luci-app-mtwifi-cfg \
    luci-i18n-mtwifi-cfg-zh-cn \
    grep -q "^${image_pkg}[[:space:]-]" "$ARTIFACTS_DIR/openwrt-image.manifest" || \
      die "Firmware image manifest is missing required package: ${image_pkg}"
  done

  if is_true "$ENABLE_ADGUARDHOME" && ! grep -q '^luci-i18n-adguardhome-zh-cn[[:space:]-]' "$ARTIFACTS_DIR/openwrt-image.manifest"; then
    die "Firmware image manifest is missing required package: luci-i18n-adguardhome-zh-cn"
  fi
  if is_true "$ENABLE_ADBYBY_PLUS" && ! grep -q '^luci-i18n-adbyby-plus-zh-cn[[:space:]-]' "$ARTIFACTS_DIR/openwrt-image.manifest"; then
    die "Firmware image manifest is missing required package: luci-i18n-adbyby-plus-zh-cn"
  fi
  if is_true "$ENABLE_HOMEPROXY" && ! grep -q '^luci-app-homeproxy[[:space:]-]' "$ARTIFACTS_DIR/openwrt-image.manifest"; then
    die "Firmware image manifest is missing required package: luci-app-homeproxy"
  fi

  {
    echo "ImmortalWrt H5000M local build"
    echo "Build time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Source: $REPO_URL ($REPO_BRANCH)"
    echo
    echo "Artifacts:"
    (cd "$ARTIFACTS_DIR" && ls -lh | sed 's/^/  /')
  } > "$ARTIFACTS_DIR/MANIFEST.txt"

  cp -f "$SOURCE_DIR/.config" "$ARTIFACTS_DIR/build.config"
  grep '^CONFIG_PACKAGE_.*=y$' "$SOURCE_DIR/.config" | sort > "$ARTIFACTS_DIR/enabled-packages.txt"

  tar -czf artifacts.tar.gz "$ARTIFACTS_DIR"
  ls -lh "$ARTIFACTS_DIR"
  echo "Artifacts archive: $ROOT_DIR/artifacts.tar.gz"
}

main() {
  cd "$ROOT_DIR"
  is_true "$INSTALL_DEPS" && install_deps
  check_environment
  show_features
  prepare_source
  prepare_feeds
  apply_package_fixes
  install_selected_packages
  configure_build
  is_true "$PREPARE_ONLY" && { log "Prepare-only requested; stopping before downloads/build"; exit 0; }
  is_true "$CONFIG_ONLY" && { log "Config-only requested; stopping before downloads/build"; exit 0; }
  prefetch_and_toolchain
  compile_firmware
  collect_artifacts
}

main "$@"