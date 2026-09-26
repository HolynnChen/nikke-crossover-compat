# 安装指南 / Installation Guide

从零开始把《胜利女神：NIKKE》Windows PC 版跑到 Apple Silicon Mac 上，
以及后续如何更新本项目的兼容补丁。

本指南基于 2026-09-22 ~ 09-23 的实际安装过程整理，
所有命令与路径均在本机验证过。

---

## 目录

- [一、准备工作](#一准备工作)
- [二、创建前缀并安装游戏](#二创建前缀并安装游戏)
- [三、构建兼容补丁](#三构建兼容补丁)
- [四、安装到 Wine 前缀](#四安装到-wine-前缀)
- [五、验证安装](#五验证安装)
- [六、日常启动](#六日常启动)
- [七、更新到新版本](#七更新到新版本)
- [八、故障排查](#八故障排查)

---

## 一、准备工作

### 环境要求

| 项 | 版本 |
|---|---|
| 硬件 | Apple Silicon（M 系列）；实测 **Apple M4 Pro**（Mac16,7）|
| macOS | **26.6.2**（25G83，实测）|
| CrossOver | 26.1 |
| 游戏 | NIKKE PC 国际服 **152.8.13**（实测）|
| Rosetta | 已安装 |
| Python | 3.x |
| Xcode CLT | 已安装 |
| Bison | 3.x（`brew install bison`）|
| MinGW-w64 | 用于构建 Windows 探针 |

### 安装依赖

```sh
brew install bison mingw-w64
```

Bison 默认路径为 `/opt/homebrew/opt/bison/bin/bison`，
不同安装位置用 `--bison` 指定。

### 目录约定

本指南使用以下路径（可按需替换）：

```
仓库      /path/to/nikke-crossover-compat
Wine 前缀 ~/Library/Application Support/NIKKE-Wine
构建产物  <仓库>/local/runtime-modules
启动入口  ~/Applications/NIKKE Wine.app
```

> 下文用 `/path/to/nikke-crossover-compat` 表示你克隆本仓库的位置，请按实际路径替换。

---

## 二、创建前缀并安装游戏

> 已经装好、官方启动器能打开能登录的话，跳到[第三节](#三构建兼容补丁)。

**全程不需要打开 CrossOver 的图形界面，也不需要在它里面建容器。** 用到的只是 CrossOver
装在机器上的 Wine 运行库；前缀由本项目用命令行创建，是一个**普通 Wine 前缀**，不会出现在
CrossOver 的容器列表里。

> ⚠️ 这一步需要先完成[第三节](#三构建兼容补丁)，因为创建前缀要用到本项目的运行时。

### 2.1 从官网下载 PC 版

下载 **NIKKE PC 国际服**安装包（`NIKKE.PC_Offcial_GL_<版本>.exe`）。
本指南验证版本：`152.8.13`。

### 2.2 创建前缀

```sh
scripts/create_prefix.sh "$HOME/Library/Application Support/NIKKE-Wine"
```

`wineboot` 建前缀时会打印一些 `err:` 行（`cxcompatdb`、`setupapi` 之类），那是这一阶段的
正常噪音，不影响结果。看到 `prefix created` 就是成功了。

### 2.3 安装游戏

```sh
scripts/create_prefix.sh "$HOME/Library/Application Support/NIKKE-Wine" \
    ~/Downloads/NIKKE.PC_Offcial_GL_152.8.13.exe
```

按安装程序提示完成，安装路径保持默认 `C:\NIKKE\Launcher`。

### 2.4 首次启动，让游戏下载资源

用本项目的启动方式打开启动器（见[第六节](#六日常启动)），登录并**让它把资源下完**。

> ⚠️ 首次下载量很大（>10 GB），游戏自身的下载器较慢（约 0.3 MB/s），网络不佳时要数小时。

> 若此时启动器黑屏，是因为兼容补丁还没装上 —— 先做完第三、四节再回来。

---

## 三、构建兼容补丁

以下命令**在仓库根目录执行**。

### 3.1 构建原生兼容层

```sh
cd /path/to/nikke-crossover-compat
make
make test
```

### 3.2 下载 CrossOver 源码包

从 CodeWeavers 下载官方源码：

```sh
curl -LO https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.1.0.tar.gz
```

### 3.3 构建 Wine 补丁模块

```sh
python3 scripts/build_wine_modules.py \
    --archive "$PWD/crossover-sources-26.1.0.tar.gz" \
    --output local/wine-modules
```

这个脚本会按顺序应用以下补丁：

| 补丁 | 作用 |
|---|---|
| `crossover-26.1-kernel.patch` | Rosetta NOP 指令与特权异常处理 |
| `crossover-26.1-thread-process-experimental.patch` | 线程所属进程查询 |
| `crossover-26.1-september-update.patch` | 152.8.11 驱动入口与内存映射 |
| `crossover-26.1-ace-kernel-exports.patch` | **ACE 反作弊所需的内核导出** |
| `crossover-26.1-mf-software.patch` | 视频软件回退（修复黑屏）|

脚本会校验源码包的固定 SHA-256，不匹配会拒绝构建。

### 3.4 生成运行时

```sh
python3 scripts/prepare_runtime.py \
    --output local/runtime-modules \
    --modules local/wine-modules/build
```

这一步除覆盖 5 个补丁模块外，还会把 **DXVK** 放进视图，并把视图里 `lsass.exe` 的 PE
子系统改成 **GUI**（否则每次启动都会弹出一个关不掉的 conhost 窗口）。
两者都必须在视图里生效：视图挂在 `WINEDLLPATH` 上，**会遮蔽前缀**。

---

## 四、安装到 Wine 前缀

### 4.1 方式 A：安装到已有前缀（推荐）

如果已经有一个装好 NIKKE 的前缀，只替换兼容层模块。

共替换 **5 个文件**：4 个 PE 模块在 `x86_64-windows/`，1 个 `ntdll.so` 在
`x86_64-unix/`。完整清单与哈希见 [5.1](#51-核对模块哈希)。

```sh
PREFIX="$HOME/Library/Application Support/NIKKE-Wine"
RUNTIME="$PWD/local/runtime-modules"

# 备份原文件
mkdir -p /tmp/nikke-compat-backup
for f in ntoskrnl.exe mfplat.dll mfreadwrite.dll lsass.exe; do
  cp "$PREFIX/drive_c/windows/system32/$f" /tmp/nikke-compat-backup/ 2>/dev/null
done

# 安装 4 个 PE 模块
for f in ntoskrnl.exe mfplat.dll mfreadwrite.dll lsass.exe; do
  cp "$RUNTIME/lib/wine/x86_64-windows/$f" "$PREFIX/drive_c/windows/system32/"
done
```

**`ntdll.so` 不需要拷进前缀。** 它由 app 的 `NOP_BRIDGE_NTDLL` 指向运行时视图
生效，所以只需保证这两点：

1. `local/runtime-modules/lib/wine/x86_64-unix/ntdll.so` 是打过补丁的那份；
2. 同一目录层级下 `lib/wine/x86_64-windows/ntdll.dll` **必须同时存在**。

第 2 条容易踩坑：`ntdll` 是 Unix/PE 成对的，只覆盖 `.so` 而缺了 PE 的 `.dll`
会直接以 `error c0000135` 启动失败。用 `prepare_runtime.py` 生成视图就不会漏
（脚本会从 CrossOver 原样拷入那份未修改的 `ntdll.dll`）。

> **前缀与视图两层都要更新。** 视图通过 `WINEDLLPATH` 挂在最前面并遮蔽前缀，
> 只更新一层会出现「视图已修好、前缀还是旧版」的不一致。

### 4.2 方式 B：创建独立容器

```sh
python3 scripts/install_crossover_entry.py \
    --source-prefix "$HOME/Library/Application Support/CrossOver/Bottles/YOUR_NIKKE_BOTTLE" \
    --source-runtime local/runtime-modules \
    --source-app build/NopBridgeLab.app \
    --source-bridge build/libnop_bridge.dylib \
    --bottle-name NIKKE-Compatibility-152 \
    --menu-name "NIKKE Compatibility 152" \
    --support "$HOME/Library/Application Support/NIKKE Compatibility 152"
```

脚本用 APFS 克隆创建独立容器，保留已下载资源；
原始容器不动；已有同名目标不会被覆盖。

这一步同样**不需要打开 CrossOver 界面** —— 脚本只是写文件并调用 CrossOver 的命令行工具
登记菜单项。菜单项本身是可选的，用[第六节](#六日常启动)的 app 启动就不需要它。

---

## 五、验证安装

### 5.1 核对模块哈希

```sh
RUNTIME="$PWD/local/runtime-modules"
for f in ntoskrnl.exe mfplat.dll mfreadwrite.dll lsass.exe; do
  md5 -q "$RUNTIME/lib/wine/x86_64-windows/$f"
done
md5 -q "$RUNTIME/lib/wine/x86_64-unix/ntdll.so"
```

本机验证值：

```
ntoskrnl.exe     553a755df4792272d091168c7a4ac189
mfplat.dll       9e05b449b0042c1828db913def2a1bcc
mfreadwrite.dll  1d3509c2e55d5581fc2e26426b1fe440
lsass.exe        b09816da5eb8d431c748f7709ef7b390
ntdll.so         ae6489f07e27c0ddbf541d2db82446c9   （必须是 x86_64）
```

> `ntdll.so` **必须**是 `x86_64`。本机默认编译出来是 `arm64`，装上去会在
> bootstrap 阶段以一句难懂的架构错误失败。用 `lipo -archs` 确认。

### 5.2 确认 ACE 接口已导出

构建后的 `ntoskrnl.exe` 应包含这些导出（ACE 反作弊调用）：

```
KeTryToAcquireGuardedMutex
KeIpiGenericCall
KeGetProcessorNumberFromIndex
KeRevertToUserGroupAffinityThread
KeSetSystemGroupAffinityThread
ObDereferenceObjectDeferDelete
PsGetCurrentThreadTeb
```

缺少 `KeAcquireGuardedMutex` 会导致 ACE 报
`unimplemented function ntoskrnl.exe.KeAcquireGuardedMutex` 并拒绝启动。

### 5.3 跑接口测试

```sh
python3 scripts/test_wine_modules.py \
    --prefix "$PREFIX" \
    --runtime local/runtime-modules
```

---

## 六、日常启动

**双击 `~/Applications/NIKKE Wine.app`，然后点「启动」。**

该 app 是自包含的（Wine 加载器在它内部），内部调用 `scripts/launch_nikke.sh`，
脚本默认值就是已验证配置（两个 MF 开关、DXVK 与 d3d native 覆盖）。等价命令行：

```sh
cd /path/to/nikke-crossover-compat && scripts/launch_nikke.sh
```

> 若按 [4.2](#42-方式-b创建独立容器) 建了独立容器，也可以从 CrossOver 菜单进入；
> 采用 4.1（已有前缀）时菜单里没有该入口，用上面这个 app 启动。

启动配置使用 **DXVK**。在 CrossOver 里改图形后端不会自动改写此专用配置。

需要更清晰的画面时，在容器右侧开启**高分辨率模式**并重启容器。

> ⚠️ 不要执行 `wineserver -k` —— 会杀掉当前所有 Wine 会话。

---

## 七、更新到新版本

### 7.1 在游戏内更新

游戏出新版本时，先让官方启动器自己把更新下完。

### 7.2 更新兼容补丁（如果新版本需要）

```sh
cd /path/to/nikke-crossover-compat
git pull
git checkout <新分支>

# 重新构建
make && make test
python3 scripts/build_wine_modules.py \
    --archive "$PWD/crossover-sources-26.1.0.tar.gz" \
    --output local/wine-modules-<新版本>
python3 scripts/prepare_runtime.py \
    --output local/runtime-<新版本> \
    --modules local/wine-modules-<新版本>/build

# 安装（替换成新目录）
RUNTIME="$PWD/local/runtime-<新版本>"
cp "$RUNTIME/lib/wine/x86_64-windows/ntoskrnl.exe" \
   "$HOME/Library/Application Support/NIKKE-Wine/drive_c/windows/system32/"
cp "$RUNTIME/lib/wine/x86_64-windows/lsass.exe" \
   "$HOME/Library/Application Support/NIKKE-Wine/drive_c/windows/system32/"
```

**新入口确认可用前，保留旧文件。** 恢复方式：

```sh
cp /tmp/nikke-compat-backup/*.exe \
   "$HOME/Library/Application Support/NIKKE-Wine/drive_c/windows/system32/"
```

---

## 八、故障排查


### 进剧情就卡死（进程还在、CPU 100%、日志不动）

两个 Media Foundation 开关**没有配对**。`NOP_BRIDGE_MF_NO_DXGI=1` 单独设置是半配置状态：
Unity 拿不到 DXGI device manager 而退到软件回退，reader 侧却仍按 D3D 帧预期工作，
视频管线停摆。补上 `NOP_BRIDGE_MF_SOFTWARE=1` 即可。
`scripts/launch_nikke.sh` 默认已带齐；用自建启动 app 就不会遇到。

### 每次启动都弹出一个 conhost 窗口，且不随启动器关闭

`lsass.exe` 是 CONSOLE 子系统，Wine 为该服务分配了控制台窗口；窗口属于服务而非启动器，
所以关启动器不会关它。把 `lsass.exe` 的 PE 子系统改成 GUI 即可（`prepare_runtime.py`
会自动做），改完记得**前缀与视图两层都更新**。

### 启动时报 `unimplemented function ntoskrnl.exe.KeAcquireGuardedMutex`

装的是 CrossOver 原版 `ntoskrnl.exe`，不是本项目构建的。
重新执行[第四节](#四安装到-wine-前缀)。

> 注意：本项目构建的 `ntoskrnl.exe` 是 CrossOver 原版的**超集**，
> 替换回去会**破坏 ACE**。

### 启动器黑屏

`crossover-26.1-mf-software.patch` 负责这部分（视频走软件回退）。
确认补丁已应用。

### ACE 相关报错

两个后台 ACE CORE 驱动进程仍会异常退出（已知限制）。
可玩不代表所有保护组件都正常。

### 游戏更新后无法启动

游戏大版本更新常会引入新的内核接口调用。
先用 `KeBugCheck` 日志确认缺什么：

```
ERR( "KeBugCheck %lx called from %p\n", code, __builtin_return_address(0) );
```

然后在 `patches/crossover-26.1-ace-kernel-exports.patch` 里补上对应实现。

### 画面模糊

在 CrossOver 容器设置里开启**高分辨率模式**并重启容器。

---

## 附：完整命令速查

```sh
# 一次性全流程
cd /path/to/nikke-crossover-compat
make && make test

curl -LO https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.1.0.tar.gz

python3 scripts/build_wine_modules.py \
    --archive "$PWD/crossover-sources-26.1.0.tar.gz" \
    --output local/wine-modules

python3 scripts/prepare_runtime.py \
    --output local/runtime-modules \
    --modules local/wine-modules/build

PREFIX="$HOME/Library/Application Support/NIKKE-Wine"
RUNTIME="$PWD/local/runtime-modules"
cp "$RUNTIME/lib/wine/x86_64-windows/"{ntoskrnl.exe,lsass.exe} \
   "$PREFIX/drive_c/windows/system32/"
```

---

## 许可证

本仓库采用 **LGPL-2.1-or-later**，详见 [LICENSE](../LICENSE)、
[第三方来源](../THIRD_PARTY.md)。
不包含游戏、ACE 文件、CrossOver 二进制或账号数据。
