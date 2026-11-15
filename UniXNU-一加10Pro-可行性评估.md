# 一加 10 Pro 跑 iOS —— 可行性评估（v2，已核对上游源码）

> 评估对象：https://github.com/UniXNU/UniXNU 及其 negroni（一加 10 Pro，SM8450）社区移植
> 目标机：OnePlus 10 Pro 5G / **NE2210**（国行，ColorOS 17 / Android 17，BL 已解锁）
> 硬约束：**Android 数据必须保留**
> 核对时间：2026-11-15，已拉取 upstream 的 `board.toml`、README 与 iOSPlus10 全部关键文档

---

## 1. 结论（v2 修正版）

| 问题 | 答案 |
|---|---|
| 能移植吗 | **不用移植**，两条现成的 negroni 移植都已在真机跑到 iOS 桌面 |
| 能启动 iOS 吗 | **能**：iOS 16.7.16，iPhone X（`iPhone10,3`/D22AP）身份，SpringBoard 桌面、触控、硬件键可用 |
| 你这台能照做吗 | **有条件**：型号是 NE2210，别人验证的是 NE2211/NE2213；你是 ColorOS 17（Android 17），他们验证的是 OxygenOS 16，ABL 更新，风险更高 |
| 能保留 Android 数据吗 | ❌ **不能**（这是本次评估最重要的修正）。iOS 根是一块 **11.6 GB 的 HFS+ 镜像，必须写进 `userdata` 分区**，官方 restore 流程就是 `fastboot -w`（格式化 userdata） |
| 能当日常机吗 | ❌ 不能。无 Wi-Fi/蓝牙/基带/音频/相机/App Store/Apple ID，安全模型基本关闭，作者明确写"别放任何私人数据" |
| 项目状态 | pawlickerr 的移植是个人 bring-up 树（作者自述 80% AI 生成）；akshaynexus/iOSPlus10 **已暂停，作者的 10 Pro 已卖掉**，仓库只作参考保留 |

**一句话**：技术上确实能在这台机器上跑 iOS 16，但要跑起来就必须清空 Android 数据；你的"保留数据"约束和"进桌面"是互斥的。

---

## 2. 关键事实核对（都有源码出处）

### 2.1 这两条线根本不是 UniXNU 标准构建链

UniXNU 官方文档教的是 `./unixnu defconfig → fetch → build kernel/package/firmware → bootimg`。
但 negroni 的 `board.toml` 写的是另一套：

```toml
[firmware]
tree = "~/ios-work/Mu-Silicium"        # 作者本机路径
shim = "uefi/negroni/shim-mu.sh"
[kernel]
repo = "MellysInformejtik/slop"        # 第三方仓库的 CI
workflow = "negroni-ios"
artifact = "negroni-ios-kernel"
[payload]
volume = "NEGRONIESP"
kernel_args = ["rd=ufsroot0", "ufsrw=1", "rootrw=1", ...]
[tools]
fastboot = "/mnt/c/Users/paw/scoop/shims/fastboot.exe"   # 作者的 Windows 路径
python   = "~/ios-work/mu-venv/bin/python"
```

也就是说：pawlickerr 的仓库是 **ios-sweet 血统**（dipa-studio 的红米 Note 10 Pro 移植）的设备层，内核由 GitHub Actions 在 macOS runner 上编，根文件系统在 Linux 上用 `apfs-fuse + hfsprogs` 从 IPSW 合成。**不能直接 `./unixnu build`。**

### 2.2 iOSPlus10 才是能用的一条线

`akshaynexus/iOSPlus10` 把整条链做成了 Makefile（Linux/macOS 双支持）：

```
make tools / op10tool / image         一次性环境
make mu        → Mu-Silicium UEFI（容器内 EDK2 构建）
make kernel    → 从 slop 的 CI 下载 xnu-8796 mach-o
make devicetree→ d22ap.adt
make boot      → out/ios16/boot_a.img + vendor_boot_a.img
make dmgs/root/simg → ~/op10-apple/ios16-root.simg (11.6 GB)
make flash CONFIRM=yes
```

而且它做了 pawlickerr 没做的：Metal2Vulkan GPU（A730）、Wi-Fi/蓝牙/电池修复、USB 实时日志（`negroniusb=2`，手机变 CDC-ECM 网卡往 `192.168.7.1:5140` 发日志）。

### 2.3 为什么"保留数据"做不到

| 环节 | 事实 |
|---|---|
| 根文件系统 | `ios16-root.simg`，**11.6 GB**，HFS+ |
| 写入位置 | `fastboot flash userdata`（fastbootd 里分 45 段发，因为手机单次最多 256 MiB） |
| 内核挂载点 | boot-arg `rd=ufsroot0 ufsrw=1 rootrw=1` —— 根设备写死在 userdata |
| 官方回退 | `make flash-restore` = 刷回 stock boot/vendor_boot/dtbo/vbmeta + **`fastboot -w`（格式化 userdata）** |
| 备份文档 | 明确写 *"Not in the backup: user data"* —— 项目自己的备份**不含** userdata |
| UniXNU 的 `unixnu` 分区方案 | 实验性，官方文档原话："Image-builder and UFS-driver configuration remain separate tasks" —— 需要改内核根设备映射，作者没做 |

结论：想保住 Android 数据又要进桌面，**必须自己改内核/UFS 驱动把根指向另一个分区**，这不是配置活，是开发活，且没有先例。

---

## 3. 你的机器 vs 作者机器

| 项 | iOSPlus10 作者 | 你 | 影响 |
|---|---|---|---|
| 型号 | NE2211（印度） | **NE2210**（国行） | `config/negroni-ne2211.toml` 要改型号/可能触摸节点 |
| 系统 | OxygenOS 16.0.3.530 / Android 16 | **ColorOS 17 / Android 17** | ⚠️ 文档已列风险："OxygenOS 16 的 ABL 可能拒绝 header-v4 shim"，你比它更新 |
| SoC / RAM / UFS | SM8450 / 12 GB / 256 GB | 同 | ✅ 一致 |
| BL | 已解锁（`flash.locked=0`，verified boot orange） | 已解锁 | ✅ |
| 槽位 | 只写 A 槽，B 槽保持 stock | 同 | ✅ 留了退路 |
| 反回滚 | ARB index 0 | 未知，需查 | ⚠️ 若 ARB 被抬高，刷写风险变大 |

---

## 4. 现在能做的三件事（按风险从低到高）

### 方案 A：完全不写分区，只看能不能亮（风险最低，收益也最低）

`fastboot boot` 从内存加载 boot 镜像，不动任何分区。但：

- 没有 iOS 根 → XNU 会在挂载根文件系统时失败，**到不了桌面**；
- 这个移植的 shim 依赖 ABL 传入的 live DTB 和 vendor_boot 里的 mainline DTB，`fastboot boot` 能不能走通**没有文档保证**；
- 收益：确认 UEFI 菜单 + 内核早期日志 + 你的 NE2210 触摸/面板是否被识别。

适合"先看看，不冒险"。

### 方案 B：全量备份 userdata 后刷，玩完再灌回去

唯一"理论上能回到今天状态"的路，但项目没验证过：

1. TWRP 里 dd 出 `userdata` + `metadata`（256 GB 机器上 userdata 可能 200 GB+，按 25 MB/s 要 2 小时以上，还要一块同样大的盘）；
2. `make flash CONFIRM=yes`（会清空 userdata）；
3. 回退：`make flash-restore` → 再把 dd 出来的 `userdata` + `metadata` 原样写回。

风险：F2FS 元数据/加密 key 对不上就解不开；`metadata` 必须同版本同状态；恢复耗时又是一遍 dd。**这不是官方支持路径。**

### 方案 C：搞一台备用机（最稳）

闲鱼上战损的一加 10 Pro（屏幕坏的）三四百块。你的主力机数据一点不动，随便刷。考虑到"数据必须保留"是硬约束，这是唯一不赌的方案。

---

## 5. 成本估算（不管哪个方案，构建都要走一遍）

| 阶段 | 内容 | 时间 |
|---|---|---|
| 环境 | WSL2 Ubuntu 24.04 / 或原生 Linux；apt 依赖；Rust；Docker | 0.5 天 |
| 工具 | `make tools` `make op10tool` `make image` | 1–2 h |
| UEFI | `make mu`（EDK2 容器构建） | 1–2 h |
| 内核 | `make kernel`（从 slop 的 GitHub Actions 下 artifact，**需要一个 GitHub 账号**） | 20 min |
| 引导 | `make devicetree` `make boot` | 20 min |
| 根镜像 | `make dmgs`（下载 3 个 dmg）+ `make root`（sudo，apfs-fuse，15 GB raw） | 1–2 h |
| 刷写 | `make flash` | 1 h（11.6 GB / 45 段） |
| 首次开机 | Apple logo 数据迁移 | 4–5 min |

磁盘：**60–80 GB** 空闲（root raw 15 GB + simg 12 GB + 容器镜像 + IPSW）。

---

## 6. 明确做不到的（引用作者原话）

- ❌ Wi-Fi、蓝牙、蜂窝、音频、相机、传感器、GPS、SEP / Face ID
- ❌ GPU 硬件加速（iOSPlus10 用 Metal2Vulkan 绕，属于实验路径；原版是纯 CPU 20–30 fps）
- ❌ App Store / Apple ID
- ❌ 从 app 里退出的手势（home 手势无效）
- ❌ 安全：AMFI 宽松、Sandbox 宽松、AppleKeyStore 是桩、无数据保护 —— "Do not put anything personal on it"

---

## 7. 参考资料

- 主仓库：https://github.com/UniXNU/UniXNU ｜文档：https://unixnu.com
- 设备页：https://unixnu.com/zh/devices/negroni
- pawlickerr 设备层（ios-sweet 血统）：https://github.com/pawlickerr/UniXNU-negroni
- pawlickerr UEFI：https://github.com/pawlickerr/Mu-Silicum-negroni
- **推荐路线**：https://github.com/akshaynexus/iOSPlus10
  - `docs/setup-linux.md` / `docs/build-ios16.md` / `docs/flash-ios16.md` / `docs/backup-and-restore.md`
- ios-sweet 上游（能力边界的最诚实描述在这里）：https://github.com/dipa-studio/ios-sweet
