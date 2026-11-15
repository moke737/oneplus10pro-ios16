# 一加 10 Pro（NE2210）跑 iOS 16 —— 操作手册 v3（方案 A：非破坏性）

配套评估：[UniXNU-一加10Pro-可行性评估.md](UniXNU-一加10Pro-可行性评估.md)
上游主线：[akshaynexus/iOSPlus10](https://github.com/akshaynexus/iOSPlus10)

**本次执行方案：A —— 只 `fastboot boot`，不写任何分区。**
不需要 TWRP，不需要备份 userdata，不需要 iOS 根镜像（所以到不了桌面，这是预期内的）。

---

## 一键脚本（推荐）

双击 **`一键执行.cmd`** 就行。

它把下面 5 个阶段串起来，**并且能断点续跑**（阶段记在 `state\phase.txt`，重启/断电后重新双击会接着走）：

```
0 主机自检 → 装 WSL2（要管理员 + 重启）
1 验证发行版
2 拉 iOSPlus10 + 装依赖 + 起 docker
3 逐 step 跑 make，并按产物轮询（防 make 把长任务丢进 tmux 后提前返回）
4 提示你把手机进 bootloader → fastboot boot
5 汇总结论
```

**物理上绕不过去的 4 个人工点**（脚本会停下来等你）：

| 停顿点 | 为什么 | 你要做什么 |
|---|---|---|
| UAC 提权 | 装 WSL2 必须管理员 | 点"是" |
| 重启 | WSL2 内核/功能要重启生效 | 回车重启；重登后脚本会通过 RunOnce 自动续跑 |
| `gh auth login` | 内核从 GitHub Actions artifact 下 | 浏览器里授权一次 |
| 手机进 bootloader | `fastboot boot` 前设备必须在 fastboot 模式 | 按提示按键 |

可选参数：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\oneclick.ps1 -Proxy http://127.0.0.1:7890
powershell -ExecutionPolicy Bypass -File scripts\oneclick.ps1 -SkipBoot
powershell -ExecutionPolicy Bypass -File scripts\oneclick.ps1 -Reset        # 从头再来
powershell -ExecutionPolicy Bypass -File scripts\oneclick.ps1 -Steps "tools op10tool"
```

日志在 `logs\oneclick-<时间>.log`；某一步卡住超过阈值（`mu` 180 分钟、`kernel` 90 分钟等），脚本会把对应的 `~/iOSPlus10/logs/*.log` 末尾 20 行打出来。

> 一键脚本 = 把下面这些"手动阶段"自动化，流程和判定完全一样。想看细节继续往下读。

---

## 这条路能得到什么、得不到什么

| 得到 | 得不到 |
|---|---|
| Mu-Silicium UEFI 是否能在你的 NE2210 上起来 | iOS 桌面（没有根文件系统，XNU 会在 mount root 时失败） |
| UniXNU 菜单是否显示、能否进 XNU | 触控/显示/GPU 的任何实用功能 |
| 内核早期日志（有 USB 日志通道的话） | 任何持久改动 |

**为什么到不了桌面**：iOS 根是 11.6 GB 的 HFS+ 镜像，只能写进 `userdata`（内核 boot-arg `rd=ufsroot0` 写死）。
你的 `userdata` 现在还是 Android 的 F2FS，XNU 挂不上，必然停在挂载根那一步。
这正是方案 A 安全的原因：**它本来就不写任何东西**。

---

## 执行顺序（照抄即可）

### 0. 主机自检

```powershell
cd <repo>
powershell -ExecutionPolicy Bypass -File scripts\00-check-env.ps1
```

要没有 FAIL。`github.com:443` 大概率 FAIL（你的网络到 GitHub 不通），不影响——下一步用 `--mirror`。

### 1. 装 WSL2

```powershell
powershell -ExecutionPolicy Bypass -File scripts\01-install-wsl.ps1
```

管理员运行。**之后必须重启**。重启后从开始菜单打开一次 *Ubuntu 24.04*，建 Linux 用户名和密码（后面 `sudo` 要用）。

### 2. 拉代码

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run-wsl.ps1 -Script 02-setup-repos.sh -ScriptArgs "--mirror"
```

- `--mirror` 会把 `github.com` 改写走 `ghproxy.net`（我实测这条能通，直连超时）；
- 克隆 `~/iOSPlus10` + 6 个 submodule（`slop`、`Mu-Silicium-negroni`、`UniXNU`、`metal2vulkan` 等）；
- 顺手建 `~/op10-apple`、`~/op10-backup`；
- 最后会打印 `make help`，正常。

取消镜像改写：`git config --global --unset-all url.https://ghproxy.net/https://github.com/.insteadOf`

### 3. 主机依赖

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run-wsl.ps1 -Script 03-host-deps.sh
```

apt 依赖、Rust、Docker、`modprobe hfsplus`、udev、`payload-dumper-go`、`gh`。

⚠️ 装完 Docker 后**要注销重进**（`usermod -aG docker` 才生效），否则 `make mu` 会 permission denied。
临时办法：`newgrp docker`。

### 4. 构建 boot 镜像（最小集合）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run-wsl.ps1 -Script 04-build.sh -ScriptArgs "--steps","boottest"
```

`boottest` = `tools op10tool image mu kernel devicetree boot`，产出：

```
~/iOSPlus10/out/ios16/boot_a.img          ← 要的就是它
~/iOSPlus10/out/ios16/vendor_boot_a.img
~/iOSPlus10/out/ios16/negroni.adt
~/iOSPlus10/out/kernel/kernel.macho
```

跑完脚本会把它们拷到 `<repo>\dist\`。

各步说明：

| 步骤 | 干什么 | 常见失败 |
|---|---|---|
| `tools` | apt 交叉 GCC、gawk、AOSP mkbootimg、pyfatfs venv | apt 源缺包 |
| `op10tool` | Rust CLI（img2simg / ipsw-get / im4p） | 没装 cargo |
| `image` | x86_64 Docker 构建镜像（给 Mu 用） | docker 组没生效 |
| `mu` | 容器里跑 EDK2，编 Mu-Silicium UEFI | 首次拉镜像慢；EDK2 报错看 `logs/NAME.log` |
| `kernel` | `gh run download` 从 `slop` 的 Actions 下 `kernel.development.negroni` | **artifact 过期 / gh 没登录** |
| `devicetree` | `op10tool ipsw-get` + `im4p` 取 d22ap | Apple CDN 慢 |
| `boot` | 打 `boot_a.img` + `vendor_boot_a.img` + `esp.img` | 缺 ADT 或 kernel |

`make kernel` 依赖 GitHub Actions 的 artifact，**先用 `gh auth login` 登录**：

```bash
wsl -d Ubuntu-24.04 -- gh auth login
```

artifact 有 90 天保质期，项目 10 月底停更，现在还来得及。

### 5. 非破坏性启动测试

手机关机 → **音量上 + 音量下 + 电源** → 进 bootloader（不是 fastbootd）。

```powershell
powershell -ExecutionPolicy Bypass -File scripts\05-boot.ps1
```

脚本会打印镜像的 sha256、检查设备、执行 `fastboot boot dist\boot_a.img`。

**这一步不写 boot_a、不写 vendor_boot_a、不写 vbmeta、不碰 userdata。** 失败唯一后果是重启一次。

### 6. 结果判读

| 现象 | 含义 | 下一步 |
|---|---|---|
| 出现 Mu-Silicium / UniXNU 菜单 | ✅ UEFI 链路通了，shim 被 ABL 接受 | 恭喜，方案 A 成功 |
| 菜单 → 选 XNU → 黑屏/自动重启 | ✅ 正常。没有 iOS 根，XNU 挂根失败 | 想进桌面只能转方案 B |
| 直接黑屏，无菜单 | ⚠️ ABL 拒绝 header-v4 shim，或 `fastboot boot` 没把 DTB 传进去（文档列过这个风险） | 试 `make flash-boot`（会写 boot_a/vendor_boot_a，但不动 userdata） |
| `Flashing is not allowed` | BL 没解 | `fastboot oem device-info` 确认 |
| `unknown command` | 在 fastbootd，不是 bootloader | `adb reboot bootloader` |

退出：长按电源 ~10 秒强制关机，再正常开机。或 `fastboot reboot`。

### 7. 如果 `fastboot boot` 起不来（可选退路）

`make flash-boot CONFIRM=yes` 会写 `boot_a`、`vendor_boot_a`、`vbmeta_a`、擦 `dtbo_a`，**但不碰 userdata**。
这仍然保留 Android 数据，只是把引导换了；回退用 `make flash-restore CONFIRM=yes`（注意这条会 `fastboot -w`，会清 userdata，所以回退前先把 `~/op10-backup/images` 准备好，用 `fastboot flash` 只刷回 boot/vendor_boot/dtbo/vbmeta，不要带 `-w`）。

---

## 脚本清单

| 脚本 | 作用 | 会不会改手机 |
|---|---|---|
| `00-check-env.ps1` | 主机自检 | 否 |
| `01-install-wsl.ps1` | 装 WSL2 + Ubuntu 24.04 | 否（改 PC，要重启） |
| `run-wsl.ps1` | 在 WSL 里跑 .sh（自动转 LF） | 否 |
| `02-setup-repos.sh` | 克隆 iOSPlus10 + submodule | 否 |
| `03-host-deps.sh` | 主机依赖 | 否 |
| `04-build.sh` | 驱动 Makefile | 否（`flash*` 步骤除外） |
| `05-boot.ps1` | `fastboot boot` | **否** |
| `90-backup-userdata.ps1` | TWRP 里备份 | 否（只读） |

> 脚本按 upstream 文档写，**没有实机验证**。报错把输出贴回来。

---

## 已知坑（全部来自 upstream 文档）

- **ABL 可能拒绝 header-v4 shim**：文档只验证过 OxygenOS 16，你是 ColorOS 17，风险更高。
- **Mu 可能自己关机**：r0q 的 PmicDxe 电源键补丁在这版固件上没有对应实现。
- **NE2211 vs NE2210**：`config/negroni-ne2211.toml` 是作者机型配置。你的 NE2210 大概率同板，但触摸/面板节点可能要改（先跑再说，起不来菜单再谈）。
- **线材**：有的线 adb 能用、fastboot 不能用。
- **`fastboot boot` 对这种 v4 + vendor_boot 组合没有文档保证**——A 方案本质是一次探测。

---

## 附录：方案 B（清数据进桌面，本次不做）

只有在你看完菜单、确认想继续时才考虑。完整步骤见 v2 手册的历史版本思路：

1. `--steps "dmgs root simg"` 造 11.6 GB 根镜像（需要 sudo + apfs-fuse + 60–80 GB 磁盘）；
2. `90-backup-userdata.ps1 -Mode Full -Force` 整盘备份（200 GB 级）；
3. `--steps "flash" --yes`（清空 userdata）；
4. 回退：`make flash-restore` + 手工写回 userdata/metadata（**不保证 F2FS 加密元数据对得上**）。

方案 C（备用机）永远是更稳的选择。
