# 成功记录：OnePlus 10 Pro (NE2210) 跑起 iOS 16.7.16

**时间**：2026-11-16 00:40
**结果**：开机 → Apple logo → 数据迁移 → **iOS 桌面（SpringBoard）**
**机型**：NE2210（国行，ColorOS 17.0.0.155 / Android 17），代号 negroni，SM8450
**身份**：iPhone X（iPhone10,3 / D22AP），iOS 16.7.16 (20H392)
**性质**：备用机，userdata 已清空并写入 iOS 根，Slot A 已改为 iOS 引导

---

## 一、最终可用的刷写顺序

> 全部在 **bootloader fastboot**（不是 fastbootd）里执行。前四步可任意顺序，最后 `set_active a` 必须最后。

```powershell
# 1. iOS 根文件系统 → userdata（11.3 GB sparse，16 段，约 5.5 分钟）
fastboot flash userdata D:\op10\ios16-root.simg

# 2. 引导镜像（shim + Mu FD + ESP payload）
fastboot flash boot_a      dist\boot_a.img          # 67 MB, ANDROID! v4
fastboot flash vendor_boot_a dist\vendor_boot_a.img # 184 KB, 仅 mainline DTB

# 3. 擦掉 dtbo（端口要求）
fastboot erase dtbo_a

# 4. vbmeta：关闭 verity + verification
#    ⚠️ 关键：Windows 上 `fastboot --disable-verity --disable-verification flash`
#       会失败（GetTempFileName error 5），必须用 avbtool 预生成：
#       python3 avbtool.py make_vbmeta_image --flags 3 --output vbmeta_flags3.img
fastboot flash vbmeta_a   inputs\vbmeta_flags3.img  # 256 字节, Flags: 3

# 5. 激活并重启
fastboot set_active a
fastboot reboot
```

首次启动：OnePlus logo → 红屏 shim 自检（几秒）→ 黑屏 → **Apple logo** → 4–5 分钟数据迁移 → 锁屏/桌面。

---

## 二、踩过的坑（每条都真实卡过一次）

| # | 现象 | 根因 | 解法 |
|---|---|---|---|
| 1 | shim 红屏 `LOADER no SWEETXNU payload` | `fastboot boot` 传的 initrd 是已安装 vendor_boot 里的 stock ramdisk（88 MB ≠ 我们的 67 MB），起始处没有 `_FVH` | 不能靠 `fastboot boot`，必须**刷分区**走正常启动路径 |
| 2 | `fastboot boot` v2 镜像直接回 fastboot | ABL 不接受 v2 | 用 v4 |
| 3 | 刷完 vendor_boot_a 后 Android 无限重启 | 端口的 vendor_boot 只有 DTB、**vendor ramdisk 为空**，Android 起不来；ABL 把 slot A 标 `unbootable` | `fastboot set_active a` 清标记 + 刷回原厂 vendor_boot |
| 4 | 全套原厂镜像刷回后仍 bootloop | ColorOS17 包里的 `boot/dtbo` 与机器上的 17.0.0.155 **不是同一构建** | 备用机可放弃 Android；要保留 Android 就不能这么换 |
| 5 | WSL 编根镜像失败 `unknown filesystem type 'hfsplus'` | WSL 内核 `CONFIG_HFSPLUS_FS` 未设 | 用 `/proc/config.gz` + 官方源码重编内核（`HFSPLUS_FS=y`），`.wslconfig` 指定 `kernel=` |
| 6 | `make root` 卡在 `modprobe hfsplus` | HFS+ 编进内核后没有模块，脚本 `set -e` 直接退出 | 改成 `modprobe hfsplus 2>/dev/null || true` |
| 7 | `apfs-fuse` 编不过 `No SOURCES given to target: lzfse` | 它的 lzfse 子模块走 github.com 拉不下来 | 用 `codeload.github.com/lzfse/lzfse/tar.gz/...` 下 tar 包塞进 `3rdparty/lzfse` |
| 8 | `setup-mu.sh` 死循环拉 OpenSSL 测试套件（wycheproof/krb5/gost） | `--recursive` 会进 openssl 的测试子模块 | 补丁：从嵌套循环里去掉 openssl，并把 libspdm 的 crypto 子模块设 `update none` |
| 9 | `patches/apply.sh: Illegal option -o pipefail` | `setup-mu.sh` 用 `sh` 调了 bash 脚本 | 改成 `bash patches/apply.sh` |
| 10 | `patch does not apply` | Mu_Basecore 的 fork HEAD 已自带补丁 | apply 改成幂等（正向失败则反向检查后跳过） |
| 11 | `github.com` 时通时不通 | 网络 | git `insteadOf` → `gitclone.com`；raw 走 `ghproxy.net`；gh 走 Clash 代理 |
| 12 | E: 盘写满 | WSL vhdx 因根镜像膨胀 | 根镜像产物落 `/mnt/e`，simg 拷到 D: 再刷 |

---

## 三、关键数据

| 项 | 值 |
|---|---|
| `boot_a.img` | 67 MB，`ANDROID!` v4，kernel=shim(184 KB)，ramdisk=FD(3 MiB)+ESP(64 MiB)=67 MiB |
| `vendor_boot_a.img` | 184 KB，仅 DTB，**vendor ramdisk 为空** |
| `vbmeta_a` | 256 B，`avbtool make_vbmeta_image --flags 3` |
| `userdata` 根 | `ios16-root.img` 17.18 GB HFS+（case-sensitive, journaled）→ `simg` 11.3 GB |
| 内核 cmdline | `... negroniusb=2 negronifb_hz=120 negroniadreno=22 negronigpu_pool=1536 ...` |
| iOS 根内容校验 | `/sbin/launchd` 541600 B、`SystemVersion.plist` ProductBuildVersion `20H392` |

---

## 四、回 Android（如果以后要）

当前 slot A 的引导已被替换，Android 无法启动（userdata 也被 iOS 根覆盖）。

要回 Android 需要：

1. 用**与机器完全同版本**的 17.0.0.155 完整 OTA 里的 `boot/vendor_boot/dtbo/vbmeta`（不能用别的构建包，坑 #4）；
2. `fastboot flash` 四个分区 + `fastboot set_active a`；
3. `fastboot -w` 清 userdata（或恢复之前 dd 的 userdata 镜像）；
4. 重启。

原厂镜像已抽在 `inputs\`：`boot.img` `vendor_boot.img` `dtbo.img` `vbmeta.img`（来自 ColorOS17 正式版包，**与 17.0.0.155 不完全匹配**，仅作应急）。

---

## 五、后续可玩

- 触控/按键/HID：`negronikeys=1 negronitouch=1`
- GPU：`negroniadreno=22` 已开，但需要 Metal2Vulkan 用户态库；否则走 CPU 渲染
- 亮度/音频/Wi-Fi（QCA6490）/蓝牙：端口文档标注均未通
- 内核日志：`negroniusb=2` 会把日志从 USB CDC-ECM 发到 `192.168.7.1:5140`；
  Windows 缺 CDC-ECM 驱动（Code 28），要抓日志需 `usbipd` 把设备透传进 WSL（Linux 自带 `cdc_ether`）
