# 教务直达 (CampusEntry for macOS)

上海工程技术大学（SUES）WebVPN 与教务系统原生 macOS 桌面客户端（Swift + AppKit + WKWebView）。

## 核心特性

- **双入口直达与状态机导航 (`EntryFlow` / `Sues`)**：支持「教务系统」与「WebVPN 门户」入口；自动识别已缓存的 WebVPN 前缀、处理 `wengine-vpn/failed` 换票中转页、探测门户前缀并限制自动续探次数，并在到达目标页面后立即停手，不劫持用户后续浏览。
- **本地加密凭据保存 (`CredentialStore` / `KeychainCryptoBackend`)**：凭据经版本化二进制编码后使用 macOS Keychain 中保存的对称密钥执行 AES-256-GCM 加密落盘，并在每次认证页自动提交后跟踪结果归因，避免错误凭据反复提交触发锁定。
- **滑块验证码自动定位与拟真拖拽 (`ImageDecoder` / `SliderSolver` / `SliderDrag`)**：使用 CoreGraphics 解码非预乘 `0xAARRGGBB` 图像数据，结合设备几何参数计算相对滑轨位移量并执行拖动。
- **共享页面脚本契约 (`ScriptBag`)**：直接打包并同步 `shared/js/` 下的 13 个页面脚本，统一门户探测、到达判定、CAS 状态观测、表单填充、滑块几何读取与公告抑制逻辑。
- **原生 AppKit 界面与自适应主题 (`Theme` / `MainWindowController` / `SettingsWindowController`)**：基于 `WKWebView` 构建单窗口浏览器界面，提供导航栏、状态提示、设置面板、菜单栏快捷键及自适应浅色/深色主题。

## 工程架构

```text
macos/
├── Package.swift                             # SwiftPM 清单 (macOS 13.0+)
├── Sources/
│   ├── CampusEntryCore/                      # 跨平台可测核心库
│   │   ├── CredentialStore.swift             # 版本化凭据编码与读写
│   │   ├── KeychainCryptoBackend.swift       # macOS Keychain + AES-256-GCM 后端
│   │   ├── EntryFlow.swift                   # 导航与判决归因状态机
│   │   ├── EntrySettings.swift               # 配置持久化 (~/Library/Application Support/CampusEntry/entry.json)
│   │   ├── ImageDecoder.swift                # 非预乘 PNG/DataURL 像素解码
│   │   ├── RunLogger.swift                   # 运行日志记录
│   │   ├── ScriptBag.swift                   # 共享 JS 资源加载与占位符替换
│   │   ├── SliderDrag.swift                  # 滑块几何换算与拖动计划
│   │   ├── SliderSolver.swift                # 滑块缺口匹配求解器
│   │   ├── Sues.swift                        # SUES 域名、前缀与页面判据
│   │   └── Resources/js/                     # 同步自 ../shared/js/ 的页面脚本
│   └── CampusEntry/                          # macOS AppKit 应用宿主
│       ├── App/                              # main.swift / AppDelegate.swift
│       ├── Host/                             # EntryHost.swift (WKWebView 与脚本桥接)
│       └── UI/                               # Theme / AppIconDrawer / 窗口控制器
├── Tests/
│   └── CampusEntryCoreTests/                 # 单元测试 (7 个测试套件，58 个测试用例)
└── scripts/
    ├── generate-icon.swift                   # 生成 #2F6FB5 圆角方形折纸图标 (.icns)
    └── build-app.sh                          # 同步脚本、Release 构建、打包 .app 与 .dmg
```

## 系统与芯片兼容性

- **操作系统**：macOS 13.0（Ventura）及以上版本。
- **芯片架构**：原生支持 **Apple Silicon（`arm64`）** 与 **Intel（`x86_64`）**。Swift Package Manager 默认按当前宿主架构编译；如需生成通用二进制（Universal Binary），可在构建时传入 `--arch arm64 --arch x86_64`。
- **运行与构建依赖**：
  - 仅使用系统原生框架（`AppKit`、`WebKit`、`Security`、`CryptoKit`、`ImageIO`、`CoreGraphics`），**零第三方 Swift / npm / pip 运行时或构建依赖**。
  - 本地编译与打包只需安装 **Xcode Command Line Tools**（`xcode-select --install`，含 Swift 工具链与 macOS SDK）或完整版 **Xcode**。

## 构建、测试与打包

### 1. 运行调试构建与单元测试

```bash
cd macos
swift build
swift test
```

或在仓库根目录执行：

```bash
swift build --package-path macos
swift test --package-path macos
```

> 注：若本机仅安装了 Xcode Command Line Tools（未安装完整 `Xcode.app`），`Package.swift` 会自动在 `CampusEntryCoreTests` 中附加 `libTestingMacros.dylib` 插件路径，以确保 `swift test` 可直接运行。

### 2. 打包 `.app` 与 `.dmg` 分发镜像

```bash
./scripts/build-app.sh
```

脚本依次完成以下步骤：

1. 若 `../shared/js/*.js` 存在，将其同步至 `Sources/CampusEntryCore/Resources/js/`；
2. 执行 `swift build -c release` 编译发布版二进制与 SwiftPM 资源包（`*.bundle`）；
3. 调用 `scripts/generate-icon.swift` 渲染 `#2F6FB5` 圆角方形底板与白色折纸矢量图标并生成 `CampusEntry.icns`；
4. 组装 `dist/CampusEntry.app`（写入 `Info.plist`：`CFBundleDisplayName` 为 `教务直达`，`CFBundleIdentifier` 为 `cn.edu.sues.campus-entry`，`CFBundleShortVersionString` 为 `1.0.0`，`LSMinimumSystemVersion` 为 `13.0`，开启 `NSHighResolutionCapable` 及严格的 `NSAppTransportSecurity` 默认策略）；
5. 使用 `codesign --deep --force -s -` 进行本地 ad-hoc 签名并校验；
6. 使用 `hdiutil create` 生成带 `Applications` 快捷方式的 `dist/CampusEntry-1.0.0-macOS.dmg`。

## CI 与发布

- `.github/workflows/macos.yml`：改动 `macos/**` 或 `shared/js/**` 时触发，依次跑 `swift test`、
  `build-app.sh --universal`、`lipo -archs` 双架构断言、`codesign --verify`，并把 `.dmg` 作为
  artifact 上传。**本机没有 macOS 时，这条流水线就是唯一的编译验证。**
- `.github/workflows/release.yml`：推送 `v*` tag 时构建 macOS 包。若同名 release 已存在则追加
  dmg，否则创建**草稿** release——APK / EXE 仍由维护者手工附上，避免发出只带一个平台的正式版。

### 签名与分发边界

- 当前是 **ad-hoc 签名**，不是 Developer ID，也没有公证。别人下载 DMG 后 Gatekeeper 会拦，
  需要右键「打开」；被 quarantine 标记时可 `xattr -d com.apple.quarantine /Applications/教务直达.app`。
- ad-hoc 签名的 designated requirement 是 cdhash，**每次重建都会变**：Keychain 里那条密钥可能
  重新弹授权（系统弹窗，属预期）。要消除这一点，只能用固定的 Developer ID 证书签名。
- 要正式分发，需要 Developer ID + `notarytool` 公证 + `stapler`。证书与 App Store Connect 凭据
  **只放仓库 Actions secrets**，不要进仓库，也不要放在个人机器上代签——否则二进制的信任锚会变成
  某个人的开发者账号。

## 与上游规范对齐

- **`shared/js/`**：页面 DOM 探测、CAS 观测、自动填充、滑块拖动与公告关闭脚本均直接复用仓库根目录 `shared/js/` 契约；`build-app.sh` 构建前会自动执行同步。
- **`docs/CORE-SPEC.md`**：`Sues`、`EntryFlow`、`SliderSolver`、`SliderDrag` 与 `CredentialStore` 严格实现核心规范中的 URL 前缀形状判据、状态迁移、设备几何换算公式及凭据落盘格式。`CampusEntryCoreTests` 覆盖 §7 的判据、解析与几何向量；**尚未覆盖**页面级（DOM）向量与滑块真值图像语料，见下文「已知缺口」。
- **`DESIGN.md`**：界面颜色令牌（主色 `#2F6FB5` / 深色模式 `#5B9BD5`、状态色、幽灵按钮状态层）、工具栏尺寸与品牌折纸图标几何比例均与 `DESIGN.md` 对齐。

## 已知缺口

以下三项是 2026-11 评审确认的覆盖缺口，不是"待办清单"里的可选项——`docs/CORE-SPEC.md` 都点过名：

1. **宿主层零自动化用例。** `EntryHost` 里的"≤2 次自动提交""≤3 次拖动""20 s / 15 s 超时"
   "待判决归因""`about:blank` 记账"全靠人工验证。PC / Android 各有 4 项真机宿主用例，
   macOS 还没有；§4.0 记录的那个"自动登录偶发静默失效"正是宿主测试才查出来的。
2. **滑块只有合成用例。** 合成图里模板就是背景的裁剪，`TM_CCORR_NORMED` 与 `TM_CCOEFF_NORMED`
   给出同一答案——把度量改错，现有 7 条用例仍会全绿。§5.2 要求用真值语料回归。
3. **没有页面级（DOM）用例。** `armed` 门禁、`<div>` 嵌套不截断、`<br>` 不算嵌套、
   HTML 实体解码这几条只在 Android 的 `PageDomTest` 里被钉住；macOS 的 `shared/js` 副本
   目前只有"文件在、占位符都替换了"的完整性测试。
