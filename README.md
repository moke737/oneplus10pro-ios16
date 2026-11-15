**English** | [简体中文](README.zh-CN.md)

# iOS 16.7.16 on a OnePlus 10 Pro (NE2210) — field notes and tooling

Booting Apple's XNU kernel and the **iOS 16.7.16 userland on real OnePlus 10 Pro hardware**
(`negroni`, Snapdragon 8 Gen 1 / SM8450), from a stock-unlocked retail phone, through the
[UniXNU](https://github.com/UniXNU/UniXNU) stack:

```
ABL → BootShim (ios-sweet) → Mu-Silicium UEFI → UniXNU menu → DarwinBoot → XNU → launchd → SpringBoard
```

**Status: boots to the iOS desktop.** Display, touch and hardware keys work. The GPU driver is
enabled (`negroniadreno=22`) but needs a Metal→Vulkan userland to be useful. Wi-Fi, Bluetooth,
audio, camera and cellular are not up. This is a research toy, not a daily driver.

> The phone presents itself as an **iPhone X (`iPhone10,3` / D22AP)**. Do not sign in with a real
> Apple ID on it.

---

## What this repository is

Not a fork of anything. It is the **reproducible part** of a two-evening bring-up on a
**NE2210 (China) / ColorOS 17.0.0.155** device, where the upstream ports were validated on
**NE2211 (India) / OxygenOS 16**. The upstream recipe does not survive that jump; this repo
records what actually does.

| Path | Contents |
|---|---|
| `README.md` | this file |
| `README.zh-CN.md` | 中文版（Chinese version） |
| `成功记录-iOS16桌面.md` | **the working recipe** + 12 pitfalls with fixes (Chinese) |
| `事故记录-引导循环与恢复.md` | bootloop post-mortem: how slot A gets marked unbootable, and how to recover (Chinese) |
| `UniXNU-一加10Pro-可行性评估.md` | feasibility, architecture, cost and risk analysis (Chinese) |
| `README-操作顺序.md` | step-by-step runbook (Chinese) |
| `scripts/oneclick.ps1` | end-to-end automation: WSL2 → repos → toolchain → UEFI → kernel → ADT → boot.img |
| `scripts/00..05`, `90` | individual stages (host check, WSL install, repos, deps, build, boot, backup) |
| `scripts/run-wsl.ps1` | runs a bash stage inside WSL with LF normalization |
| `tools/compact-wsl-vhdx.ps1` | shrink a WSL `ext4.vhdx` (the sparse-flag catch that breaks diskpart) |
| `一键执行.cmd` | double-click entry point for `oneclick.ps1` |

The detailed field notes are written in Chinese; the code, scripts and this README are English.

## What is **not** in this repository

- Apple binaries of any kind: no IPSW, no DMGs, no iOS root image, no `kernel.macho`, no ADT.
- Vendor firmware partitions (`boot.img`, `vendor_boot.img`, `dtbo.img`, `vbmeta.img`, `uefi.img`).
- Third-party source trees (UniXNU, ios-sweet, iOSPlus10, Mu-Silicium) — fetch them from their own repos.

`.gitignore` enforces this; build artifacts and device dumps stay local.

---

## The flash recipe that works

All commands run in **bootloader fastboot** (not fastbootd). Only the last two steps are order-sensitive.

```bash
# 1. iOS root filesystem (11.3 GB sparse, HFS+, case-sensitive, journaled)
fastboot flash userdata ios16-root.simg

# 2. boot image: shim + Mu FD (padded to 1 MiB) + NEGRONIESP payload
fastboot flash boot_a dist/boot_a.img            # ANDROID! header v4

# 3. vendor_boot: mainline DTB only, empty vendor ramdisk
fastboot flash vendor_boot_a dist/vendor_boot_a.img

# 4. erase dtbo
fastboot erase dtbo_a

# 5. vbmeta with verity AND verification disabled
fastboot flash vbmeta_a vbmeta_flags3.img        # 256 bytes, avbtool --flags 3

# 6. activate
fastboot set_active a
fastboot reboot
```

First boot: OnePlus logo → shim self-test (red screen, a few seconds) → black → **Apple logo**
(4–5 minutes of data migration) → lock screen.

### The one byte that mattered

The bootloader on this firmware is unlocked (`verifiedbootstate=orange`) but **still refuses to boot
slot A when `vbmeta` does not match the flashed `boot`/`vendor_boot`** — the phone falls back to
fastboot, and after a few attempts ABL marks the slot unbootable:

```
slot-unbootable:a: yes
```

`fastboot --disable-verity --disable-verification flash vbmeta_a` **fails on Windows** with
`GetTempFileName failed, error 5`, so the vbmeta has to be generated ahead of time:

```bash
python3 avbtool.py make_vbmeta_image --flags 3 --output vbmeta_flags3.img
```

Flags `3` = disable verity (bit 0) + disable verification (bit 1). An empty vbmeta carrying those
flags is accepted and the slot boots.

---

## Hard-won details

| Symptom | Cause | Fix |
|---|---|---|
| `LOADER no SWEETXNU payload` on a red shim screen | `fastboot boot` passes the **installed** vendor_boot's ramdisk as initrd (88 MB) instead of our 67 MB one; the `_FVH` signature is not at the start | flash partitions instead of `fastboot boot` |
| header v2 image → straight back to fastboot | this ABL only accepts v4 | build v4 |
| infinite reboot after flashing `vendor_boot_a` | the port's vendor_boot has an **empty vendor ramdisk**; Android cannot boot | `fastboot set_active a` clears `slot-unbootable`, then restore the stock image |
| `unknown filesystem type 'hfsplus'` in WSL | WSL kernel has `CONFIG_HFSPLUS_FS` unset | rebuild the WSL kernel from `microsoft/WSL2-Linux-Kernel` with `/proc/config.gz` and `HFSPLUS_FS=y` |
| `apfs-fuse` build: `No SOURCES given to target: lzfse` | its submodule is cloned from github.com, which is blocked | fetch `lzfse` via `codeload.github.com` tarball |
| `setup-mu.sh` stuck cloning OpenSSL test suites | `--recursive` descends into `wycheproof`, `krb5`, `gost-engine` | patch the nested loop, skip OpenSSL's test submodules |
| `patches/apply.sh: Illegal option -o pipefail` | invoked with `sh` (dash) | call it with `bash` |
| `patch does not apply` | the pinned `Mu_Basecore` fork already contains the patch | make the apply idempotent (forward check, then reverse check) |
| E: drive filled up in 20 minutes | the WSL `ext4.vhdx` grows and never shrinks | `tools/compact-wsl-vhdx.ps1` (clear the NTFS sparse flag first — diskpart refuses sparse VHDs) |

Full write-ups (Chinese) in `成功记录-iOS16桌面.md` and `事故记录-引导循环与恢复.md`.

---

## Build it yourself (Windows + WSL2)

Requirements: WSL2, ~60 GB free on the drive that holds the WSL distro, an unlocked phone,
a GitHub account (the kernel comes from a GitHub Actions artifact), and a cable that works in
fastboot mode.

```powershell
# 0. preflight (read-only)
powershell -ExecutionPolicy Bypass -File scripts\00-check-env.ps1

# 1. install WSL2 + Ubuntu 24.04 (needs admin + one reboot)
powershell -ExecutionPolicy Bypass -File scripts\01-install-wsl.ps1

# 2. clone iOSPlus10 + submodules, install host dependencies
powershell -ExecutionPolicy Bypass -File scripts\run-wsl.ps1 -Script 02-setup-repos.sh
powershell -ExecutionPolicy Bypass -File scripts\run-wsl.ps1 -Script 03-host-deps.sh

# 3. build UEFI + kernel + ADT + boot image
powershell -ExecutionPolicy Bypass -File scripts\run-wsl.ps1 -Script 04-build.sh -ScriptArgs "--steps","boottest"

# 4. non-destructive boot test (writes nothing)
powershell -ExecutionPolicy Bypass -File scripts\05-boot.ps1
```

Or double-click `一键执行.cmd` — it chains everything and resumes across reboots (state in
`state/phase.txt`, relaunched via a RunOnce entry).

The iOS **root image** step is not automated here: it needs `apfs-fuse`, `hfsprogs` and a kernel
with HFS+ support. The exact sequence is in `成功记录-iOS16桌面.md` §1 and the WSL kernel rebuild
is described in the pitfalls table.

Environment overrides: `UNIXNU_ARTIFACTS` for the artifact directory (defaults to this repo's root),
`ANDROID_TOOLS` for platform-tools.

---

## Restoring Android

Slot A's boot chain is replaced and `userdata` now holds the iOS root. Going back needs the
**exact same firmware build** as the phone (ColorOS 17.0.0.155 for NE2210) — images from a different
build bootloop, which cost an evening here. Then flash `boot`/`vendor_boot`/`dtbo`/`vbmeta`,
`set_active a`, and `fastboot -w`.

The stock images used during bring-up are deliberately not published; pull them from your own OTA.

---

## Credits

- [UniXNU](https://github.com/UniXNU/UniXNU) — UEFI boot manager and DarwinBoot
- [ios-sweet](https://github.com/dipa-studio/ios-sweet) — the XNU-on-Qualcomm lineage and the shim
- [iOSPlus10](https://github.com/akshaynexus/iOSPlus10) — the negroni workspace this builds on
- [pawlickerr/UniXNU-negroni](https://github.com/pawlickerr/UniXNU-negroni) — the first negroni board files
- [Mu-Silicium](https://github.com/Project-Silicium/Mu-Silicium) — UEFI firmware
- Apple's open-source XNU, IOHIDFamily, libpthread, hfs

## Support

If these notes saved you an evening of debugging, you can scan this code:

<img src="assets/tip-moke.png" width="200" alt="莫珂 的赞赏码">

WeChat / Alipay.

## Legal

For research and interoperability. No Apple code or binaries are distributed here; iOS itself is
Apple's. Flashing replaces your boot chain and erases `userdata` — do it on a spare device.
Nothing here is endorsed by Apple, Qualcomm, OPPO/OnePlus or the upstream projects.

MIT licensed (see `LICENSE`) for the files in this repository; upstream components keep their own
licenses.
