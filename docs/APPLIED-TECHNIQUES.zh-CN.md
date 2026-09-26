# 当前走通的方案：真正在用的技术清单

本文件回答一个问题：**现在能进游戏的那套运行时，究竟用到了哪些技术？**
结论来自对已装运行时的实测比对，不是设计意图的复述。判定方法见第六节，
每条结论都可以照着复现。

---

## 一、结论速览

运行时视图共 840 个条目，其中 **828 个是指向已安装 CrossOver 的符号链接**
（未做任何改动），**7 个实体文件**。这 7 个里 **6 个是被我们替换的**：

```
lib/wine/x86_64-windows/ntoskrnl.exe      ← 替换（定制）
lib/wine/x86_64-windows/mfplat.dll        ← 替换（定制）
lib/wine/x86_64-windows/mfreadwrite.dll   ← 替换（定制）
lib/wine/x86_64-windows/lsass.exe         ← 替换（定制）
lib/wine/x86_64-unix/ntdll.so             ← 替换（定制）
lib/wine/x86_64-windows/ntdll.dll         ← 替换（Chromium/CEF 命令列补丁，见 5.2）
LOCAL_ONLY.txt                            ← 说明文件
```

加上 macOS 侧的一个 dylib 和一个自建 bootstrap，就是全部。

---

## 二、被替换的 5 个文件

| 文件 | md5 | 来源 | 是否必需 |
|---|---|---|---|
| `x86_64-windows/ntoskrnl.exe` | `553a755df4792272d091168c7a4ac189` | 7 个内核补丁 | **必需（已证）** |
| `x86_64-unix/ntdll.so` | `ae6489f07e27c0ddbf541d2db82446c9` | `rosetta-multibyte-nop` | 在用（必要性未隔离） |
| `x86_64-windows/mfplat.dll` | `9e05b449b0042c1828db913def2a1bcc` | `mf-software` | 在用 |
| `x86_64-windows/mfreadwrite.dll` | `1d3509c2e55d5581fc2e26426b1fe440` | `mf-software` | 在用 |
| `x86_64-windows/lsass.exe` | `b09816da5eb8d431c748f7709ef7b390` | `src/lsass.c` | 在用（已注册 RunServices）。**PE 子系统已由 CONSOLE 改为 GUI** —— 否则 Wine 会为这个服务分配控制台，导致每次启动都弹出一个不随启动器关闭的 conhost 窗口 |
| `x86_64-windows/ntdll.dll` | 见 5.2 | `chromium-flags` | 在用（CEF 渲染补丁，且是 `.so` 的配对件） |

**`ntoskrnl.exe` 是唯一被证明"去掉就进不去"的文件。** 依据：打上内核态
Rosetta NOP 补丁之前，ACE 弹窗必现、`ACE-CORE102797` 停留在 `STOPPED`
（`error 31`）；打上之后才变 `RUNNING`，弹窗消失。

---

## 三、10 个补丁的分工

补丁顺序不能调换（后面的补丁基于前面改完的文件生成）。

| # | 补丁 | 改动文件 | 作用 | 进入哪个产物 |
|---|---|---|---|---|
| 1 | `kernel` | `sync.c` `ntoskrnl.c` `ntoskrnl_private.h` `*.spec` | 内核态基础设施：同步、对象名生命周期、回调列表归属、调用方内存区间数组 | ntoskrnl.exe |
| 2 | `thread-process-experimental` | `ntoskrnl.c` `*.spec` | 线程/进程属主 | ntoskrnl.exe |
| 3 | `september-update` | `instr.c` `ntoskrnl.c` `*.spec` `*_private.h` | 九月上游同步 + 内核态 RIP 转换块 | ntoskrnl.exe |
| 4 | `ace-kernel-exports` | `sync.c` `ntoskrnl.c` `*.spec` | ACE 所需内核导出（第一批） | ntoskrnl.exe |
| 5 | `ace-extended-exports` | `ntoskrnl.c` `*.spec` | ACE 所需内核导出（第二批） | ntoskrnl.exe |
| 6 | `ace-core-driver-stubs` | `ntoskrnl.c` `*.spec` | ACE CORE 驱动导入的 10 个 stub | ntoskrnl.exe |
| 7 | **`ntoskrnl-rosetta-nop`** | `instr.c` | **内核态多字节 NOP 解码 + 处理 `EXCEPTION_ILLEGAL_INSTRUCTION`** | ntoskrnl.exe |
| 8 | `rosetta-multibyte-nop` | `ntdll/unix/signal_x86_64.c` | 用户态 `handle_rosetta_nop()` | **ntdll.so** |
| 9 | `mf-software` | `mfreadwrite/reader.c` `mfplat/main.c` | Media Foundation 软件回退。**含两个必须配对的开关**：`NOP_BRIDGE_MF_NO_DXGI` 让 `MFCreateDXGIDeviceManager` 返回 `E_NOTIMPL`，`NOP_BRIDGE_MF_SOFTWARE` 让 reader 不去取 D3D manager。只开前者会卡死游戏，见 5.3 | mfplat.dll、mfreadwrite.dll |

第 7 条是本次修复的核心。第 1–6、9 条是 0.4.0 之前既有的成果。

第 10 条来自 `main` 分支的 Chromium/CEF 工作，与第 8 条**改的是 ntdll 的两半**
（`loader.c` 是 PE 侧，`unix/signal_x86_64.c` 是 Unix 侧），互不重叠，可共存。

| 10 | `chromium-flags` | `ntdll/loader.c` | 给 `tbs_browser.exe` / `INTLWebViewHelper.exe` 追加 `--in-process-gpu --disable-gpu-compositing`，绕开 winemac.drv 无法跨进程建窗口表面导致的 CEF 黑屏 | **ntdll.dll（PE）** |

---

## 四、macOS 侧生效的项

来自 `NIKKE Wine.app/Contents/Info.plist` 的 `LSEnvironment`。
这部分**没有改动**，按既定约束保持原样。

| 变量 | 作用 |
|---|---|
| `DYLD_INSERT_LIBRARIES` | 注入 `libnop_bridge.dylib`（`src/bridge.c` + `nop_decode.h` + `priv_decode.h`） |
| `NOP_BRIDGE_PRIVILEGED=1` | 启用 `priv_decode` 路径：把 `MOV CR*` 的 trap 6 改判为 trap 13 |
| `NOP_BRIDGE_NTDLL` | 指向 `runtime-modules/.../x86_64-unix/ntdll.so`（即上表第 2 行） |
| `NOP_BRIDGE_MF_NO_DXGI=1` | 启用 `mf-software` 的 NO_DXGI 分支。**必须与 `NOP_BRIDGE_MF_SOFTWARE=1` 同时设置**，否则视频管线停摆卡死游戏（见 5.3） |
| `NOP_BRIDGE_APP_PROGRAM/CWD` | 指定被托管的程序与工作目录 |
| `NOP_BRIDGE_LOG` | 桥的日志输出路径 |
| `CX_GRAPHICS_BACKEND=dxvk` | **走 DXVK，不走 CrossOver 的 DXMT/Metal 后端**（决定了第五节第 1 条） |
| `WINEDLLPATH` | 指向运行时视图的 `lib/wine/{x86_64-windows,i386-windows}` |
| `WINEDLLOVERRIDES=version=n,b` | 版本 DLL 用原生优先 |
| `WINEARCH=wow64` | 前缀架构 |
| `WINE(L)OADER` / `WINESERVER` / `CX_ROOT` / `WINEPREFIX` | 启动与容器定位 |

**注意 `NOP_BRIDGE_TRACE` 没有设置**，所以桥即使命中也不打印任何东西。
`NOP_BRIDGE_LOG` 里那条 `[nop-bridge] emulated register NOP` 计数为 0，
不能作为"桥没生效"的证据。

---

## 五、本次精简掉的内容

### 5.1 删除 `x86_64-unix/winemetal.so`（24 MB）

判定它是死重量，三条证据互相独立：

1. **图形后端不是它。** app 里显式设了 `CX_GRAPHICS_BACKEND=dxvk`，
   运行日志也确认 DXVK 已加载（`DXVK: cxaddon-1.10.3-1-25-g737aacd`）。
2. **没有任何 PE 模块会导入它。** 全量扫描 `lib/wine/x86_64-windows/` 与
   `lib/dxmt/x86_64-windows/` 的导入表：`winemetal.dll` 只被
   `lib/dxmt/` 下的 `d3d11.dll`、`dxgi.dll`、`nvapi64.dll` 三个引用，
   `lib/wine/` 下 **0 个**。DXMT 不被选中 → 这三个不会被加载。
3. **它不是脚本产出的。** `prepare_runtime.py` 里 `winemetal` 出现 0 次，
   而 `lib/dxmt` 已经作为符号链接存在。这份 24 MB 的实体副本与
   `CrossOver/lib/dxmt/x86_64-unix/winemetal.so` **md5 完全相同**
   （`548cb7eeb4dbd993f193fa02226a6019`），是手工放进去的冗余。

删除后运行时视图由 30 MB 降到 6.9 MB，冒烟测试通过（`RUNTIME_OK`）。

> 若将来把后端切回 `CX_GRAPHICS_BACKEND=dxmt`，需要把这份 .so 放回去。

### 5.2 PE `ntdll.dll` 必须存在（这次差点删错）

它和 CrossOver 原版 **md5 完全相同**（`28f9240613d2472d1091530bebf969a6`），
一开始我判断它只是"无意义的副本"并删掉了。**结果直接起不来**：

```
wine: failed to load .../local/runtime-modules/lib/wine/x86_64-unix/ntdll.dll
error c0000135
```

`c0000135` 是 `STATUS_DLL_NOT_FOUND`。原因是 **ntdll 是成对的**：
Unix 侧的 `.so` 和 PE 侧的 `.dll` 必须放在一起。既然我们的 `.so` 是覆盖进去的，
PE 的 `.dll` 就必须一起覆盖，否则加载直接失败。

所以结论修正为：**这份 `ntdll.dll` 是必需的。**

**它从哪里来，取决于有没有提供构建产物：**

- **有构建产物（正常流程）→ 用构建出来的**，因为 `chromium-flags` 补丁改的是
  PE 侧的 `dlls/ntdll/loader.c`，只有自建的 `.dll` 才带这个改动。
- **没有构建产物 → 退回 CrossOver 原版**，此时只有 Unix 侧被覆盖，
  成对关系依然成立。

需要留意的是：用自建 `ntdll.dll` 意味着**放弃 CodeWeavers 对 PE 侧 ntdll 的补丁**。
这是 `chromium-flags` 方案的固有代价（不改 `loader.c` 就加不了那两个命令行开关），
不是本次合并引入的新问题。

> 附带修掉的一个坑：`prepare_runtime.py` 原来在 `if modules:` 分支里才把
> `x86_64-windows` 从符号链接换成真目录。如果把 `ntdll.dll` 的拷贝放在那之前，
> 就会**透过符号链接写进已安装的 CrossOver 目录**。脚本已改为无条件先实体化
> 该目录、再拷入文件；构建前后已核对 CrossOver 的 mtime 与 md5 未变。

### 5.3 视频管线停摆：两个 MF 开关必须配对（新结论）

**症状**：进入剧情（`StoryEvent` / `EpisodePlayOverlay`）后游戏**假死不退出**——
进程存活、单核 103% CPU 空转、`Player.log` 停止输出（实测静默 206 秒）。
用 `sample` 抓栈可见视频管线线程全部**阻塞**在 `g_cond_wait`，
进程里堆着 10 条 GStreamer 管线（`qtdemux` / `multiqueue` / `vtdechw`）。

**触发点**：`Player.log` 里退出前是 5 个并行的

```
WindowsVideoMedia error 0x80004001
Context: Creating DXGI DeviceManager      ← 就是这一步失败
```

`0x80004001` 是 `E_NOTIMPL`，**由本补丁的 NO_DXGI 分支产生**。

**机制**：`NOP_BRIDGE_MF_NO_DXGI=1` 让 Unity 拿不到 DXGI device manager
（Unity 因此退到软件回退），但 reader 侧仍在按"D3D 帧"的预期工作，
两边不一致 → 视频管线起头后停摆。补上 `NOP_BRIDGE_MF_SOFTWARE=1` 后，
reader 明确不取 D3D manager、产出系统内存样本，与 Unity 的软件回退一致，问题消失。

**实测对照**（除 `MF_SOFTWARE` 外环境完全相同）：

| | 只开 `NO_DXGI` | `NO_DXGI` + `MF_SOFTWARE` |
|---|---|---|
| `using system-memory video samples` | **0 次** | **6 次** |
| 同一个 `EventFieldHud → StoryEvent` | 卡死，静默 206 秒 | 走过，继续到战斗结算 |
| 游戏进程 CPU | 103%（空转） | ~52%（正常解码） |
| 画面 | 冻住 | 剧情正常渲染 |

这与 `VALIDATION.md` 里的早期结论不矛盾，正好拼完整：
`MF_SOFTWARE` **单独**用会失败（manager 仍能创建，Unity 继续要 `IMFDXGIBuffer` 报
`E_NOINTERFACE`）；`NO_DXGI` **单独**用在下载背景动画上够用，
但在剧情播片场景会停摆。**两个一起**才是自洽的软件视频路径。

> ⚠️ 截至本次提交，这个组合只在手动启动的进程里验证过；
> app bundle 的 `Info.plist` 尚未包含 `NOP_BRIDGE_MF_SOFTWARE`，
> 走图标启动仍会复发。切换方式见第八节。

### 5.4 硬解直通：尚未定论（先前结论已更正）

> **本节原先断言「DXMT 与 DXVK 都没有实现 DXGI 共享句柄，所以硬解直通不可行」。
> 那个断言是错的，已在 2026-09-26 更正。** 错在两处方法问题，记录下来以免重犯。

**方法错误一：grep 错了模块。** `CreateSharedHandle` 是 COM 虚表方法，
实现在 **`d3d11.dll`**，不在 `dxgi.dll`；只 grep `dxgi.dll` 会得到 0 命中的假阴性。
实际情况是三个实现**都有**：

| 实现 | 证据 |
|---|---|
| DXVK `d3d11.dll` | `CreateSharedHandle: access / attributes / name`、`D3D11Device::OpenSharedResourceGeneric: Handle not found:`、`Failed to create shared resource:` |
| DXMT `d3d11.dll` | `dxmt::DeviceTexture<...>::CreateSharedHandle(_SECURITY_ATTRIBUTES*, unsigned long, wchar_t const*, void**)`（C++ 修饰符号） |
| Wine 内置 `d3d11.dll` | 4 处匹配 |

**方法错误二：测试用错了后端。** 那次「放开 DXGI 就卡死」的实验跑在
`CX_GRAPHICS_BACKEND=d3dmetal` 下，而实测该值在本机会被判 unusable 并
**静默回退到 Wine 内置 d3d11**。所以那次卡死只证明**内置 d3d11** 不行 ——
**DXVK 从未在「放开 DXGI」的条件下被测试过**。

**仍然成立的部分**：

- 放开 DXGI 路径时，游戏会在剧情处卡死（已在内置 d3d11 下复现），
  日志静默 200 秒以上、单核 103% CPU、GStreamer 管线堆积。
- 解码确实是 `vtdec_hw`（VideoToolbox 硬解），软的是帧交付。
- `NOP_BRIDGE_MF_NO_DXGI` 自 2026-09-08（commit `9b1884d`）就存在，早于本次修复。

**新的开放问题**：DXVK 的共享句柄依赖 Vulkan 外部内存句柄机制，
而 MoltenVK 只暴露基础 `VK_KHR_external_memory`，**没有**
`_win32` / `_fd` / `_metal` 任何一个平台句柄扩展。因此 DXVK 的共享句柄在 macOS 上
能否真正工作仍未确定 —— 它可能退化为进程内共享表（DXVK 内部有
`OpenSharedResourceGeneric` 的 name→resource 查表逻辑），
而**进程内共享对 Unity 的 MF 路径可能已经够用**。

**待办**：用**确认已生效的 `dxvk` 后端**（查实际加载的 dll 路径）+ 放开两个 MF
开关重测。在那之前，不要把「硬解直通不可行」当作结论。

### 5.5 后端切换的坑（操作提醒）

`CX_GRAPHICS_BACKEND` 的合法值是 `d3dmetal` / `dxmt` / `dxvk` / `wined3d`，
由 Wine 侧的 `cxcompatdb.so` 读取后把 d3d dll 重定向到 `lib/dxmt` 或 `lib/dxvk`。

**本机实测**：设 `d3dmetal` 时该后端被判为 unusable，**静默回退到 Wine 内置 d3d11** ——
实际加载的是 `lib/wine/x86_64-windows/d3d11.dll` 加 `libMoltenVK.dylib`。
因此**不能只看环境变量就断定后端生效**，要查实际加载的 dll 路径：

```sh
lsof -p <游戏PID> | grep -iE "d3d11|dxgi" | awk '{print $NF}'
```

出现 `lib/dxmt/...` 或 `lib/dxvk/...` 才是后端生效；
`lib/wine/x86_64-windows/...` 说明已经回退到内置实现。


### 5.6 DXVK 必须放进运行时视图（性能关键，且视图会遮蔽前缀）

**背景**：Wine 内置 wined3d 性能明显不足；DXVK 快很多（用户实测「帧率流畅许多」）。
但本项目的配置里 `CX_GRAPHICS_BACKEND=dxvk` **从未真正生效过**，原因如下。

**视图遮蔽前缀**：`WINEDLLPATH` 指向 `local/runtime-modules`，Wine 解析 d3d dll 时
**先命中视图**。因此：

| 做法 | 结果 |
|---|---|
| 只设 `CX_GRAPHICS_BACKEND=dxvk` | ❌ 从视图解析到内置 dll |
| 加 `CX_ACTIVE_GRAPHICS_BACKEND=dxvk` | ❌ 无效（已实测证伪） |
| 把 DXVK 装进前缀 `system32` + native 覆盖 | ❌ 覆盖「生效」了，但加载的仍是被当成 native 的**视图内置 PE** |
| **把 DXVK 的 dll 放进运行时视图** | ✅ **真正加载** |

**判定方法（不要只看环境变量）**：

```sh
# 加载的 dll 的 inode 必须等于视图里那个文件
f=$(lsof -p <游戏PID> | awk '$NF ~ /d3d11.dll$/ {print $NF}' | head -1)
stat -f '%i %z' "$f" "$RUNTIME/lib/wine/x86_64-windows/d3d11.dll"
# DXVK d3d11 ≈ 3165760 B；Wine 内置 ≈ 425552 B。DXVK 还会生成 d3d9.log
```

`prepare_runtime.py` 现在会把 `lib/dxvk/x86_64-windows/{d3d9,d3d10,d3d10_1,d3d10core,d3d11}.dll`
materialize 进视图（CrossOver 的 DXVK 不含 `dxgi.dll`，故 dxgi 仍用 Wine 内置）。
`launch_nikke.sh` 默认带上 native 覆盖：

```
WINEDLLOVERRIDES=version=n,b;d3d9,d3d10,d3d10_1,d3d10core,d3d11=n,b
```

> ⚠️ **写穿符号链接的坑（务必注意）。** 视图里 `lib/wine/i386-windows` 是**指回 CrossOver
> 本体的符号链接**。对它下面的文件执行 `rm + cp` 会**直接改写 CrossOver 安装**
> （本次就误伤过 32 位 d3d dll，已用前缀内置副本还原并验证 `codesign --verify` 通过）。
> 要替换视图里的文件，先确认该目录不是指向 CrossOver 的链接。

### 5.7 放开 DXGI 的失败根因：Wine 自己的 mfplat

在**确认 DXVK 已真正加载**的前提下重测「放开两个 MF 开关」，结果：

- 游戏**仍然卡死**在剧情处（日志冻结 90 秒以上、单核 103% CPU、GStreamer 管线堆积）。
- Unity 仍报 `WindowsVideoMedia error 0x80004001`，上下文是 `Creating DXGIDeviceManager`。
- 这次补丁是**关闭**的，所以 `E_NOTIMPL` 来自 **Wine 自身的 `MFCreateDXGIDeviceManager`**。

**结论修正**：瓶颈不是 DXVK 的共享句柄（DXVK 确实实现了 `CreateSharedHandle`），
而是 **Wine 的 mfplat 在这套环境下就无法提供 DXGI device manager**。
因此两个 MF 开关的配对是**必需**的，与渲染后端无关。

**最终推荐配置**：DXVK（性能）+ `NOP_BRIDGE_MF_NO_DXGI=1` + `NOP_BRIDGE_MF_SOFTWARE=1`（视频不卡死）。
两者可以并存，实测剧情正常通过、CPU 62-96%（对比卡死时空转 103%）。

---

## 六、判定方法（结论怎么来的）

每条结论都不是靠读代码猜的，而是：

1. **对比已装运行时与 CrossOver 原版。** 遍历运行时视图，用 `find -type f`
   挑出所有非符号链接的实体文件，再对每个文件与
   `/Applications/CrossOver.app/.../CrossOver/` 下的同名文件比 md5。
   相同 = 只是副本，不同 = 真定制。这一步直接得出第二节那 5 个文件。
2. **导入表扫描，ASCII 与 UTF-16 都要查。** 这一步差点让我得出错误结论：
   按 ASCII 搜 `mfplat`，`UnityPlayer.dll` 命中 **0** 次，看着像"游戏不用
   Media Foundation"；改搜 **UTF-16LE** 才命中 `mfplat.dll`、`mfreadwrite.dll`。
   Unity 是按 UTF-16 名字 `LoadLibrary` 的，所以 `mfplat`/`mfreadwrite`
   两个模块**确实在路径上**（另有 `MFStartup`、`MFCreateSourceReader`、
   `IMFSourceReader` 等字符串互相印证）。
   **任何"某 DLL 没被使用"的结论，都必须同时查两种编码。**
3. **句柄反查。** `lsof +D <prefix>` 找出真正被进程打开的文件，
   比 `ps` 按进程名匹配可靠得多（Wine 会把进程名写成 `-timestamps`
   这种看不出身份的值）。
4. **重建比对，而且必须真的启动一次。** 用 `prepare_runtime.py` 重新生成
   一份运行时视图，确认文件清单与手工装的那套 **md5 完全一致**。
   但**只比哈希是不够的**：脚本早先的版本能产出"哈希全对"的视图，
   却因为少了一个 `ntdll.dll` 而根本起不来。
   所以最终判据是**把新视图真正启动一次**：

   ```sh
   NOP_BRIDGE_NTDLL=/tmp/rt-new/lib/wine/x86_64-unix/ntdll.so \
     "$HOME/Applications/NIKKE Wine.app/Contents/MacOS/nikke_wine" \
     "C:\\windows\\system32\\cmd.exe" /c "echo OK"
   ```

---

## 七、保留但已知冗余或未验证的项

这些**没有删**，因为删掉的风险大于收益，或者证据不足以定论：

| 项 | 情况 |
|---|---|
| 用户态 `ntdll.so` 补丁 | 与 macOS 侧 `nop_bridge`（`src/nop_decode.h`）覆盖**同一条编码**。桥生效时 ACE 仍失败，说明桥不覆盖内核路径；但两者在游戏进程里各自的贡献**未做隔离验证** |
| `crossover-26.1-thread-process-experimental.patch` | 仅 28 行，`ARCHITECTURE.md` 说明其实现已并入默认构建，保留该文件是为了留下改动来源 |
| `ACE-CORE202797` | 仍为 `STOPPED`（`sc start` 返回 `87 ERROR_INVALID_PARAMETER`）。**不影响进游戏** |

---

## 八、复现

**注意 `MF_SOFTWARE` 必须带上**，否则剧情播片会卡死（5.3）。

日常启动用 `scripts/launch_nikke.sh`：它**复刻 app bundle 自己的那套环境**
（`WINELOADER`/`CX_WINELOADER` 指向 app 自带的 bootstrap），只多出
`NOP_BRIDGE_MF_SOFTWARE=1`。这样既不必改 app 的 `Info.plist`（它是 adhoc 签名的，
改了签名就失效），也不引入额外一层。

> **为什么不走 `scripts/launch_crossover.py`。** 它内部调用 CrossOver 自己的
> `bin/wine` 包装脚本，那是一条**额外的依赖层**——原 app 正是刻意绕开它、
> 直接用自己的 bootstrap 当 loader 的。本机实测这条路径只拉起了 `wineserver`、
> 启动器始终没出现，因此改用 bootstrap 直启。
> （附带查明：`bin/wine` 是 Perl 脚本，其中**不含任何许可或过期检查逻辑**；
> 但两条路都同样依赖 CrossOver.app 处于已安装状态，
> 因为运行时视图里的文件是符号链接指向它的。）

等价的图形入口是 `~/Applications/NIKKE Wine.app`——一个**新建的**包装
app，原 `NIKKE Wine.app` 完全未被改动。

```sh
# 1. 构建 5 个模块（含 ntdll.so，会强制 x86_64 并打印哈希）
python3 scripts/build_wine_modules.py

# 2. 生成运行时视图（脚本会自动选用打过补丁的 ntdll.so）
python3 scripts/prepare_runtime.py \
    --output local/runtime-modules \
    --modules local/wine-modules/build

# 3. 核对：应恰好输出这 5 个实体文件
find local/runtime-modules -type f

# 4. 启动
open "$HOME/Applications/NIKKE Wine.app"
```

`prepare_runtime.py` 会在构建出的 `ntdll.so` 不是 x86_64 时**直接报错**，
而不是留到启动阶段才报一句难懂的加载失败——这是之前踩过的坑。
