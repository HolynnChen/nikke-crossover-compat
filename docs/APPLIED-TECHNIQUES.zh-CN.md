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
| `x86_64-windows/lsass.exe` | `3410c261f87e9d36ba1614d883b9e824` | `src/lsass.c` | 在用（已注册 RunServices） |
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
| 9 | `mf-software` | `mfreadwrite/reader.c` `mfplat/main.c` | Media Foundation 软件回退（DXGI 共享句柄能力查询改为明确失败而非假装成功） | mfplat.dll、mfreadwrite.dll |

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
| `NOP_BRIDGE_MF_NO_DXGI=1` | 启用 `mf-software` 的 NO_DXGI 分支 |
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
| `NOP_BRIDGE_MF_SOFTWARE` | **没有设置**，而 `NOP_BRIDGE_MF_NO_DXGI` 设置了。这两个是配套开关，当前处于不一致状态。游戏能进大厅，故未改动 |
| `crossover-26.1-thread-process-experimental.patch` | 仅 28 行，`ARCHITECTURE.md` 说明其实现已并入默认构建，保留该文件是为了留下改动来源 |
| `ACE-CORE202797` | 仍为 `STOPPED`（`sc start` 返回 `87 ERROR_INVALID_PARAMETER`）。**不影响进游戏** |

---

## 八、复现

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
