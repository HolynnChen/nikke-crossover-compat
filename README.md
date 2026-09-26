# NIKKE CrossOver Compatibility

**让《胜利女神：NIKKE》Windows PC 版在 Apple Silicon Mac 上通过 CrossOver 正常运行。**

[English](README.en.md) · [安装指南](docs/INSTALL.zh-CN.md) · [真正在用的技术](docs/APPLIED-TECHNIQUES.zh-CN.md) · [验证记录](docs/VALIDATION.md) · [技术设计](docs/ARCHITECTURE.md) · [CEF 渲染补丁](docs/CHROMIUM-FLAGS.md)

面向 NIKKE 的 Wine 兼容补丁集：修掉进不去、剧情卡死、帧率过低和一个多余的控制台窗口。
所有结论都来自本机实测；被推翻的早期结论在 [验证记录](docs/VALIDATION.md) 里保留了更正过程。

## 已在什么环境验证

| 项目 | 实测值 |
|---|---|
| 机型 / 芯片 | Mac16,7 / **Apple M4 Pro** |
| macOS | **26.6.2**（25G83） |
| CrossOver | **26.1** |
| NIKKE PC 国际服 | **152.8.13** |
| 容器前缀 | `~/Library/Application Support/NIKKE-Wine` |

其他硬件、CrossOver 版本和后续游戏更新尚未验证。

## 它修好了什么

**1. 启动器黑屏 / 进不去游戏**
根因：Rosetta 2 无法翻译 `0F 1F` 的**寄存器形式**多字节 NOP（ModRM.mod = 3），直接 SIGILL，
同一个根因同时打死了 ACE 内核驱动和 Unity 的 IL2CPP。修复在 Wine 侧（ntoskrnl / ntdll）。
详见 [本次更新](docs/UPDATE-2026-09-26.zh-CN.md)。

**2. 一进剧情就卡死**
根因：两个 Media Foundation 开关必须**配对**。只设 `NOP_BRIDGE_MF_NO_DXGI=1` 是半配置状态 ——
Unity 拿不到 DXGI device manager 而退到软件回退，reader 侧却仍按 D3D 帧的预期工作，
于是视频管线起头后停摆：进程活着、单核 103% CPU 空转、`Player.log` 静默数分钟。
补上 `NOP_BRIDGE_MF_SOFTWARE=1` 后剧情正常播放。

**3. 帧率低**
根因：`CX_GRAPHICS_BACKEND=dxvk` **从来没有真正生效过**。运行时视图挂在 `WINEDLLPATH` 上，
会**遮蔽前缀**，Wine 从视图里解析到内置 dll；把 DXVK 的 dll 装进前缀再加重写规则也没用
（加载到的是「被当成 native 的视图内置 PE」）。把 DXVK 放进视图后真正加载，帧率明显提升。

**4. 每次启动都弹出一个 conhost 窗口，且不随启动器关闭**
根因：本项目的 `lsass.exe` 被编译成 CONSOLE 子系统，又注册为服务，Wine 就为它分配了控制台。
窗口属于那个服务而不是启动器，所以关掉启动器也不会关。改为 GUI 子系统后消失，服务本身不受影响。

## 以后怎么启动

**双击 `~/Applications/NIKKE Wine.app` → 点「启动」。**

该 app 是自包含的（Wine 加载器就在它内部），内部调用 `scripts/launch_nikke.sh`，
脚本默认值就是已验证配置：

```
NOP_BRIDGE_MF_NO_DXGI / NOP_BRIDGE_MF_SOFTWARE = 1    视频不卡死
CX_GRAPHICS_BACKEND = dxvk + d3d9,d3d10,d3d10_1,d3d10core,d3d11=n,b    DXVK 生效
NOP_BRIDGE_PRIVILEGED = 1
```

等价的命令行方式：`cd <repo> && scripts/launch_nikke.sh`

> 本机不使用 CrossOver 菜单入口。`install_crossover_entry.py` 仍保留，供「从源容器克隆出独立容器」
> 的流程使用，但当前这台机器用的是上面这个前缀加自建启动 app。

## 构建

需要 Xcode Command Line Tools、Python 3、Bison 3 与 MinGW-w64。

```sh
# 1. macOS 侧（Rosetta NOP 桥）
make && make test

# 2. 下载 CrossOver 26.1 官方源码包
#    https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.1.0.tar.gz
python3 scripts/build_wine_modules.py \
    --archive /absolute/path/to/crossover-sources-26.1.0.tar.gz \
    --output local/wine-modules

# 3. 生成运行时视图
#    这一步会：覆盖 5 个补丁模块、materialize DXVK、把 lsass.exe 的子系统改成 GUI
python3 scripts/prepare_runtime.py \
    --output local/runtime-modules \
    --modules local/wine-modules/build
```

第 3 步的输出是**本机专用**：它包含绝对路径符号链接与第三方二进制，不要发布，换机器需重新生成。

启动 app 是一个薄壳，可以随时重建：

```sh
make                                   # 生成 build/NopBridgeLab.app（内含 Wine 加载器）
APP="$HOME/Applications/NIKKE Wine.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
printf '#!/bin/sh\nexec "%s/scripts/launch_nikke.sh" "$@"\n' "$PWD" > "$APP/Contents/MacOS/launch"
chmod +x "$APP/Contents/MacOS/launch"
cp build/NopBridgeLab.app/Contents/MacOS/wine_bootstrap "$APP/Contents/MacOS/nikke_wine"
cp src/Info.plist "$APP/Contents/Info.plist"
```

## 运行时到底替换了什么

5 个模块（`ntoskrnl.exe`、`mfplat.dll`、`mfreadwrite.dll`、`lsass.exe`，以及 Unix 侧 `ntdll.so`）
加配对的 PE `ntdll.dll`，外加视图里的 DXVK dll。
完整哈希、每个文件的证据来源和 10 个补丁的顺序见
[真正在用的技术](docs/APPLIED-TECHNIQUES.zh-CN.md)。

## 已知限制

以下都是实测结论，不是推测：

- **GPU 视频直通做不到。** Unity 的 Media Foundation 路径需要 DXGI device manager，
  而 **Wine 自身的 `MFCreateDXGIDeviceManager` 在这套环境里提供不了它**
  （错误上下文即 `Context: Creating DXGIDeviceManager`）。因此视频帧只能经系统内存交付，
  每帧多一次「显存 → 内存 → 再上传」的拷贝。这也是上面第 2 条那两个开关**必需**的原因，
  与渲染后端无关 —— 换成 DXVK 也一样。
- **解码本身仍是硬解。** GStreamer 管线里用的是 `vtdec_hw`（VideoToolbox 纯硬件元件），
  软化的只是帧交付那一段，不是「用 CPU 解码」。
- **ACE CORE 驱动进程仍有异常退出记录**，但不阻塞游戏；这不代表反作弊各组件都正常。
- 未做长期稳定性测试与定量 FPS 测量。CrossOver 或游戏更新后可能需要重新适配。

## 踩过的坑（改之前请先读）

- **视图里 `lib/wine/i386-windows` 是指回 CrossOver 本体的符号链接。** 往它下面 `rm` + `cp`
  会直接改写 CrossOver 安装（本项目误伤过一次 32 位 d3d dll）。替换视图文件前先确认该目录不是链接。
- **不要用 CrossOver 原版 `ntoskrnl.exe` 覆盖本项目构建的版本** —— 本项目版本是原版的超集。
- 判断后端是否生效**不能只看环境变量**，要查实际加载的 dll 路径与大小
  （DXVK 的 `d3d11.dll` ≈ 3165760 B，Wine 内置 ≈ 425552 B）。
- **`build/wine_bootstrap` 是 `make` 生成的符号链接**，指向 `build/NopBridgeLab.app/Contents/MacOS/wine_bootstrap`。没跑过 `make` 时它是**断链** —— `cat` 没有输出、`stat` 显示 46 字节（那是目标路径的长度），看起来像空文件。
- 校验文件时注意 `strings` 的检索目标：`CreateSharedHandle` 是 COM 虚表方法，实现在 `d3d11.dll`，
  只 grep `dxgi.dll` 会得到假阴性。

## 许可证与致谢

采用 **LGPL-2.1-or-later**，详见 [LICENSE](LICENSE) 与 [第三方来源说明](THIRD_PARTY.md)。

仓库只提供源码，不含游戏、ACE 文件、CrossOver 二进制或账号数据；
不修改也不分发游戏与 ACE 二进制；不把失败的接口查询替换成固定成功值（部分接口仍明确返回不支持）。

感谢 Wine、CodeWeavers、DW-Proton、Endfield_FineWine 及此前启动器修复项目提供的公开工作。
NIKKE、CrossOver 和 Rosetta 均为各自权利人的产品；本项目是独立的社区兼容研究。
