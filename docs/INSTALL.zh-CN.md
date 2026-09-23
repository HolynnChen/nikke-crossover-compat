# 安装指南 / Installation Guide

从零开始把《胜利女神：NIKKE》Windows PC 版跑到 Apple Silicon Mac 上，
以及后续如何更新本项目的兼容补丁。

本指南基于 2026-09-22 ~ 09-23 的实际安装过程整理，
所有命令与路径均在本机验证过。

---

## 目录

- [一、准备工作](#一准备工作)
- [二、安装 NIKKE 本体](#二安装-nikke-本体)
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
| 硬件 | Apple Silicon（M 系列）|
| macOS | 27.0（26.6.2 亦可）|
| CrossOver | 26.1 |
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
仓库      ~/work/nikke-crossover-compat
Wine 前缀 ~/Library/Application Support/NIKKE-Wine
构建产物  <仓库>/local/runtime-0.2.0
启动入口  ~/Applications/NIKKE Wine.app
```

---

## 二、安装 NIKKE 本体

> 如果已经装好并能打开官方启动器，跳到[第三节](#三构建兼容补丁)。

### 2.1 从官网下载 PC 版

下载 **NIKKE PC 国际服**安装包（`NIKKE.PC_Offcial_GL_<版本>.exe`）。
本指南验证版本：`152.8.11`。

### 2.2 在 CrossOver 中安装

1. 打开 CrossOver → **安装 Windows 软件**
2. 选择下载好的安装包
3. 容器名建议：`NIKKE-Compatibility`
4. 安装路径保持默认 `C:\NIKKE\Launcher`

### 2.3 首次启动，让游戏下载资源

从 CrossOver 启动官方启动器，登录并**让它把资源下完**。

> ⚠️ 首次下载量很大（>10 GB），游戏自身的下载器较慢（约 0.3 MB/s）。
> 网络条件不佳时可能要数小时。

### 2.4 确认启动器可用

官方启动器能打开、能登录、能看到「开始游戏」按钮，就完成这一步。

如果启动器本身打不开，先解决启动器问题 —— 本项目的补丁不负责修复启动器。

---

## 三、构建兼容补丁

以下命令**在仓库根目录执行**。

### 3.1 构建原生兼容层

```sh
cd ~/work/nikke-crossover-compat
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
    --output local/wine-modules-0.2.0
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
    --output local/runtime-0.2.0 \
    --modules local/wine-modules-0.2.0/build
```

---

## 四、安装到 Wine 前缀

### 4.1 方式 A：安装到已有前缀（推荐）

如果已经有一个装好 NIKKE 的前缀，只替换兼容层模块：

```sh
PREFIX="$HOME/Library/Application Support/NIKKE-Wine"
RUNTIME="$PWD/local/runtime-0.2.0"

# 备份原文件
mkdir -p /tmp/nikke-compat-backup
for f in ntoskrnl.exe lsass.exe; do
  cp "$PREFIX/drive_c/windows/system32/$f" /tmp/nikke-compat-backup/ 2>/dev/null
done

# 安装新模块
cp "$RUNTIME/lib/wine/x86_64-windows/ntoskrnl.exe" \
   "$PREFIX/drive_c/windows/system32/"
cp "$RUNTIME/lib/wine/x86_64-windows/lsass.exe" \
   "$PREFIX/drive_c/windows/system32/"
```

### 4.2 方式 B：创建独立容器

```sh
python3 scripts/install_crossover_entry.py \
    --source-prefix "$HOME/Library/Application Support/CrossOver/Bottles/YOUR_NIKKE_BOTTLE" \
    --source-runtime local/runtime-0.2.0 \
    --source-app build/NopBridgeLab.app \
    --source-bridge build/libnop_bridge.dylib \
    --bottle-name NIKKE-Compatibility-152 \
    --menu-name "NIKKE Compatibility 152" \
    --support "$HOME/Library/Application Support/NIKKE Compatibility 152"
```

脚本用 APFS 克隆创建独立容器，保留已下载资源；
原始容器不动；已有同名目标不会被覆盖。

---

## 五、验证安装

### 5.1 核对模块哈希

```sh
PREFIX="$HOME/Library/Application Support/NIKKE-Wine"
md5 -q "$PREFIX/drive_c/windows/system32/ntoskrnl.exe"
md5 -q "$PREFIX/drive_c/windows/system32/lsass.exe"
```

本机验证值（0.2.0）：

```
ntoskrnl.exe  019181abcb3eae2ac386da83df26afe0
lsass.exe     3410c261f87e9d36ba1614d883b9e824
```

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
    --runtime local/runtime-0.2.0
```

---

## 六、日常启动

打开 `~/Applications/NIKKE Wine.app`，或从 CrossOver 进入
**NIKKE-Compatibility → NIKKE Compatibility → 官方启动器的「开始游戏」**。

启动配置使用 **DXVK**。在 CrossOver 里改图形后端不会自动改写此专用配置。

需要更清晰的画面时，在容器右侧开启**高分辨率模式**并重启容器。

> ⚠️ 不要执行 `wineserver -k` —— 会杀掉当前所有 Wine 会话。

---

## 七、更新到新版本

### 7.1 在游戏内更新

游戏出新版本时，先让官方启动器自己把更新下完。

### 7.2 更新兼容补丁（如果新版本需要）

```sh
cd ~/work/nikke-crossover-compat
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
cd ~/work/nikke-crossover-compat
make && make test

curl -LO https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.1.0.tar.gz

python3 scripts/build_wine_modules.py \
    --archive "$PWD/crossover-sources-26.1.0.tar.gz" \
    --output local/wine-modules-0.2.0

python3 scripts/prepare_runtime.py \
    --output local/runtime-0.2.0 \
    --modules local/wine-modules-0.2.0/build

PREFIX="$HOME/Library/Application Support/NIKKE-Wine"
RUNTIME="$PWD/local/runtime-0.2.0"
cp "$RUNTIME/lib/wine/x86_64-windows/"{ntoskrnl.exe,lsass.exe} \
   "$PREFIX/drive_c/windows/system32/"
```

---

## 许可证

本仓库采用 **LGPL-2.1-or-later**，详见 [LICENSE](../LICENSE)、
[第三方来源](../THIRD_PARTY.md)。
不包含游戏、ACE 文件、CrossOver 二进制或账号数据。
