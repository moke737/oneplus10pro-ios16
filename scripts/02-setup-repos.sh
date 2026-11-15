#!/usr/bin/env bash
# 02-setup-repos.sh - clone the iOSPlus10 workspace (OnePlus 10 Pro / negroni)
# and all of its submodules.
#
# Run from Windows:
#   powershell -ExecutionPolicy Bypass -File scripts\run-wsl.ps1 -Script 02-setup-repos.sh
#   ... -Script 02-setup-repos.sh -ScriptArgs "--mirror"      # if github.com is blocked
#
# Layout produced:
#   ~/iOSPlus10                 the workspace (Makefile, scripts, docs, submodules)
#   ~/op10-apple                Apple artifacts + iOS root image   (created by make)
#   ~/op10-backup               stock images for restore           (you create it)

set -euo pipefail

WORKSPACE="${IOSPLUS10_DIR:-$HOME/iOSPlus10}"
REPO="${IOSPLUS10_REPO:-https://github.com/akshaynexus/iOSPlus10.git}"
ART="${UNIXNU_ARTIFACTS:-$(cd "$(dirname "$0")/.." && pwd)}"
MIRROR=0

while [ $# -gt 0 ]; do
  case "$1" in
    --mirror) MIRROR=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) printf '[FAIL] unknown option: %s\n' "$1"; exit 2 ;;
  esac
done

say()  { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '  [OK] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
die()  { printf '  [FAIL] %s\n' "$*"; exit 1; }

say "workspace: $WORKSPACE"

# --- base tools ----------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
  say "installing git"
  sudo apt-get update -qq
  sudo apt-get install -y -qq git ca-certificates curl
fi
ok "git $(git --version | awk '{print $3}')"

# Serial, HTTP/1.1 git: parallel submodule fetches through a local proxy get
# their TLS connections reset (gnutls_handshake failed), which aborts clone.
git config --global http.version HTTP/1.1
git config --global http.postBuffer 524288000
git config --global http.maxRequests 1
git config --global submodule.fetchJobs 1
ok "git configured for serial HTTP/1.1 fetches"

# --- optional github mirror ---------------------------------------------
if [ "$MIRROR" -eq 1 ]; then
  say "routing github.com through ghproxy.net"
  git config --global url."https://ghproxy.net/https://github.com/".insteadOf "https://github.com/"
  git config --global url."https://ghproxy.net/https://github.com/".insteadOf "git@github.com:"
  ok "git insteadOf configured (undo: git config --global --unset-all url.https://ghproxy.net/https://github.com/.insteadOf)"
fi

# --- reachability (only needed for a fresh clone) ------------------------
if [ -d "$WORKSPACE/.git" ]; then
  ok "existing checkout found - skipping the remote check"
else
  say "checking $REPO"
  if ! timeout 90 git ls-remote "$REPO" HEAD >/dev/null 2>&1; then
    warn "cannot reach the repository"
    cat <<'EOS'
  github.com is blocked on this network. Re-run with:
      -ScriptArgs "--mirror"
  or export a proxy first:
      export ALL_PROXY=http://$(ip route show default | awk '{print $3}'):7890
      export HTTPS_PROXY=$ALL_PROXY HTTP_PROXY=$ALL_PROXY
EOS
    die "network check failed"
  fi
  ok "reachable"
fi

# --- clone / update ------------------------------------------------------
if [ -d "$WORKSPACE/.git" ]; then
  say "workspace exists - updating"
  git -C "$WORKSPACE" fetch --prune --tags --quiet || warn "fetch failed"
  git -C "$WORKSPACE" pull --ff-only --quiet || warn "pull skipped (local changes?)"
else
  say "cloning iOSPlus10 (deep clone, be patient)"
  git clone --jobs 1 "$REPO" "$WORKSPACE"
fi

ok "workspace at $WORKSPACE ($(git -C "$WORKSPACE" rev-parse --short HEAD))"

# Submodules: serial + retry. Parallel fetches through a local proxy get their
# TLS connections reset ("gnutls_handshake() failed"), which aborts the tree.
# OpenSSL's test-data submodules and libspdm's vendored crypto are not needed
# to build the UEFI firmware; cloning them costs hundreds of MB and fails.
skip_optional_submodules() {
  local dirs=(
    "$WORKSPACE/external/Mu-Silicium-negroni/Silicon/Silicium/OpensslPkg/Library/OpensslLib/openssl"
    "$WORKSPACE/external/Mu-Silicium-negroni/Mu_Basecore/SecurityPkg/DeviceSecurity/SpdmLib/libspdm"
  )
  local d key name
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      name=${key#submodule.}
      name=${name%.path}
      git -C "$d" config "submodule.$name.update" none
    done < <(git -C "$d" config -f .gitmodules --name-only --get-regexp '\.path$' 2>/dev/null)
    say "skipped optional submodules under ${d#"$WORKSPACE"/}"
  done
}

say "initializing submodules (serial, retries, optional ones skipped)"
for i in 1 2 3 4 5 6; do
  skip_optional_submodules
  if git -C "$WORKSPACE" submodule update --init --recursive --jobs 1; then
    ok "all required submodules present"
    break
  fi
  warn "submodule update failed (attempt $i/6), retrying in 5 s"
  sleep 5
  if [ "$i" -eq 6 ]; then die "submodule update keeps failing - check the proxy"; fi
done

ok "submodules:"
git -C "$WORKSPACE" submodule status 2>/dev/null | awk '{printf "    %s %s\n", substr($1,1,9), $2}' || true

# --- sanity --------------------------------------------------------------
[ -f "$WORKSPACE/Makefile" ] || die "Makefile missing - wrong repo?"
mkdir -p "$ART/dist" "$HOME/op10-apple" "$HOME/op10-backup"
ok "created ~/op10-apple and ~/op10-backup"

say "make targets"
( cd "$WORKSPACE" && make help 2>/dev/null | head -40 ) || warn "make help failed (deps not installed yet - normal)"

cat <<EOS

Next:
  powershell -ExecutionPolicy Bypass -File scripts\\run-wsl.ps1 -Script 03-host-deps.sh

If you want the reference-only repos as well (not needed to build):
  cd $WORKSPACE && make references
EOS
