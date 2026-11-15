#!/usr/bin/env bash
# 04-build.sh - drive the iOSPlus10 Makefile from Windows.
#
# Run from Windows:
#   powershell -ExecutionPolicy Bypass -File scripts\run-wsl.ps1 -Script 04-build.sh
#   ... -Script 04-build.sh -ScriptArgs "--steps","mu kernel devicetree"
#   ... -Script 04-build.sh -ScriptArgs "--steps","flash","--yes"
#
# Steps (groups in brackets):
#   tools op10tool image mu kernel devicetree boot dmgs root simg
#   [setup]  = tools op10tool image
#   [boottest] = tools op10tool image mu kernel devicetree boot   <- non-destructive route
#   [chain]  = mu kernel devicetree boot
#   [rootfs] = dmgs root simg
#   [flash]  = flash            (writes userdata: ERASES ANDROID DATA, needs --yes)
#   [flashboot] = flash-boot    (boot image only, keeps userdata)
#   [restore]   = flash-restore (stock + fastboot -w)
#   status
#
# Options:
#   --steps "a b c"   default: tools op10tool image
#   --yes             required for flash / restore
#   --dry-run         print the make commands only

set -euo pipefail

WORKSPACE="${IOSPLUS10_DIR:-$HOME/iOSPlus10}"
LOG="$WORKSPACE/logs"
STEPS="tools op10tool image mu kernel devicetree boot"
YES=0
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --steps)   STEPS="${2:?}"; shift 2 ;;
    --yes)     YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *)         printf '[FAIL] unknown option: %s\n' "$1"; exit 2 ;;
  esac
done

mkdir -p "$LOG"
say()  { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '  [OK] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
die()  { printf '  [FAIL] %s\n' "$*"; exit 1; }

[ -d "$WORKSPACE" ] || die "missing $WORKSPACE - run 02-setup-repos.sh"
cd "$WORKSPACE"

# --- group expansion -----------------------------------------------------
EXPANDED=""
for s in $STEPS; do
  case "$s" in
    setup)     EXPANDED="$EXPANDED tools op10tool image" ;;
    boottest)  EXPANDED="$EXPANDED tools op10tool image mu kernel devicetree boot" ;;
    chain)     EXPANDED="$EXPANDED mu kernel devicetree boot" ;;
    rootfs)    EXPANDED="$EXPANDED dmgs root simg" ;;
    flash)     EXPANDED="$EXPANDED flash" ;;
    flashboot) EXPANDED="$EXPANDED flash-boot" ;;
    restore)   EXPANDED="$EXPANDED flash-restore" ;;
    *)         EXPANDED="$EXPANDED $s" ;;
  esac
done
STEPS="$EXPANDED"

# --- guards --------------------------------------------------------------
case " $STEPS " in
  *" flash "*|*" flash-restore "*)
    if [ "$YES" -ne 1 ]; then
      cat <<'EOS'
[STOP] flash writes userdata - Android's data is erased.
       Read UniXNU-一加10Pro-可行性评估.md section 2.3 first, back up, then re-run with:
           -ScriptArgs "--steps","flash","--yes"
EOS
      exit 3
    fi
    ;;
esac

run_make() {
  local target="$1"; shift
  local log="$LOG/manual-$target.log"
  say "make $target $*"
  if [ "$DRY" -eq 1 ]; then printf '  (dry-run) make %s %s\n' "$target" "$*"; return 0; fi
  if make "$target" "$@" 2>&1 | tee "$log"; then
    ok "$target"
    return 0
  fi
  local rc=${PIPESTATUS[0]}
  warn "$target FAILED (rc=$rc)"
  printf '\n---- last 30 lines of %s ----\n' "$log"
  tail -30 "$log" || true
  return "$rc"
}

# --- per-step specifics --------------------------------------------------
for s in $STEPS; do
  case "$s" in
    root)
      say "make root (needs sudo: apfs-fuse + hfsplus loop mount)"
      if [ "$DRY" -eq 1 ]; then echo '  (dry-run) sudo -E make root'; else
        sudo -E make root 2>&1 | tee "$LOG/manual-root.log" || die "make root failed - see $LOG/manual-root.log"
        ok "root"
      fi
      ;;
    flash)
      run_make flash CONFIRM=yes
      ;;
    flash-boot)
      run_make flash-boot CONFIRM=yes
      ;;
    flash-restore)
      run_make flash-restore CONFIRM=yes
      ;;
    status)
      make status || true
      ;;
    *)
      run_make "$s" || die "step '$s' failed - see $LOG/manual-$s.log"
      ;;
  esac
done

# --- collect artifacts ---------------------------------------------------
ART="${UNIXNU_ARTIFACTS:-$(cd "$(dirname "$0")/.." && pwd)}"
mkdir -p "$ART/dist"
say "collecting artifacts"
shopt -s nullglob
for f in out/ios16/boot_a.img out/ios16/vendor_boot_a.img out/ios16/esp.img out/ios16/negroni.adt out/kernel/kernel.macho; do
  if [ -f "$f" ]; then cp -f "$f" "$ART/dist/$(basename "$f")"; ok "$(basename "$f") -> dist/"; fi
done
for f in "$HOME/op10-apple/ios16-root.simg"; do
  if [ -f "$f" ]; then printf '  [note] %s (%s) stays in %s - too big to copy\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)" "$HOME/op10-apple"; fi
done

cat <<EOS

Non-destructive boot test (does not write any partition):
  powershell -ExecutionPolicy Bypass -File scripts\\05-boot.ps1

Full flash (erases userdata):
  -ScriptArgs "--steps","flash","--yes"
EOS
