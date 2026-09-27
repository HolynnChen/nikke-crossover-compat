# 安装指南

把《胜利女神：NIKKE》Windows PC 国际服跑到 Apple Silicon Mac 上。

> **只想一条命令装完？** 在仓库根目录执行
> `scripts/install_all.sh --installer <游戏安装包.exe>`。
> 它按下表的顺序自动完成第二～五节并建好启动 app，可重复执行、已完成步骤会跳过。
> 本指南其余部分是同一流程的手动分步版。

## 顺序要求

四步之间有硬依赖，**顺序不能调换**：

| 顺序 | 步骤 | 为什么必须在这里 |
|---|---|---|
| 1 | 构建兼容补丁（含运行时视图）| 后面每一步都要用视图里的 Wine 加载器和库 |
| 2 | 创建前缀 | `create_prefix.sh` 直接依赖视图（`bin/wineloader`、`lib/wine/x86_64-*`），视图不在就报错退出 |
| 3 | **把补丁模块装进前缀** | 启动器靠它们才能渲染界面、下载资源 |
| 4 | **安装游戏** | 必须在补丁之后；反过来会黑屏、卡在「正在初始化」、下不动资源 |

最常被搞反的是第 3、4 步。

---

## 目录

- [一、准备工作](#一准备工作)
- [二、构建兼容补丁](#二构建兼容补丁)
- [三、创建前缀](#三创建前缀)
- [四、把补丁装进前缀](#四把补丁装进前缀)
- [五、安装游戏](#五安装游戏)
- [六、验证](#六验证)
- [七、日常启动](#七日常启动)
- [八、更新到新版本](#八更新到新版本)
- [九、故障排查](#九故障排查)

---

## 一、准备工作

### 环境要求

| 项 | 版本 |
|---|---|
| 硬件 | Apple Silicon（M 系列）；实测 **Apple M4 Pro**（Mac16,7）|
| macOS | **26.6.2**（实测）|
| CrossOver | **26.3**（`brew install --cask crossover`）|
| 游戏 | NIKKE PC 国际服 **152.8.13**（实测）|
| Rosetta | 已安装 |
| Python | 3.x |
| Xcode CLT | 已安装 |
| Bison | 3.x |
| MinGW-w64 | 构建 Windows 探针用 |

```sh
brew install bison mingw-w64
```

Bison 默认在 `/opt/homebrew/opt/bison/bin/bison`，装在别处用 `--bison` 指定。

> 补丁按 **26.3** 的源码锚定，构建时会校验源码包 SHA-256；运行时视图里 800 多个文件是
> **指向 CrossOver 安装目录的符号链接**，所以升级 CrossOver 后必须用同版本源码重新构建模块。
> 补丁同时适用于 26.1 和 26.3。

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

## 二、构建兼容补丁

以下命令**在仓库根目录执行**。

### 2.1 构建 macOS 侧兼容层

```sh
cd /path/to/nikke-crossover-compat
make
make test
```

### 2.2 下载 CrossOver 源码包

```sh
curl -LO https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz
```

### 2.3 构建 Wine 补丁模块

```sh
python3 scripts/build_wine_modules.py \
    --archive "$PWD/crossover-sources-26.3.0.tar.gz" \
    --output local/wine-modules
```

脚本按固定顺序应用补丁，并校验源码包 SHA-256，不匹配会拒绝构建：

| 补丁 | 改的文件 | 作用 |
|---|---|---|
| `crossover-kernel.patch` | `ntoskrnl.exe/sync.c` | 内核同步原语（guarded mutex 等）|
| `crossover-thread-process-experimental.patch` | `ntoskrnl.exe/ntoskrnl.c` | 线程所属进程查询 |
| `crossover-september-update.patch` | `ntoskrnl.exe/instr.c` | 驱动入口与内存映射 |
| `crossover-ace-kernel-exports.patch` | `ntoskrnl.exe/sync.c` | **ACE 反作弊所需的内核导出** |
| `crossover-ace-extended-exports.patch` | `ntoskrnl.exe/ntoskrnl.c` | ACE 所需的扩展内核导出 |
| `crossover-ace-core-driver-stubs.patch` | `ntoskrnl.exe/ntoskrnl.c` | ACE CORE 驱动所需的桩函数 |
| `crossover-ntoskrnl-rosetta-nop.patch` | `ntoskrnl.exe/instr.c` | 内核态多字节 NOP 模拟 |
| `crossover-rosetta-multibyte-nop.patch` | `ntdll/unix/signal_x86_64.c` | 用户态多字节 NOP 模拟（Rosetta）|
| `crossover-mf-software.patch` | `mfreadwrite/reader.c` | 视频软件回退（剧情不卡死）|
| `crossover-chromium-flags.patch` | `ntdll/loader.c` | **给 `tbs_browser.exe` 追加 `--in-process-gpu`（修启动器黑屏）**|

### 2.4 生成运行时视图

```sh
python3 scripts/prepare_runtime.py \
    --output local/runtime-modules \
    --modules local/wine-modules/build
```

这一步除放入 5 个补丁模块外，还会把 **DXVK** 放进视图，并把视图里 `lsass.exe` 的 PE
子系统改成 **GUI**（否则每次启动都会多出一个关不掉的 conhost 窗口）。

两者都必须在视图里生效：视图挂在 `WINEDLLPATH` 上并**遮蔽前缀**。

---

## 三、创建前缀

**全程不需要打开 CrossOver 的图形界面，也不需要在它里面建容器。** 用到的只是 CrossOver
装在机器上的 Wine 运行库；前缀由本项目用命令行创建，是一个**普通 Wine 前缀**，
不会出现在 CrossOver 的容器列表里。

```sh
scripts/create_prefix.sh "$HOME/Library/Application Support/NIKKE-Wine"
```

`wineboot` 建前缀时会打印一些 `err:` 行（`cxcompatdb`、`setupapi` 之类），
那是这一阶段的正常噪音。看到 `prefix created` 就是成功了。

---

## 四、把补丁装进前缀

> ⚠️ **这一步必须在安装游戏之前做完。** 少了补丁，启动器会黑屏、卡在「正在初始化」、下不动资源。

共替换 **4 个 PE 模块**：

```sh
PREFIX="$HOME/Library/Application Support/NIKKE-Wine"
RUNTIME="$PWD/local/runtime-modules"

# 备份原文件
mkdir -p /tmp/nikke-compat-backup
for f in ntoskrnl.exe mfplat.dll mfreadwrite.dll lsass.exe; do
  cp -p "$PREFIX/drive_c/windows/system32/$f" /tmp/nikke-compat-backup/ 2>/dev/null
done

# 安装
for f in ntoskrnl.exe mfplat.dll mfreadwrite.dll lsass.exe; do
  cp "$RUNTIME/lib/wine/x86_64-windows/$f" "$PREFIX/drive_c/windows/system32/"
done
```

**`ntdll.so` 不需要拷进前缀。** 它由启动 app 的 `NOP_BRIDGE_NTDLL` 指向视图生效，
只需保证这两点：

1. `local/runtime-modules/lib/wine/x86_64-unix/ntdll.so` 是打过补丁的那份；
2. 同层级下 `lib/wine/x86_64-windows/ntdll.dll` **必须同时存在**。

第 2 条容易踩坑：`ntdll` 是 Unix/PE 成对的，只覆盖 `.so` 而缺了 `.dll` 会以
`error c0000135` 启动失败。用 `prepare_runtime.py` 生成视图就不会漏。

> **前缀与视图两层都要更新。** 视图遮蔽前缀，只更新一层会出现「视图已修好、前缀还是旧版」
> 的不一致。

> 已经有装好 NIKKE 的前缀（例如用 CrossOver 图形界面装的容器）时，只做本节即可。
> 若你想在原容器之外另建一个带 CrossOver 菜单入口的独立副本，
> 用 `scripts/install_crossover_entry.py`，参数见 `--help`。

---

## 五、安装游戏

### 5.1 从官网下载 PC 版

下载 **NIKKE PC 国际服**安装包（`NIKKE.PC_Offcial_GL_<版本>.exe`）。本指南验证版本：`152.8.13`。

### 5.2 运行安装程序

```sh
scripts/create_prefix.sh "$HOME/Library/Application Support/NIKKE-Wine" \
    ~/Downloads/NIKKE.PC_Offcial_GL_<版本>.exe
```

前缀已存在，脚本会跳过创建、只运行安装包。按提示完成，
安装路径保持默认 `C:\NIKKE\Launcher`。

### 5.3 创建启动 app

```sh
scripts/create_launch_app.sh
```

生成 `~/Applications/NIKKE Wine.app`（自包含，Wine 加载器在它内部）。

---

## 六、验证

```sh
python3 scripts/test_wine_modules.py \
    --prefix "$HOME/Library/Application Support/NIKKE-Wine" \
    --runtime local/runtime-modules
```

再确认 `ntdll.so` 的架构是 **x86_64**：

```sh
lipo -archs local/runtime-modules/lib/wine/x86_64-unix/ntdll.so
```

> 必须是 `x86_64`。装成 `arm64` 会在 bootstrap 阶段以一句难懂的架构错误失败。

---

## 七、日常启动

**双击 `~/Applications/NIKKE Wine.app`，点「启动」。**

等价命令行：

```sh
cd /path/to/nikke-crossover-compat && scripts/launch_nikke.sh
```

启动脚本默认值就是已验证配置（两个 Media Foundation 开关、`CX_GRAPHICS_BACKEND=dxvk`、
d3d native 覆盖），用启动 app 就不会漏。

### 首次启动：让游戏下载资源

首次打开启动器后登录，**让它把资源下完**再点「启动」。

> 首次下载量很大（>10 GB），游戏自身下载器较慢，网络不佳时要数小时。

> 画面模糊时在 CrossOver 容器设置里开启**高分辨率模式**并重启容器。

> ⚠️ 不要执行 `wineserver -k` —— 会杀掉当前所有 Wine 会话。

---

## 八、更新到新版本

### 8.1 在游戏内更新

游戏出新版本时，先让官方启动器把更新下完。

### 8.2 更新兼容补丁（如果新版本需要）

```sh
cd /path/to/nikke-crossover-compat
git pull

# 构建到新目录，不覆盖正在用的那份
make && make test
python3 scripts/build_wine_modules.py \
    --archive "$PWD/crossover-sources-26.3.0.tar.gz" --output local/wine-modules-new
python3 scripts/prepare_runtime.py \
    --output local/runtime-modules-new --modules local/wine-modules-new/build

# 备份并替换全部 4 个模块（与第四节相同；漏掉 mfplat / mfreadwrite 会让剧情重新卡死）
PREFIX="$HOME/Library/Application Support/NIKKE-Wine"
mkdir -p /tmp/nikke-compat-backup
for f in ntoskrnl.exe mfplat.dll mfreadwrite.dll lsass.exe; do
  cp -p "$PREFIX/drive_c/windows/system32/$f" /tmp/nikke-compat-backup/
  cp "local/runtime-modules-new/lib/wine/x86_64-windows/$f" \
     "$PREFIX/drive_c/windows/system32/"
done

# 启用新视图：换成启动脚本默认使用的那一份
mv local/runtime-modules local/runtime-modules-old
mv local/runtime-modules-new local/runtime-modules
```

**确认新版本可用之前保留旧文件。** 回滚：

```sh
cp /tmp/nikke-compat-backup/* "$PREFIX/drive_c/windows/system32/"
mv local/runtime-modules local/runtime-modules-bad
mv local/runtime-modules-old local/runtime-modules
```

---

## 九、故障排查

### 启动器黑屏 / 卡在「正在初始化」 / 下不动资源

补丁没装进前缀，或者前缀与视图不一致。回到[第四节](#四把补丁装进前缀)重做，
并确认前缀与视图**两层**都已更新。

### 进剧情就卡死（进程还在、CPU 100%、日志不动）

两个 Media Foundation 开关**没有配对**。只设 `NOP_BRIDGE_MF_NO_DXGI=1` 是半配置状态：
Unity 拿不到 DXGI device manager 而退到软件回退，reader 侧却仍按 D3D 帧预期工作，
视频管线停摆。补上 `NOP_BRIDGE_MF_SOFTWARE=1` 即可。`scripts/launch_nikke.sh` 默认已带齐。

### 每次启动都弹出一个 conhost 窗口，且不随启动器关闭

`lsass.exe` 是 CONSOLE 子系统，Wine 为该服务分配了控制台窗口；窗口属于服务而非启动器，
所以关启动器不会关它。把它的 PE 子系统改成 GUI 即可（`prepare_runtime.py` 会自动做），
改完记得**前缀与视图两层都更新**。

### 启动时报 `unimplemented function ntoskrnl.exe.KeAcquireGuardedMutex`

装的是 CrossOver 原版 `ntoskrnl.exe`，不是本项目构建的。重做[第四节](#四把补丁装进前缀)。

> 本项目构建的 `ntoskrnl.exe` 是 CrossOver 原版的**超集**，替换回原版会**破坏 ACE**。
> 构建后的 `ntoskrnl.exe` 应包含 `KeTryToAcquireGuardedMutex`、`KeIpiGenericCall`、
> `KeGetProcessorNumberFromIndex`、`PsGetCurrentThreadTeb` 等 ACE 所需导出。

### ACE 相关报错

两个后台 ACE CORE 驱动进程仍会异常退出（已知限制）。可玩不代表所有保护组件都正常。

### 游戏更新后无法启动

游戏大版本更新常会引入新的内核接口调用。先用 `KeBugCheck` 日志确认缺什么：

```
ERR( "KeBugCheck %lx called from %p\n", code, __builtin_return_address(0) );
```

然后在 `patches/crossover-ace-kernel-exports.patch` 里补上对应实现。

---

## 许可证

本仓库采用 **LGPL-2.1-or-later**，详见 [LICENSE](../LICENSE)、
[第三方来源](../THIRD_PARTY.md)。
不包含游戏、ACE 文件、CrossOver 二进制或账号数据。
