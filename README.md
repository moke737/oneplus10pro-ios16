# 一加 10 Pro（NE2210）跑 iOS 16.7.16 —— 实战记录与工具

在**真机**一加 10 Pro（`negroni`，骁龙 8 Gen 1 / SM8450）上，从解锁的零售机启动苹果 XNU 内核
和 **iOS 16.7.16 用户态**，走的是 [UniXNU](https://github.com/UniXNU/UniXNU) 那套链路：

```
ABL → BootShim（ios-sweet）→ Mu-Silicium UEFI → UniXNU 菜单 → DarwinBoot → XNU → launchd → SpringBoard
```

**当前状态：能进 iOS 桌面。** 显示、触控、硬件键可用；GPU 驱动已开（`negroniadreno=22`），
但还需要 Metal→Vulkan 用户态库才有意义。Wi-Fi、蓝牙、音频、相机、蜂窝基带均未打通。
这是研究玩具，不是日用机。

> 手机会把自己伪装成 **iPhone X（`iPhone10,3` / D22AP）**。别在上面登真实 Apple ID。

---

## 这个仓库是什么

不是任何项目的 fork。它是**两个晚上**在 **NE2210（国行）/ ColorOS 17.0.0.155** 上折腾出来的
可复现部分——而上游那些移植都是在 **NE2211（印度）/ OxygenOS 16** 上验证的。
上游假定能用的配方，跨到这台机器上基本全部失效；这个仓库记录的是**真正能用的那一套**。

| 路径 | 内容 |
|---|---|
| `README.md` | 本文件 |
| `成功记录-iOS16桌面.md` | **可用配方** + 12 个坑的完整解法（推荐先看这个） |
| `事故记录-引导循环与恢复.md` | 无限重启的事后分析：slot 怎么被标 unbootable、怎么救 |
| `UniXNU-一加10Pro-可行性评估.md` | 可行性、架构、成本与风险评估 |
| `README-操作顺序.md` | 分阶段操作手册 |
| `scripts/oneclick.ps1` | 全流程自动化：WSL2 → 拉仓库 → 工具链 → UEFI → 内核 → ADT → boot.img |
| `scripts/00..05`、`90` | 各阶段单独脚本（自检、装 WSL、拉仓库、装依赖、构建、启动、备份） |
| `scripts/run-wsl.ps1` | 在 WSL 里跑 bash 阶段脚本（自动处理 CRLF） |
| `tools/compact-wsl-vhdx.ps1` | 压缩 WSL 的 `ext4.vhdx`（含 diskpart 拒绝稀疏盘的解法） |
| `一键执行.cmd` | 双击入口，串 `oneclick.ps1` |

## 仓库里**没有**什么

- 任何苹果文件：没有 IPSW、没有 DMG、没有 iOS 根镜像、没有 `kernel.macho`、没有 ADT；
- 原厂固件分区（`boot.img`、`vendor_boot.img`、`dtbo.img`、`vbmeta.img`、`uefi.img`）；
- 第三方源码树（UniXNU、ios-sweet、iOSPlus10、Mu-Silicium）——请从各自仓库拉。

`.gitignore` 强制挡住这些；构建产物和设备 dump 都留在本地。

---

## 真正能用的刷写配方

所有命令都在 **bootloader 的 fastboot** 里执行（不是 fastbootd）。只有最后两步有顺序要求。

```bash
# 1. iOS 根文件系统（11.3 GB sparse，HFS+，区分大小写、带日志）
fastboot flash userdata ios16-root.simg

# 2. 引导镜像：shim + Mu FD（补齐到 1 MiB）+ NEGRONIESP payload
fastboot flash boot_a dist/boot_a.img            # ANDROID! header v4

# 3. vendor_boot：只有 mainline DTB，vendor ramdisk 是空的
fastboot flash vendor_boot_a dist/vendor_boot_a.img

# 4. 擦掉 dtbo
fastboot erase dtbo_a

# 5. vbmeta：同时关闭 verity 和 verification
fastboot flash vbmeta_a vbmeta_flags3.img        # 256 字节，avbtool --flags 3

# 6. 激活
fastboot set_active a
fastboot reboot
```

首次启动：一加 logo → shim 自检（红屏，几秒）→ 黑屏 → **苹果 logo**（4–5 分钟数据迁移）→ 锁屏。

### 最关键的那一个字节

这台机器的 bootloader 虽然已解锁（`verifiedbootstate=orange`），但**只要 `vbmeta` 和刷进去的
`boot`/`vendor_boot` 不匹配，它就拒绝启动 slot A**——表现是直接退回 fastboot，试几次之后 ABL
会把槽位标成不可用：

```
slot-unbootable:a: yes
```

而 `fastboot --disable-verity --disable-verification flash vbmeta_a` **在 Windows 上必定失败**
（`GetTempFileName failed, error 5`），所以 vbmeta 必须提前生成：

```bash
python3 avbtool.py make_vbmeta_image --flags 3 --output vbmeta_flags3.img
```

`flags = 3` 表示关闭 verity（bit 0）+ 关闭 verification（bit 1）。一个带这两个标志的空 vbmeta
就能让 ABL 放行。

---

## 踩坑速查表

| 现象 | 原因 | 解法 |
|---|---|---|
| 红屏 shim 显示 `LOADER no SWEETXNU payload` | `fastboot boot` 传给内核的 initrd 是**已安装的** vendor_boot 里的 ramdisk（88 MB），不是我们镜像里的 67 MB，起始处没有 `_FVH` 签名 | 不要用 `fastboot boot`，改成刷分区 |
| 打 v2 header 的镜像 → 直接回 fastboot | 这个 ABL 只认 v4 | 用 v4 |
| 刷完 `vendor_boot_a` 后无限重启 | 端口的 vendor_boot **vendor ramdisk 为空**，Android 起不来 | `fastboot set_active a` 清 `slot-unbootable`，再刷回原厂镜像 |
| WSL 里 `unknown filesystem type 'hfsplus'` | WSL 内核没编 `CONFIG_HFSPLUS_FS` | 用 `/proc/config.gz` + 官方源码重编内核，开 `HFSPLUS_FS=y` |
| `apfs-fuse` 编译报 `No SOURCES given to target: lzfse` | 它的 lzfse 子模块要从 github.com 拉，被墙 | 用 `codeload.github.com` 下 tar 包塞进 `3rdparty/lzfse` |
| `setup-mu.sh` 卡在拉 OpenSSL 测试套件 | `--recursive` 会进 `wycheproof`、`krb5`、`gost-engine` | 改嵌套循环，跳过 OpenSSL 的测试子模块 |
| `patches/apply.sh: Illegal option -o pipefail` | 脚本用 `sh`（dash）调了 bash 脚本 | 改成 `bash patches/apply.sh` |
| `patch does not apply` | 固定的 `Mu_Basecore` fork 已经自带该补丁 | apply 改幂等（正向失败就反向检查后跳过） |
| E: 盘 20 分钟被写满 | WSL 的 `ext4.vhdx` 只涨不缩 | `tools/compact-wsl-vhdx.ps1`（先清 NTFS 稀疏标记，否则 diskpart 会拒绝） |

完整过程见 `成功记录-iOS16桌面.md` 和 `事故记录-引导循环与恢复.md`。

---

## 自己构建（Windows + WSL2）

需要：WSL2、WSL 所在盘约 60 GB 空闲、一台已解锁的手机、一个 GitHub 账号
（内核来自 GitHub Actions artifact）、一根能在 fastboot 下工作的线。

```powershell
# 0. 主机自检（只读）
powershell -ExecutionPolicy Bypass -File scripts\00-check-env.ps1

# 1. 装 WSL2 + Ubuntu 24.04（要管理员 + 重启一次）
powershell -ExecutionPolicy Bypass -File scripts\01-install-wsl.ps1

# 2. 拉 iOSPlus10 + 子模块，装主机依赖
powershell -ExecutionPolicy Bypass -File scripts\run-wsl.ps1 -Script 02-setup-repos.sh
powershell -ExecutionPolicy Bypass -File scripts\run-wsl.ps1 -Script 03-host-deps.sh

# 3. 构建 UEFI + 内核 + ADT + boot 镜像
powershell -ExecutionPolicy Bypass -File scripts\run-wsl.ps1 -Script 04-build.sh -ScriptArgs "--steps","boottest"

# 4. 非破坏性启动测试（不写任何分区）
powershell -ExecutionPolicy Bypass -File scripts\05-boot.ps1
```

或者直接双击 `一键执行.cmd`——它把上面全部串起来，并且能跨重启续跑
（阶段号存在 `state/phase.txt`，用 RunOnce 自动恢复）。

**iOS 根镜像**这一步没有自动化，因为它需要 `apfs-fuse`、`hfsprogs` 和带 HFS+ 支持的内核；
具体步骤在 `成功记录-iOS16桌面.md` 第一节，WSL 内核重编见踩坑表。

环境变量：`UNIXNU_ARTIFACTS` 覆盖产物目录（默认仓库根），`ANDROID_TOOLS` 指向 platform-tools。

---

## 回到 Android

Slot A 的引导链已被替换，`userdata` 也写成了 iOS 根。要回去必须用**和手机完全同版本**的固件
（NE2210 的 ColorOS 17.0.0.155）——用别的构建的镜像会 bootloop，这台机器上就吃过一次亏。
然后刷 `boot`/`vendor_boot`/`dtbo`/`vbmeta`，`set_active a`，最后 `fastboot -w`。

仓库**不提供**原厂镜像，请从你自己的 OTA 里取。

---

## 致谢

- [UniXNU](https://github.com/UniXNU/UniXNU) —— UEFI 启动管理器与 DarwinBoot
- [ios-sweet](https://github.com/dipa-studio/ios-sweet) —— XNU on Qualcomm 的血统与 shim
- [iOSPlus10](https://github.com/akshaynexus/iOSPlus10) —— 本仓库构建所用的 negroni 工作区
- [pawlickerr/UniXNU-negroni](https://github.com/pawlickerr/UniXNU-negroni) —— 最早的 negroni 板级文件
- [Mu-Silicium](https://github.com/Project-Silicium/Mu-Silicium) —— UEFI 固件
- 苹果开源的 XNU、IOHIDFamily、libpthread、hfs

## 赞赏

如果这些记录帮你省掉了一个晚上，可以扫这个码：

<img src="assets/tip-moke.png" width="200" alt="莫珂 的赞赏码">

微信 / 支付宝均可。

## 法律声明

仅供研究与互操作参考。本仓库不分发任何苹果代码或二进制，iOS 本身归苹果所有。
刷机会替换引导链并清空 `userdata`——请用备用机。本项目与苹果、高通、OPPO/一加及上游项目无关。

本仓库内的文件采用 MIT 许可（见 `LICENSE`），上游组件遵循各自许可。

---

<details>
<summary><b>English abstract</b></summary>

Booting Apple's XNU kernel and the iOS 16.7.16 userland on a real OnePlus 10 Pro
(`negroni`, SM8450) via the UniXNU stack (ios-sweet shim → Mu-Silicium UEFI → DarwinBoot → XNU).
Status: reaches the iOS SpringBoard; display/touch/keys work, Wi-Fi/BT/audio/camera/cellular do not.

This repository is the reproducible part of a NE2210 / ColorOS 17.0.0.155 bring-up — the upstream
ports were validated on NE2211 / OxygenOS 16, and their recipe does not carry over. It contains the
field notes and the tooling, **not** Apple binaries or vendor firmware.

The one non-obvious step: the bootloader is unlocked but still refuses slot A unless `vbmeta` matches
the flashed `boot`/`vendor_boot`; `--disable-verity` fails on Windows, so generate
`avbtool make_vbmeta_image --flags 3` and flash that instead.

</details>
