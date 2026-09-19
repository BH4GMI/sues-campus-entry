# iOS 端 —— 工程已建，**尚未编译验证**

打开教务系统（默认）与 WebVPN（次要），**不做导入**。自动登录的**判断逻辑与 Android/PC 逐条一致**
（同一份 `docs/CORE-SPEC.md`、同一批页面脚本 `shared/js/`、各自语言的等价单测）。

## 交付状态：只有源码，从未编译、从未运行

本端在交付时所在的机器是 Windows，且没有 Swift 工具链（`swift` / `swiftc` / `xcodebuild` /
`xcodegen` / `clang` 全部不存在），也没有 macOS。因此：

- 没有编译过，没有运行过任何测试，界面也没有在模拟器或真机上出现过。
- 工程文件 `CampusEntry.xcodeproj` 是手写的（当时无法用 Xcode 生成），只做了结构自检
  （ID 引用完整性、括号平衡）；它能否被 Xcode 打开、能否构建成功，均未经验证。
- `CampusEntryTests/` 中的用例是把 Windows 端与 Android 端的等价用例逐条翻译过来的，未运行过。
- 无工具链时无法排除的语法点（例如 `Range(_:in:)` 与简写可选绑定）已在各文件就近注释。

在 macOS 上复现之前，本端的「与另外两端逻辑一致」来自源码与用例的对齐，不是运行结果的比对。
定位是**待编译的移植稿**，不是可交付的成品；拿到 Mac 后请先按下一节跑一遍，再考虑信任这一端。

## 首次在 Mac 上要做的事（按顺序）

```bash
# 1. 打开工程（Xcode 16+；工程文件用的是 objectVersion 77 与「同步文件夹」特性）
open ios/CampusEntry.xcodeproj

# 如果工程打不开或结构不对，用 project.yml 重新生成（它是结构的唯一事实来源）
brew install xcodegen
cd ios && xcodegen generate

# 2. 改 bundle id（当前占位 cn.sues.campusentry），真机运行需要自己的签名
#    Xcode → CampusEntry target → Signing & Capabilities → 选自己的 Team

# 3. 先编译，再跑单测（这一步才是这一端第一次被真正验证）
xcodebuild -project ios/CampusEntry.xcodeproj -scheme CampusEntry \
           -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -project ios/CampusEntry.xcodeproj -scheme CampusEntry \
           -destination 'platform=iOS Simulator,name=iPhone 16' test

# 4. 界面与流程按 docs/APP-UX.md §9 的验证矩阵跑（场景 1–10）
```

## 平台机制的三端对照

三端**共用的**是判断逻辑与页面脚本；**各自不同的**只有平台机制：

| 关注点 | Android | PC（Windows） | iOS |
| --- | --- | --- | --- |
| 浏览器内核 | `WebView` | WebView2 | `WKWebView` |
| JS → 原生 | `addJavascriptInterface` | `chrome.webview.postMessage` | `window.webkit.messageHandlers.entry.postMessage` |
| 原生 → JS | `evaluateJavascript` | `ExecuteScriptAsync` | `evaluateJavaScript` |
| 返回值形态 | 字符串 | 二次 JSON 编码的字符串，需 Unquote | **原生对象，不做 Unquote** |
| 凭据加密 | AndroidKeyStore（AES-256-GCM） | DPAPI（CurrentUser） | **Keychain 存密钥 + CryptoKit AES-GCM** |
| 凭据落盘格式 | `[版本字节 1][后端密文]`，明文 `[长度 u16 大端][账号 UTF-8][密码 UTF-8]` | 同左（框架同一套；密文段 = DPAPI 自有格式） | 同左（密文段 = `nonce(12)‖密文‖标签(16)`） |
| 设置存储 | SharedPreferences | `%LOCALAPPDATA%\CampusEntry\entry.json` | `UserDefaults` |
| 「新文档」事件 | `onPageStarted` | `NavigationStarting(!IsRedirected)` | `didStartProvisionalNavigation` |
| 窗口/标签形态 | 标签页 | 单窗口 + 自绘标题栏 | 单 WKWebView + 底部栏 |

**凭据落盘的硬契约是三端共用的「框架」**：`[版本字节 1][后端密文]`，明文为
`[用户名长度 u16 大端][用户名 UTF-8][密码 UTF-8]`（长度取低 8 位）——**这一层一个字节都不能改**。

但要**说准**一件事：`[1..]` 那段密文**按平台机制天然不同**——PC 是 DPAPI 自有格式，Android 是
`[IV长度][IV][密文+标签]`，iOS 是 `nonce(12)‖密文‖标签(16)`。PC 与 Android 之间本来就已经不同。
所以"逐字节同一套"只成立于框架，**不代表整个 blob 可以在三端之间搬**（搬过去也解不开：密钥在各自的
平台密钥库里，本来就不出机器）。

## 页面脚本（不复制，直接引用同一批物理文件）

`shared/js/` 是仓库根的同一批文件，iOS 侧以 **folder reference** 打进 App bundle
（Bundle 内路径 `js/<name>.js`），与 Android 的 `assets.srcDir` 和 PC 的 `EmbeddedResource`
链接是同一个做法——**改一处三端同时变，杜绝三份漂移**。

脚本通过 `window.entry.*` 回调宿主，iOS 的传输垫片把它转到 `webkit.messageHandlers.entry`，
消息体形状与 PC 完全一致（`cmd` 为 `armed` / `captcha` / `credential` / `log`）。
垫片必须在每份文档的页面脚本之前注入。

## 目录

```
ios/
  CampusEntry.xcodeproj/      # 手写工程文件（未验证能否打开；见上文）
  project.yml                 # 工程结构的唯一事实来源 + 重建后备（xcodegen）
  CampusEntry/
    App/                      # SwiftUI 壳层（浏览页 + 底部栏 + 状态 + 账号抽屉）
    Core/                     # 纯逻辑层与宿主（对应 Android/PC 的同名文件）
    Assets.xcassets/          # AppIcon（1024，无 alpha）+ AccentColor
  CampusEntryTests/           # XCTest：CORE-SPEC §7 向量 + 归因/换算/求解/凭据
  tools/make-app-icon.ps1     # 生成 AppIcon（与 PC 图标同一套几何，唯一事实来源）
```

## 应用图标

`ios/tools/make-app-icon.ps1` 生成 `AppIcon-1024.png`。iOS 的规则与 Windows 不同，脚本里已按 iOS 处理：

- **满幅正方形，不画圆角**（圆角与遮罩由系统施加，自己画会变成"圆角套圆角"）；
- **不能有 alpha 通道**（Xcode 与 App Store 都拒绝带透明的图标），脚本末尾有自检；
- 现代 Xcode 只需要一张 1024×1024，其余尺寸由系统缩放。

```powershell
pwsh -File ios/tools/make-app-icon.ps1
```

## 与另外两端的差异（平台形态，不是逻辑差异）

- 单 `WKWebView`，站点的 `window.open` / `target=_blank` 在当前视图打开（保住返回栈）。
- 账号入口是底部栏第三项，打开为 sheet（对应 Android 的抽屉）；设置项同 Android。

## 交付前做过的核验（以及**没做**的）

没有编译器时能做的检查都做了；做不到的没有一条被当作已完成。

做过的（可复现）：

| 项 | 方法 | 结果 |
| --- | --- | --- |
| 语法结构 | 逐文件剥离字符串与注释后统计括号 | 21 个 Swift 文件全部平衡 |
| 跨文件签名 | 把每个调用点与实现签名逐项人工对齐 | `EntryHost` → `ScriptBag` 13 个调用点全中；`SliderDrag` / `SliderSolver` / `CredentialRepository` / `CredentialStore` / `EntrySettings` 全部对上（详见下一节的存疑表与提要） |
| 滑块像素通道 | 比对解码侧与求解侧对同一 `Int32` 的位运算 | 解码 `(a<<24)\|(r<<16)\|(g<<8)\|b` ↔ 求解 `(p>>16)&0xFF` 等，**一致** |
| 页面脚本占位符 | 从 `shared/js`、PC `ScriptBag.cs`、iOS `ScriptBag.swift` 三处分别抽取 `__XXX__` | 5 个占位符三端**完全一致** |
| 页面脚本资源名 | iOS 的 12 个引用 ↔ `shared/js` 实际文件 ↔ PC csproj 的内嵌清单 | 12/12 一致，无缺无余 |
| 等价用例规模 | 与 PC 的 `[Fact]` + `[InlineData]` 逐文件对照 | 13+23+8+4+7 = **55 个 func**；PC 同样是 55 个方法（含 `[Theory]` 的向量共 **64 条**）。逐文件相等 |
| 工程文件结构 | 抽取全部 24 位 ID 与括号 | 29 个 ID 各恰好定义一次；括号平衡 |
| 应用图标 | 生成后回读像素格式 | 1024×1024，`Format24bppRgb`，**无 alpha**（iOS 硬要求） |
| 明文格式 | 逐字段比对版本字节、长度前缀、字段顺序、长度取低位 | 与另两端同一套（框架层） |

**未做的核验项**：

- **没有编译过一次**，没有链接过，没有在模拟器或真机上运行过。
- **没有运行过任何一条 XCTest**——55 个用例函数只是"写好了"，不是"通过了"。
- 界面没有出现过一次；深色模式、字号放大、无障碍播报、Keychain 真机存取全都未验证。
- 因此三端的"逻辑一致"目前是**通过对齐源码与用例文本**得到的，不是通过比对运行结果得到的。
- **PC 与 iOS 的用例逐文件相等（各 55 个方法），Android 不等（73 条）**（2026-09 审计核对）：
  Android 的 `SliderDragTest` 有 15 条（含真机那三次偏移的用例）而 PC/iOS 只有 8；
  `SliderSolverTest` 则是 PC 8 条、Android 5 条；`SuesTest` 是 Android 19 条、PC/iOS 分别为 18/13。
  **想做到三端逐条相等需要单独一轮补齐**（已记入审计待办）。

## 首次编译时必须确认的点（无工具链时逐项标注的存疑，均未解决）

这些是移植过程中**明确记录下来的不确定点**。没有编译器时它们无法排除，第一次在 Mac 上构建时应当逐个确认：

| # | 存疑点 | 影响 | 若出问题的方向 |
| --- | --- | --- | --- |
| 1 | `@MainActor` 类里覆写 NSObject 的 `observeValue`（KVO 回调）与 `WKScriptMessageHandler` / `WKNavigationDelegate` conformance 的隔离检查 | 可能报 actor 隔离错误 | 改用 KVO block 版，或对 conformance 加 `@preconcurrency` |
| 2 | Cookie 清理的确认判据 | `fetchDataRecords(ofTypes:)` 返回的是**数据类型记录**不是单个 cookie，清完后列表仍非空（localStorage/cache），PC 那句「清单为空才算清完」在 iOS 上永远不成立，会走满有界轮询再打日志 | 只查 `WKWebsiteDataTypeCookies`，或改查 `WKHTTPCookieStore` |
| 3 | `navigationAction.targetFrame == nil` 与 WebView2 `IsNewWindow` 的等价性 | 代理回调里同步 `load` 可能立刻再进一次决策回调（回调循环） | 改成下一个主队列轮次异步派发 |
| 4 | 滑块图解码的 alpha 预乘 | `CORE-SPEC §5.2` 要求**非预乘**像素，而 Core Graphics 的位图上下文不支持非预乘 alpha，`EntryHost.pixels(of:)` 只能先画进预乘缓冲 | **已按能确定正确的方向修**：读完缓冲后自己反预乘（等价 `vImageUnpremultiplyData_RGBA8888`），消除系统性偏差。**残余**：`A == 0` 的像素 RGB 已被乘成 0、不可逆，与 Android 的非预乘位图有真实差别；预期影响为零（透明区 RGB 一般就是 0，且掩码要求足够亮），但**要拿真实滑块图确认** |
| 5 | `Bundle.main.url(forResource: "probe.js", withExtension: nil, subdirectory: "js")` | 能不能取到取决于 folder reference 在 bundle 里的落点（预期是 `js/probe.js`） | 改成 `forResource: "probe", withExtension: "js"` |
| 6 | UA 处理：把 `Mobile` 换成桌面标记后，UA 里仍含 `iPhone` | 站点若按 `iPhone` 判手机，会走「与表单同页」的滑块形态（`CORE-SPEC §5.1` 同样覆盖，逻辑不变） | 改成整条桌面 UA |
| 7 | 工程文件是手写的、`objectVersion = 77` + 「同步文件夹」需要 **Xcode 16+** | 旧版 Xcode 打不开 | 用 `project.yml` + `xcodegen generate` 重建 |
| 8 | `SliderSolver` 有 `RgbaImage` 便捷重载，但 `EntryHost` 走的是 `[Int32]` 原始版本 | 两条路径的通道约定必须一致 | 已核对：`EntryHost` 打包 `0xAARRGGBB`，`SliderSolver` 提取 `>>16 / >>8 / &0xFF`，**一致** |
| 9 | `SliderDragTests` 里两条用例要读仓库根的 `shared/js`（用 `#filePath` 向上找） | 编译期绝对路径在**同一台 Mac 的模拟器**上有效，但**真机上读不到 Mac 的文件系统** | 真机跑测试时这两条会失败；要么只在模拟器跑，要么改成从 app bundle 读 `js/`（App 侧本来就以 folder reference 打进去，内容相同） |
| 10 | 55 个测试方法用的是中文名（`func test共享脚本都装着各自的占位符()`） | 若某版本的 XCTest 发现机制只认 ASCII selector，可能漏跑或报错——**症状很好认：跑出来的用例数不是 55** | 退路是把 5 个文件的 `func` 名换成 ASCII（如 `testPrefixShapeOnly`），用例数与断言一处不动 |
| 11 | `SliderSolverTests` 的「尺寸不合法」用例走 `RgbaImage` 入口 | C# 传的是「尺寸声明与实际缓冲不一致」，Swift 侧经 `pack` 会按 `width*height` 截断，属于**同结论、不同判据路径** | 三个子用例的结论都已推演为 `nil` 且与 C# 一致，但这是**最该先在 Mac 上复核的一处**；若要严格同路径，让用例直接调 `[Int32]` 原始入口 |

**已手工核对过的跨文件签名**（没有编译器，这是唯一的防线）：`EntryHost` 对 `ScriptBag` 的 13 个调用点全部存在；
`SliderDrag` 的 `parseProbe` / `makePlan` / `geometry.*` 与调用点一致；`SliderSolver.solve(_:_:_:_:_:_:)` 六个参数与
调用点一致；`CredentialRepository(_:_:)` 与 `CredentialStore(_:)` 的**无标签**构造已按实现改正；
`EntrySettings` 的 `prefix / saveAccount / saveDecided / hideNotices / save()` 全部存在。
另外修掉了 `EntryHost` 的一个真 bug：`onReady?()` 原本写在 `init` 内部，而调用方只能在拿到 init 返回值之后
才能给 `onReady` 赋值，那个事件永远收不到；已改为显式的 `start()`。
