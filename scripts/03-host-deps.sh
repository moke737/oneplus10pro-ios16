#!/usr/bin/env bash
# 03-host-deps.sh - host dependencies for the iOSPlus10 build (Ubuntu 24.04).
# Mirrors docs/setup-linux.md, plus the extra bits this workspace needs.
#
# Run from Windows:
#   powershell -ExecutionPolicy Bypass -File scripts\run-wsl.ps1 -Script 03-host-deps.sh

set -euo pipefail

WORKSPACE="${IOSPLUS10_DIR:-$HOME/iOSPlus10}"
LOG="${HOME}/unixnu-logs"
mkdir -p "$LOG"

say()  { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '  [OK] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
die()  { printf '  [FAIL] %s\n' "$*"; exit 1; }

[ -d "$WORKSPACE" ] || die "missing $WORKSPACE - run 02-setup-repos.sh first"

avail=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
say "free space in \$HOME: ${avail} GB"
[ "${avail:-0}" -ge 40 ] || warn "under 40 GB free; the root image alone needs ~27 GB (15 raw + 12 simg)"

# --- apt packages --------------------------------------------------------
say "apt packages (required)"
sudo -v
sudo apt-get update -qq
sudo apt-get install -y \
  git tmux make rsync curl ca-certificates \
  build-essential gawk cpio \
  docker.io \
  python3 python3-venv python3-pip \
  device-tree-compiler kmod 2>&1 | tee "$LOG/03-apt.log"
ok "required packages installed"

# Optional: only needed for the iOS root image (make root) and adb udev rules.
# apfs-fuse/hfsprogs are not in the Ubuntu 24.04 archive, so do not fail on them.
say "apt packages (optional)"
for p in apfs-fuse hfsprogs android-sdk-platform-tools android-sdk-platform-tools-common erofs-utils; do
  if sudo apt-get install -y "$p" >/dev/null 2>&1; then
    ok "$p"
  else
    warn "$p not available - only needed later (iOS root image / udev rules)"
  fi
done

# --- docker registry mirror ---------------------------------------------
# registry-1.docker.io is unreachable on this network; daocloud's mirror answers.
say "configuring the docker registry mirror"
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": ["https://docker.m.daocloud.io"]
}
EOF
ok "/etc/docker/daemon.json written"

# --- pip / rust mirrors -------------------------------------------------
cat > /etc/pip.conf <<'EOF'
[global]
index-url = https://mirrors.aliyun.com/pypi/simple/
trusted-host = mirrors.aliyun.com
EOF
ok "/etc/pip.conf written"

export RUSTUP_DIST_SERVER=https://mirrors.ustc.edu.cn/rust-static
export RUSTUP_UPDATE_ROOT=https://mirrors.ustc.edu.cn/rust-static/rustup

# --- hfsplus module ------------------------------------------------------
say "hfsplus kernel module (needed by the root image build)"
sudo modprobe hfsplus 2>/dev/null && ok "hfsplus loaded" || warn "modprobe hfsplus failed - check the WSL kernel"
grep -q hfsplus /proc/filesystems && ok "hfsplus present in /proc/filesystems" || warn "hfsplus not in /proc/filesystems"

# --- docker group --------------------------------------------------------
if getent group docker | grep -qw "$USER"; then
  ok "$USER already in the docker group"
else
  sudo usermod -aG docker "$USER"
  warn "added $USER to docker - LOG OUT and back in (or 'newgrp docker') before 'make mu'"
fi

# --- udev rules (absent in WSL) -----------------------------------------
if [ ! -d /etc/udev/rules.d ]; then
  say "no /etc/udev/rules.d (WSL) - skipping udev rules; adb/fastboot run on Windows"
elif [ -f /etc/udev/rules.d/51-android.rules ]; then
  ok "udev rules present"
else
  say "installing android udev rules"
  if [ -f /usr/lib/udev/rules.d/51-android.rules ]; then
    sudo cp /usr/lib/udev/rules.d/51-android.rules /etc/udev/rules.d/51-android.rules && ok "copied distro rules"
  else
    warn "no distro udev rules; adb may need sudo"
  fi
fi

# --- rust ----------------------------------------------------------------
if command -v cargo >/dev/null 2>&1; then
  ok "cargo $(cargo --version | awk '{print $2}')"
else
  say "installing rustup (rust-lang.org can be slow/blocked in CN)"
  if curl -sSf --max-time 20 https://sh.rustup.rs -o /tmp/rustup.sh 2>/dev/null; then
    sh /tmp/rustup.sh -y --default-toolchain stable 2>&1 | tee "$LOG/03-rustup.log"
  else
    warn "sh.rustup.rs unreachable - trying the USTC mirror"
    export RUSTUP_DIST_SERVER=https://mirrors.ustc.edu.cn/rust-static
    export RUSTUP_UPDATE_ROOT=https://mirrors.ustc.edu.cn/rust-static/rustup
    curl -sSf --max-time 30 https://mirrors.ustc.edu.cn/rust-static/rustup/rustup.sh -o /tmp/rustup.sh \
      && sh /tmp/rustup.sh -y --default-toolchain stable 2>&1 | tee "$LOG/03-rustup.log" \
      || die "rustup install failed (needed by make op10tool)"
  fi
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env"
  ok "cargo $(cargo --version | awk '{print $2}')"
fi

# --- payload-dumper-go ---------------------------------------------------
if command -v payload-dumper-go >/dev/null 2>&1; then
  ok "payload-dumper-go present"
else
  say "installing payload-dumper-go (for the stock OTA backup)"
  URL="https://github.com/ssut/payload-dumper-go/releases/latest/download/payload-dumper-go_1.3.0_linux_amd64.tar.gz"
  if curl -sSL --max-time 60 "$URL" -o /tmp/pdg.tgz; then
    tar -xzf /tmp/pdg.tgz -C /tmp payload-dumper-go 2>/dev/null || tar -xzf /tmp/pdg.tgz -C /tmp
    sudo install -m 755 /tmp/payload-dumper-go /usr/local/bin/payload-dumper-go && ok "installed"
  else
    warn "download failed (github releases blocked?) - install payload-dumper-go manually"
  fi
fi

# --- gh (kernel artifacts come from GitHub Actions) ----------------------
if command -v gh >/dev/null 2>&1; then
  ok "gh $(gh --version | head -1 | awk '{print $3}')"
else
  say "installing gh"
  sudo apt-get install -y gh 2>>"$LOG/03-apt.log" && ok "gh via apt" || warn "gh not in apt; install from cli.github.com, needed by 'make kernel'"
fi

# --- report --------------------------------------------------------------
say "tool versions"
for t in git make docker cargo python3 adb fastboot gh sudo; do
  if command -v "$t" >/dev/null 2>&1; then printf '  %-10s %s\n' "$t" "$(command -v "$t")"; else printf '  %-10s MISSING\n' "$t"; fi
done

cat <<EOS

Next (one-time):
  powershell -ExecutionPolicy Bypass -File scripts\\run-wsl.ps1 -Script 04-build.sh -ScriptArgs "--steps","tools op10tool image"

Remember: after the docker group change you must log out and back in.
EOS
