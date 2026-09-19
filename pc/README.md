# PC（Windows）端 —— 已实现

打开教务系统（默认）与 WebVPN（次要），**不做导入**。自动登录的**判断逻辑与 Android 端逐条一致**
（同一份 `docs/CORE-SPEC.md`、同一批页面脚本 `shared/js/`、各自语言的等价单测）；
**界面形态是桌面的**，不是手机应用的移植。

## 形态（桌面惯例）

- **启动直达**：双击即进教务系统，没有中间首页/大卡片；首次运行只用一条可关闭的顶部横幅说明
  「非官方：这是个人做的教务系统快捷入口，与学校无关」+「首次登录后记住账号（加密保存在本机）」，
  有过一次已保存的账号之后横幅不再出现。
- **自绘标题栏**：左侧是应用标记（圆形满底 + 白色描边折角纸）+ `教务直达` + 当前页面标题，
  右侧是系统样式的 `—` `□` `✕`。
  用 WPF 原生 `WindowChrome` 实现，拖动、双击最大化、贴边贴靠、`Alt+Space` 系统菜单**都是系统行为**。
- **工具栏**：`← → ⟳ | 教务系统 | WebVPN | （右侧）状态一句话 + ⚙ 设置`。
- **快捷键**：`Alt+←/→` 后退前进、`Ctrl+1/2` 切换入口、`F5` 刷新；支持鼠标后退/前进侧键。
- **设置 = 模态对话框**（CheckBox / Button，桌面控件）：自动登录、收起公告弹窗、清除缓存退出登录、
  清除账号（危险）、改用其他账号。
- **记住窗口大小与位置**；窗口标题跟页面走（`页面标题 — 教务直达`）。

## 显示层（桌面视觉，与手机端刻意不同）

颜色 token 与语义角色沿用 `DESIGN.md`，**字号与密度按桌面重定**——手机规范里 `labelSmall 11px` 是给
6 寸屏底栏的，直接当 DIP 用会得到「大框小字」，1080 DIP 宽的窗口里它比学校页面正文还小。落地见
`DESIGN.md` 的「落到 PC（Windows）时本文件表达不了的语义」，代码在 `App.xaml`。

- **图标用 Windows 原生图标字体** `Segoe Fluent Icons`（Win10 回退 `Segoe MDL2 Assets`），
  不再用 `←` `→` `⟳` `⚙` 这类文本字形——它们来自字体回退链，笔画、字高、基线互不一致，高 DPI 下无法对齐。
- **桌面字号层级**：caption 12 / body 13 / label 13 / title 15，一屏最多两种字重；页签选中态靠
  主色 + 底边 2px 指示条，不加粗（避免切换时横向抖动）。
- **状态层**：悬停 `#EDF1F6`、按下 `#E2E9F1`；窗口按钮悬停 `#E9EDF2`，关闭键悬停 `#C42B1C` 白字。
- **鼠标目标**：工具栏图标按钮 36×36、窗口按钮 46×36、对话框按钮高 36（触屏的 48px 不适用）。
- **边框**：无系统边框，由 1px 描边 + 8px 圆角自绘；最大化时圆角与描边归零。
- **DPI**：`app.manifest` 声明 `permonitorv2,permonitor`，进程为 PerMonitorV2，跨显示器/改缩放不会整窗发虚。
- **应用图标**：`Assets/CampusEntry.ico`（16/20/24/32/40/48 用 BMP + 64/128/256 用 PNG），
  由 `tools/make-app-icon.ps1` 生成——**脚本才是图标的唯一事实来源**，改设计改脚本重跑即可。
- **无障碍**：「当前入口」用 `RadioButton` 表达互斥状态，每个图标按钮都有 `AutomationProperties.Name`。

### 已知限制（实测记录，不是猜的）

- **最大化时客户区比工作区每边大 13px**：`WindowChrome` 会把最大化窗口按「工作区外扩一圈
  `ResizeBorderThickness`」给出，而它同时把非客户区清零，客户区就等于整个窗口矩形。标准做法是在
  `WM_GETMINMAXINFO` 里把 `MaxSize` 钉回工作区，但 **`WindowChrome` 自己已经消费了这条消息**
  （它的钩子返回 `handled=true`，后加的 `HwndSource` 钩子实测完全不会被调用）。只影响视口高度
  （页面按 1730 排版、可见 1704），可见边缘仍严格止于任务栏，没有视觉断层；换来的是保留原生的拖动、
  贴靠与最小尺寸约束，这个取舍划算，因此不自行接管窗口几何。详见 `DesktopWindowFrame.cs`。
- **贴靠布局（Snap Layouts）悬浮预览**：窗口按钮是我们画的，鼠标悬停到最大化键不会弹出 Win11 的
  布局选择浮层。`Win+Z` 与拖到屏幕边缘贴靠不受影响。若要补，需要在 `WM_NCHITTEST` 里对最大化键
  返回 `HTMAXBUTTON`，但那会把该区域变成非客户区，WPF 侧就收不到悬停事件、按钮失去悬停高亮。
- **首次运行横幅**：已目视复核（`pc-banner.png`）。复核方法值得记一笔——本机已保存凭据时按设计
  横幅不显示，所以是**把 `credentials.bin` 临时移开、截图后原样还原**（凭据文件本身没有被读写或重建），
  而不是"因为看不到所以不验"。
- **滑块识别在真值语料上有 3/80 的天花板（96.2%，已实测，非本实现特有）**：这一版度量在
  「单次提交」协议下首选命中 77/80；剩下 3 例偏差都在 200px 量级（整个认错），参考实现同样错这 3 例。
  它们的真值**落在参考候选表的前 4 位内**，要靠"提交失败后换下一个候选"才能救——而页面每失败一次就
  换一张验证码，所以这条路在本应用里走不通。实际影响很小：单次 96.2% × 3 次重试，一次登录流程
  三次全错的概率约 **0.005%**（修度量之前是 0.8%）。

## 与三端一致的部分（唯一来源，不在此处重复）

| 内容 | 唯一来源 |
| --- | --- |
| 页面契约 JS（探测/认证页观察/滑块/填写/凭据捕获/公告弹窗） | `shared/js/`（链接为本工程内嵌资源） |
| 落点与状态机、页面身份判据、停手规则 | `docs/CORE-SPEC.md` §1–§4（`Core/EntryFlow.cs`、`Core/Sues.cs` 逐条对应） |
| 滑块定位与拖动换算 | `docs/CORE-SPEC.md` §5（`Core/SliderSolver.cs`、`Core/SliderDrag.cs`） |
| 凭据规则（何时填、何时删、归因） | `docs/CORE-SPEC.md` §6（落盘**框架**与 Android 同一套：`[版本字节 1][后端密文]` + 明文 `[长度 u16 大端][账号][密码]`；密文段 PC 走 DPAPI、与 Android 的格式天然不同） |
| 视觉 token | `DESIGN.md`（颜色/字号/圆角/行高，`App.xaml` 落地；含 PC 落地层的桌面字号与密度） |

**密钥与存储（PC 的平台机制）**：DPAPI（`ProtectedData`，CurrentUser 范围）——Windows 的一等公民，
密钥由操作系统按用户账户派生并保管，应用读不到、导不出；密文换用户/换机器即解不开。
落盘在 `%LOCALAPPDATA%\CampusEntry\`：`entry.json`（前缀与偏好、窗口几何）、`credentials.bin`
（凭据密文，单独文件便于「清除账号」与备份排除）、`run.log`（运行日志，报障发这一个文件即可）、
`WebView2\`（浏览器数据目录）。

## 目录

```
pc/
  src/CampusEntry/            # WPF 应用（net8.0-windows）
    app.manifest              # PerMonitorV2 DPI 感知 + Win10/11 兼容性声明
    Assets/CampusEntry.ico    # 应用图标（由 tools/make-app-icon.ps1 生成，勿手改）
    App.xaml                  # 设计 token + 控件样式（图标字体、页签、窗口按钮、复选框）
    DesktopWindowFrame.cs     # Win11 窗口圆角（DWM），含最大化尺寸的实测记录
    Core/Sues.cs              # 判据（对应 Sues.kt）
    Core/EntryFlow.cs         # 导航状态机（对应 EntryFlow.kt，含待判决归因）
    Core/SliderSolver.cs      # 滑块定位（对应 SliderSolver.kt）
    Core/SliderDrag.cs        # 拖动换算（对应 SliderDrag.kt）
    Core/CredentialStore.cs   # 凭据编解码（对应 CredentialStore.kt，格式同一套）
    Core/DpapiCryptoBackend.cs
    Core/CredentialRepository.cs / EntrySettings.cs
    Core/EntryHost.cs         # WebView2 宿主（对应 EntryHost.kt；回调走 chrome.webview.postMessage）
    Core/ScriptBag.cs         # 内嵌的 shared/js + 占位符填充 + PC 传输垫片
    MainWindow / SettingsWindow
  tools/
    make-app-icon.ps1         # 生成多尺寸 .ico（图标的唯一事实来源）
    capture-window.ps1        # 抓真实窗口截图，用于显示效果核验（PrintWindow，被遮挡也有效）
    preview-identity.ps1      # 渲染改名/改图标的候选对照图，选定之前先看效果
  tests/CampusEntry.Tests/    # xunit：CORE-SPEC §7 向量 + 归因/换算/求解/凭据 + 内嵌清单守卫 + 宿主层（70 项）
```

## 构建与运行

```powershell
cd pc
dotnet build src\CampusEntry\CampusEntry.csproj        # 需 .NET 8 SDK 与 WebView2 Runtime（Win10/11 自带）
dotnet test tests\CampusEntry.Tests\CampusEntry.Tests.csproj
dotnet run --project src\CampusEntry

# 改了图标设计之后重生成 .ico（唯一事实来源是脚本，不是那个二进制文件）
pwsh -File tools\make-app-icon.ps1

# 显示效果核验：抓真实窗口截图（源码级单测证明不了"显示效果"）
pwsh -File tools\capture-window.ps1 -Start -WaitSeconds 12
pwsh -File tools\capture-window.ps1 -CropTop 160 -OutPath docs\screenshots\_top.png

# 便携版：自包含单文件，目标机不需要装 .NET（仍需系统的 WebView2 Runtime）
dotnet publish src\CampusEntry\CampusEntry.csproj -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
  -p:EnableCompressionInSingleFile=true -p:DebugType=none -o dist

# 改名/改图标之前先出候选对照图（不动任何应用代码）
pwsh -File tools\preview-identity.ps1
```

> 构建前先退出正在运行的 CampusEntry，否则 exe 被占用会报 `MSB3027`。

### 便携版

`dist\CampusEntry.exe` 是**一个文件**（约 68.8 MB）：自包含单文件 + 压缩，目标机**不需要安装 .NET**。
它唯一带不走的外部依赖是 **WebView2 Runtime**——那是系统级组件，微软不支持随应用分发（固定版本方案要另外
分发近 200 MB 并自行跟进更新）。绝大多数 Win10/11 自带；万一缺失，应用会弹出带官方下载地址的明确提示并干净退出，
而不是崩溃（`MainWindow.ReportFatal`）。

第一次运行会在 `%LOCALAPPDATA%\CampusEntry\` 建目录（配置、凭据密文、WebView2 数据）。**便携指的是程序，不是数据**——
数据不跟着 exe 走，这是刻意的：凭据密文由 DPAPI 绑定当前用户，跟着 exe 走也解不开，只会多一份需要清理的东西。

### 改名时不能动的东西

显示名是「教务直达」，但下面这些都是**标识**，改名时**一个都不能跟着改**（改了用户机器上的账号就读不到了）：

| 位置 | 值 | 为什么 |
| --- | --- | --- |
| 数据目录 | `%LOCALAPPDATA%\CampusEntry\` | 改了等于换了一个存储位置，已保存的账号读不到 |
| exe 文件名 | `CampusEntry.exe` | 中文文件名在压缩包/脚本/老工具里容易乱码 |
| 命名空间、程序集名、资源逻辑名 | `CampusEntry.*` | 纯技术标识，改了要动一批引用 |
| 日志前缀协议 | `campus-entry` | 与 `shared/js/notice-dialog.js` 的 `LOG` 逐字对应，是跨端契约 |

显示名只在三处出现：窗口标题（`Title`）、标题栏文案、以及 exe 文件属性里的**产品名/文件说明**（`<Product>` / `<AssemblyTitle>`）。

依赖：`Microsoft.Web.WebView2`、`System.Drawing.Common`（滑块取像素）、
`System.Security.Cryptography.ProtectedData`（DPAPI）。没有统计与上报。

## 已实测（2026-09-19，真实网络）

- 首次运行：门户 → 认证页 → 用户手动登录 → 凭据捕获（提交那一刻）→ 滑块自动拖 →
  「密码已过期」页自动点掉「点击跳过」→ 门户读出前缀 → 落 `/student/home` → 凭据加密落盘。
- 冷启动：**零操作**直达教务系统（含自动填写提交、滑块自动拖、过期页跳过；约 3 秒）。
- 滑块一把落出 ±2 容差时会换图自动重试（实测第二把过）。
- 公告弹窗按开关收起（首评 `none`，MutationObserver 随后收掉；页面右侧「通知公告」仍可用）。
- 密码错误处置（删凭据/归因/剩余次数）在单测覆盖；**未对真实服务端做过错误密码提交**
  （服务端累计 5 次锁号，不该拿真实账号去撞）。

## 显示效果核验（2026-09-19，真实窗口 + 截图，不是"看代码觉得对"）

显示这一层用真实截图核验（`tools/capture-window.ps1`，200% 缩放，物理像素）：

| 项 | 核验方式 | 结果 |
| --- | --- | --- |
| 垂直对齐 | 扫描标题文字 / 图标 / 分隔线 / 页签的实测像素中心 | 标题文字中心 38 对行中心 38；图标 116.5 对 118；分隔线 117.5；页签文字 118 |
| 工具栏分栏 | 实测工具栏底线 | y=162，与 `2 + 36 + 44` DIP 的推算完全一致 |
| 选中指示条 | 主色像素扫描 | 贴在工具栏底边（2 DIP） |
| 悬停态 | 鼠标移到后退键，比对像素 | `(255,255,255)` → `(237,241,246)` = `#EDF1F6` |
| 窗口圆角 | 抓左上角放大 8× | 被 DWM 真正裁圆 |
| 标题栏/任务栏图标 | `WM_GETICON` 取值 + exe 资源枚举 | 三个 `HICON` 均非零；exe 内 `RT_GROUP_ICON` 在 32512 |
| 滑块识别 | 80 例真值语料逐例对照 Python 参考 | 首选命中 **77/80（96.2%）**、与参考**逐例一致 80/80**（2026-09 修度量之后；修之前是 64/80） |
| DPI 感知 | `AreDpiAwarenessContextsEqual` 比上下文句柄 | `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2`（改造前实测为 `SYSTEM_AWARE`） |
| 最大化 | 比对窗口矩形与工作区 | 底边曾比工作区低 108px → 去掉 `WindowStyle="None"` 后收敛到 13px（见「已知限制」） |
| 无障碍树 | UI Automation 遍历 | `RadioButton 打开教务系统 / 打开 WebVPN`、三个窗口按钮、`Text 状态` 均在 |

单测 70 项全绿（含 4 项宿主层真机用例，见下）；显示层改动不触碰 `Core/` 逻辑。

### 宿主层用例（`EntryHostDomTests`，4 项）

测的是**判据有没有被接上**（导航回调 → 状态机 → 宿主效果），不是判据本身——判据由
`SuesTests` / `EntryFlowTests` 覆盖。做这一层的直接理由：Android 侧同一层查出了两个真实缺陷
（初始 `about:blank` 被当成一份文档、判据读控件的实时属性），而 PC 侧原先**零覆盖**。

```powershell
dotnet test tests\CampusEntry.Tests\CampusEntry.Tests.csproj --filter 'FullyQualifiedName~EntryHostDomTests'
```

四个硬约束（**改这个文件之前先读**）：

1. **STA + 消息泵**：`WebView2` 要求 STA，xunit 的测试线程是 MTA，直接 `CreateAsync` 会得到
   `RPC_E_CHANGED_MODE`。用例在一条 STA 线程上起 `Dispatcher` + **离屏窗口**（`Left=-4000`，必须真的
   `Show()` 过才有 HWND），**所有 WebView2 调用都在那条线程上**；测试方法本身是 `async`，不在 UI 线程上阻塞。
2. **拦截请求，不联网**：`WebResourceRequested` + `AddWebResourceRequestedFilter` 把
   `https://webvpn.sues.edu.cn/*` 与 `https://jxfw.sues.edu.cn/*` 的响应换成本地造的那一页。
   于是 `Core.Source` 是**真实的学校地址**（`IsCredentialPage` 这类判据照常判），
   而**一点网络流量都不产生**——测试绝不该向学校发请求。
3. **别碰用户数据**：临时目录 + `EntrySettings.DataDirectory`（2026-09 新增，默认值不变）。
   `Save()` 是宿主会主动调用的（清前缀、切换保存意愿），只靠"测试不去调 Save"防不住。
   （宿主自己的诊断日志仍写真实目录的 `run.log`——那是应用自己的日志，与应用运行时无异。）
4. **拦截器要在初始化成功之后装**：`View.CoreWebView2` 在初始化完成前是 `null`，
   在构造函数里直接订阅会得到 `NullReferenceException`（四个用例会在构造函数里齐刷刷失败）。

用例与断言：A3 的「门户没登录标记就不算到达 / 有标记才停手」、A2 的「非门户主机不填 / 门户主机才填」。
**做过红测**：把 §6.1 的主机闸短路之后，「非门户主机不填」当场变红。

核验证据（`docs/screenshots/`，都是真实窗口的 `PrintWindow` 截图）：

| 文件 | 拍的是什么 |
| --- | --- |
| `pc-display-check.png` | 改造前的窗口（用于比对的基线） |
| `pc-display-after.png` | 显示层改造后（字号/图标/边框/DPI 那一轮） |
| `pc-identity.png` | **当前身份**：新标记 + `教务直达` + 新页面标题 |
| `pc-banner.png` | 首次运行横幅（含「非官方」交代）与登录页 |
| `pc-maximized.png` | 最大化状态（圆角归零、贴任务栏） |
| `pc-settings.png` | 设置对话框 |
| `icon-sizes.png` | 应用图标 16/20/24/32/40/48/64/128/256 各尺寸实拍 |
| `identity-preview.png` | 改名/改图标的候选对照图（选定前的预览） |
| `ios-icon.png` | iOS 图标，以及系统圆角遮罩后的效果模拟 |

> 核验记录里的数字是**实测量的**，不是估算。凡是没实测的（贴靠悬浮预览）都写在
> 「已知限制」里，不写成"已完成"。

## 与 Android 端的已知差异（逻辑无关的形态差异）

- 单窗口：站点 `window.open` / `target=_blank` 在当前窗口打开（保住返回栈）；Android 是标签页。
- PC（桌面 UA）上滑块是独立文档、手机端与表单同页——两种形态 CORE-SPEC §5.1 都覆盖。
- WebView2 无 console 事件（本 SDK），公告弹窗后续收起动作不逐条进 run.log（初始执行结果有日志）；
  需要细查时用 `--remote-debugging-port`（debug 构建未开，需要时再加）。
