# NIKKE CrossOver Compatibility

**让《胜利女神：NIKKE》Windows PC 版在 Apple Silicon Mac 上通过 CrossOver 正常运行。**

[English](README.en.md) · [安装指南](docs/INSTALL.zh-CN.md)

一组 Wine 兼容补丁，解决 Apple Silicon 上的启动失败、剧情卡死、帧率过低和一个多余的
控制台窗口。以下内容均在本机实测通过。

## 需要什么

| 项 | 要求 |
|---|---|
| Mac | Apple Silicon（已在 **M4 Pro** 上验证）|
| macOS | **26.6.2** |
| CrossOver | **26.1**，Rosetta 已安装 |
| 游戏 | NIKKE PC 国际服安装包（**152.8.13 已验证**）—— 客户端需你自行下载，本项目不提供直链 |
| 构建依赖 | Xcode Command Line Tools、Python 3、Bison 3、MinGW-w64 |

本仓库只提供源码，不含游戏、ACE 文件、CrossOver 二进制或账号数据。

> 已经装好 NIKKE、官方启动器能打开能登录的话，跳过与安装游戏有关的步骤，只做打补丁那部分即可。

## 安装

**一条命令装完（推荐）：**

```sh
scripts/install_all.sh --installer ~/Downloads/NIKKE.PC_Offcial_GL_<版本>.exe
```

它会依次检查依赖 → 下载并校验 CrossOver 源码包 → 构建 macOS 层 → 构建 Wine 补丁模块
（**耗时数十分钟**）→ 生成运行时 → 创建前缀 → 装好 4 个模块 → 运行游戏安装程序 →
建好启动 app。**可以重复执行**，已完成的步骤会自动跳过。

有两件事它替你做不了：

- **安装 CrossOver 本体** —— 商业软件，请先自行安装；
- **下载 NIKKE 客户端** —— 没有稳定的公开直链。自己下载后用 `--installer <路径>` 传入，
  或用 `--installer-url <直链>` 让它下载。

登录账号与 10 GB 以上的资源下载在启动器内完成，无法自动化。

<details>
<summary>想手动分步做，或只想看每一步在干什么</summary>

```sh
# 1. macOS 侧兼容层
make && make test

# 2. 从 CrossOver 26.1 源码包构建 Wine 补丁模块（需先下载源码包）
python3 scripts/build_wine_modules.py \
    --archive /path/to/crossover-sources-26.1.0.tar.gz --output local/wine-modules

# 3. 生成运行时视图
python3 scripts/prepare_runtime.py \
    --output local/runtime-modules --modules local/wine-modules/build

# 4. 创建前缀并安装游戏（不需要打开 CrossOver 界面，也不会建 CrossOver 容器）
#    第二个参数是游戏安装包；省略它就只创建前缀，之后再单独跑安装包
scripts/create_prefix.sh "$HOME/Library/Application Support/NIKKE-Wine" <安装包.exe>

# 5. 把运行时模块装进前缀，并创建启动 app
for f in ntoskrnl.exe mfplat.dll mfreadwrite.dll lsass.exe; do
  cp "local/runtime-modules/lib/wine/x86_64-windows/$f" \
     "$HOME/Library/Application Support/NIKKE-Wine/drive_c/windows/system32/"
done
scripts/create_launch_app.sh

```

完整说明见 **[安装指南](docs/INSTALL.zh-CN.md)**。已经装好 NIKKE 的话，跳过第 4 步。
**安装和游玩全程都不需要 CrossOver 的图形界面。**

</details>

## 启动

**双击 `~/Applications/NIKKE Wine.app`，点「启动」。**

该 app 是自包含的（Wine 加载器在它内部），内部调用 `scripts/launch_nikke.sh`，
已带齐全部必需设置。等价的命令行方式：

```sh
cd <本仓库> && scripts/launch_nikke.sh
```

## 它修好了什么

| 问题 | 原因 | 修复位置 |
|---|---|---|
| 启动器黑屏 / 进不去 | Rosetta 2 无法翻译 `0F 1F` 的**寄存器形式**多字节 NOP，同时打死 ACE 内核驱动和 Unity IL2CPP | Wine 侧 ntoskrnl / ntdll 补丁 |
| 一进剧情就卡死 | 两个 Media Foundation 开关**必须配对**；只设 `NOP_BRIDGE_MF_NO_DXGI=1` 会让视频管线停摆 | `NOP_BRIDGE_MF_SOFTWARE=1` |
| 帧率低 | `CX_GRAPHICS_BACKEND=dxvk` 单独设置不生效 —— 运行时视图会遮蔽前缀 | 把 DXVK 放进视图，并加 d3d native 覆盖 |
| 每次启动弹出 conhost 窗口 | `lsass.exe` 是 CONSOLE 子系统，Wine 为这个服务分配了控制台 | 改成 GUI 子系统 |

以上除第一项外都已固化在 `scripts/launch_nikke.sh` 与 `scripts/prepare_runtime.py` 里，
正常安装无需手工设置。

## 出问题了

先看[安装指南的故障排查](docs/INSTALL.zh-CN.md#八故障排查)。最常见的是：

- **进剧情卡死**（进程还在、CPU 100%、日志不动）：两个 MF 开关没配对。
- **每次启动弹出黑窗口且关不掉**：`lsass.exe` 的子系统没改，或只改了一层。
- **启动器黑屏**：确认用的是本仓库的启动方式，不是 CrossOver 自己的菜单入口。

## 已知限制

- **GPU 视频直通做不到。** Unity 的 Media Foundation 路径需要 DXGI device manager，
  而 Wine 自身的 `MFCreateDXGIDeviceManager` 在这套环境里提供不了。因此视频帧经系统内存
  交付，每帧多一次拷贝；这也是上面两个 MF 开关**必需**的原因，与渲染后端无关。
- **解码本身仍是硬解**（VideoToolbox / `vtdec_hw`），只有帧交付在 CPU 侧，不是"用 CPU 解码"。
- **ACE CORE 驱动进程仍有异常退出记录**，但不阻塞游戏。
- 仅在上述单一环境验证过；CrossOver 或游戏更新后可能需要重新适配。

## 许可证与致谢

采用 **LGPL-2.1-or-later**，详见 [LICENSE](LICENSE) 与 [第三方来源说明](THIRD_PARTY.md)。

本项目不修改也不分发游戏与 ACE 二进制，不把失败的接口查询替换成固定成功值。

感谢 Wine、CodeWeavers、DW-Proton、Endfield_FineWine 及此前启动器修复项目提供的公开工作。
NIKKE、CrossOver 和 Rosetta 均为各自权利人的产品；本项目是独立的社区兼容研究。
