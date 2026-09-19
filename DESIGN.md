---
version: alpha
name: 教务直达
description: 教务直达（Android / PC / iOS 三端）的设计系统。安静的墨蓝、克制的层级、一句话说得清的状态。
colors:
  primary: "#2F6FB5"
  primary-deep: "#24548A"
  ink: "#1A1C1E"
  secondary: "#6C7278"
  neutral: "#F5F7FA"
  surface: "#FFFFFF"
  line: "#E3E3E3"
  success: "#2E7D5B"
  warning: "#8F5500"
  error: "#B3261E"
typography:
  headlineSmall:
    fontFamily: system-ui
    fontSize: 24px
    fontWeight: 600
    lineHeight: 1.3
  titleMedium:
    fontFamily: system-ui
    fontSize: 16px
    fontWeight: 600
    lineHeight: 1.4
  titleSmall:
    fontFamily: system-ui
    fontSize: 14px
    fontWeight: 600
    lineHeight: 1.4
  bodyLarge:
    fontFamily: system-ui
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.5
  bodyMedium:
    fontFamily: system-ui
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.5
  bodySmall:
    fontFamily: system-ui
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.5
  labelLarge:
    fontFamily: system-ui
    fontSize: 14px
    fontWeight: 500
    lineHeight: 1.2
  labelMedium:
    fontFamily: system-ui
    fontSize: 12px
    fontWeight: 500
    lineHeight: 1.2
  labelSmall:
    fontFamily: system-ui
    fontSize: 11px
    fontWeight: 500
    lineHeight: 1.2
rounded:
  none: 0px
  xs: 4px
  sm: 8px
  md: 12px
  lg: 16px
  xl: 24px
  full: 9999px
spacing:
  xs: 4px
  sm: 8px
  md: 12px
  lg: 16px
  xl: 20px
  2xl: 24px
  3xl: 32px
  touch: 48px
components:
  screen:
    backgroundColor: "{colors.neutral}"
    textColor: "{colors.ink}"
    typography: "{typography.headlineSmall}"
    padding: "{spacing.2xl}"
  card-entry-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.surface}"
    typography: "{typography.titleMedium}"
    rounded: "{rounded.lg}"
    padding: "{spacing.xl}"
    height: 88px
  card-entry-primary-pressed:
    backgroundColor: "{colors.primary-deep}"
    textColor: "{colors.surface}"
    typography: "{typography.titleMedium}"
    rounded: "{rounded.lg}"
    padding: "{spacing.xl}"
    height: 88px
  card-entry:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    typography: "{typography.titleMedium}"
    rounded: "{rounded.lg}"
    padding: "{spacing.xl}"
    height: 88px
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.surface}"
    typography: "{typography.labelLarge}"
    rounded: "{rounded.md}"
    padding: "{spacing.md}"
    height: 48px
  button-ghost:
    backgroundColor: "{colors.neutral}"
    textColor: "{colors.primary}"
    typography: "{typography.labelLarge}"
    rounded: "{rounded.md}"
    padding: "{spacing.md}"
    height: 48px
  button-danger-text:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.error}"
    typography: "{typography.labelLarge}"
    rounded: "{rounded.md}"
    padding: "{spacing.md}"
    height: 48px
  bar:
    backgroundColor: "{colors.surface}"
    height: 48px
  bar-tab:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.secondary}"
    typography: "{typography.labelSmall}"
    rounded: "{rounded.none}"
    height: 48px
  bar-tab-active:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.primary}"
    typography: "{typography.labelSmall}"
    rounded: "{rounded.none}"
    height: 48px
  status-pill:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    typography: "{typography.labelMedium}"
    rounded: "{rounded.full}"
    padding: "{spacing.md}"
    height: 32px
  status-pill-alert:
    backgroundColor: "{colors.warning}"
    textColor: "{colors.surface}"
    typography: "{typography.labelMedium}"
    rounded: "{rounded.full}"
    padding: "{spacing.md}"
    height: 32px
  status-pill-done:
    backgroundColor: "{colors.success}"
    textColor: "{colors.surface}"
    typography: "{typography.labelMedium}"
    rounded: "{rounded.full}"
    padding: "{spacing.md}"
    height: 32px
  sheet:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    typography: "{typography.bodySmall}"
    rounded: "{rounded.xl}"
    padding: "{spacing.2xl}"
  input-field:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    typography: "{typography.bodyLarge}"
    rounded: "{rounded.sm}"
    padding: "{spacing.md}"
    height: 48px
  field-label:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.secondary}"
    typography: "{typography.bodyMedium}"
  list-row:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    typography: "{typography.bodyMedium}"
    rounded: "{rounded.none}"
    padding: "{spacing.lg}"
    height: 52px
  list-row-two-line:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    typography: "{typography.bodySmall}"
    rounded: "{rounded.none}"
    padding: "{spacing.lg}"
    height: 66px
  divider:
    backgroundColor: "{colors.line}"
    height: 1px
  checkbox-checked:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.surface}"
    rounded: "{rounded.xs}"
    size: 20px
---

# 教务直达 设计系统

## Overview

这是一款**每天用两次、每次不超过十秒**的校园工具。视觉身份是「安静的可靠」：一个冷静的墨蓝、大面积的留白、圆角卡片、几乎不用阴影。它不试图讨人喜欢，只试图让人觉得**事情已经办妥了**。

参照物是学校的公告栏与教材封面，不是社交产品：信息层级少、字号克制、没有渐变、没有插画、没有动效炫技。整个应用一次只讲一句话——现在的状态是什么，下一步会发生什么。

界面必须能在**系统字号放大到 1.1 倍**（真机实测值）时仍然单行不折、不裁切；所有可点区域的触控目标不小于 48px。

## 身份：名称与应用标记

**显示名与标识名是两回事，改名时不能混。**

| | 值 | 用在哪 |
| --- | --- | --- |
| 显示名 | **教务直达** | 窗口标题、任务栏、界面文案 |
| 标识名 | **CampusEntry** | exe 文件名、命名空间、程序集名、资源逻辑名、数据目录 |
| 协议前缀 | **campus-entry** | 注入脚本与宿主之间的日志前缀（见下） |

**持久化键永远不跟着显示名改。** 改 `%LOCALAPPDATA%\CampusEntry\` 或 iOS 的 Keychain 服务名，用户机器上已保存的账号就读不到了，他们看到的是"突然要我重新登录"——像登录坏了，实际是数据被另起炉灶。所以改名只动显示层。三端各自的位置写在 `EntrySettings.cs`、`MainActivity.kt`、`KeychainCryptoBackend.swift` 的注释里。

**协议字符串同理。** `shared/js/notice-dialog.js` 的 `LOG` 前缀与 Android `EntryHost.onConsoleMessage` 的前缀判据必须**逐字一致**，它是一条跨端契约，不是文案。

**非官方是硬约束。** 这是一个个人做的快捷入口，**任何界面都不能看起来像学校官方应用**：不使用校徽、校名、印章、官方配色；首次运行横幅必须写明「非官方：这是个人做的教务系统快捷入口，与学校无关。」；账号密码只在学校自己的统一身份认证页上输入，应用不代收。

### 应用标记

白色描边（**不填充**）的**折角纸**，配品牌蓝底板。2026-09 由「门洞 + 圆角方底 + 实心几何」改为本方案。

- **标记几何三端一致，只有底板形状按平台惯例不同。** Windows 自己画完整外形（**圆形满底**——系统不会给窗口图标加遮罩）；Android 与 iOS 画**满幅方形**，外形遮罩由系统施加（自己再画圆角会得到"圆套圆"的脏边）。
- **对比度**：白色描边对 `#2F6FB5` 是 **5.2:1**，高于 WCAG 对图形元素要求的 3:1。曾评估参照图的薄荷绿 `#54CAB2`，只有 **2.0:1**，未采用；同色相加深到 `#2AA089` 可得 3.2:1，留作备选。
- **小尺寸做光学简化，不是等比缩小**：≤ 20px 时纸面撑大、内部两条文字线去掉——1px 的线挤进 8px 宽的纸面只会糊成一团。阈值写在 `pc/tools/make-app-icon.ps1` 里，三端同源。

## Colors

- **Primary (#2F6FB5):** 交互蓝。全应用**唯一**的驱动色，只用于「当前入口」和唯一的主动作。它出现在哪里，用户的下一步就在哪里。禁止用它做装饰、分隔或图标底色。
- **Primary Deep (#24548A):** 交互蓝的按下态。只用于按压反馈，不单独出现。
- **Ink (#1A1C1E):** 墨色，承载标题与正文。不用纯黑——纯黑在深色模式与浅色页面上都显得生硬。
- **Secondary (#6C7278):** 石板灰，用于未激活的标签、字段标签与辅助说明。它是「在场但不重要」的颜色。
- **Neutral (#F5F7FA):** 页面底色。卡片浮在它上面，靠明度差而不是阴影分层。
- **Surface (#FFFFFF):** 卡片、底栏、抽屉与输入框的底色。
- **Line (#E3E3E3):** 唯一的分隔线颜色。1px，只用在底栏上沿这类必要位置。
- **Success (#2E7D5B) / Warning (#8F5500) / Error (#B3261E):** 状态语义色。**只在需要用户改变行为时出现**：Success 表示「已办妥」，Warning 表示「需要你出手」，Error 表示「它错了，不是你错了」。三者都不得用作装饰。

## Typography

字体一律用**系统默认字体**（`system-ui`）：Android 落到 `FontFamily.Default`（Roboto / 思源黑体），Windows 落到 Segoe UI，iOS 落到 SF Pro。中英混排由系统字体保证，**不打包任何自定义字体**——省体积，也避免中文回退到错误的字重。

层级只保留三档，对应三种角色：

- **headlineSmall (24/600):** 只出现在首页大标题。一个应用只有一处。
- **titleMedium / titleSmall (16/600、14/600):** 卡片标题与需要强调的标签。
- **bodyLarge / bodyMedium / bodySmall (16、14、12 / 400):** 正文、辅助说明、脚注。
- **labelLarge / labelMedium / labelSmall (14、12、11 / 500):** 按钮文字、状态胶囊、底栏标签。

一屏之内最多出现**两种字重**（400 与 600）。不用斜体，不用全大写。

## Layout

本设计系统面向三端，`px` 数值的落地映射为：

- Android / Jetpack Compose：`spacing` 与 `rounded` 的 `px` → **dp**（`20px` → `20.dp`）；`typography.fontSize` 的 `px` → **sp**（`16px` → `16.sp`）；`lineHeight` 的无单位倍数 → `.em`。
- Windows / WPF：`spacing` 与 `rounded` 的 `px` → **DIP**（`16px` → `16`，WPF 无单位即设备无关像素）；**但 `typography.fontSize` 不得直接沿用**，必须换用下方「落到 PC 时」那一档桌面字号。
- iOS / SwiftUI：`px` → **pt**（`16px` → `16.pt`），字号**同样**不复用手机档，另按 iOS 平台惯例定。
- 间距走 **4px 基准的 8px 节奏**（4 / 8 / 12 / 16 / 20 / 24 / 32）。
- 页面左右安全边距统一 `spacing.2xl` (24px)；卡片内部 `spacing.xl` (20px)。
- **触控目标不小于 `spacing.touch` (48px)**，视觉尺寸可以更小，但可点区域必须补足。
  这一条是**触屏约束**：鼠标端不适用，鼠标目标按桌面惯例（见「落到 PC 时」）。
- 底栏固定 48px，图标与标签同排；状态胶囊 32px，贴在底栏正上方。

## Elevation & Depth

深度靠**明度分层**，不靠阴影：页面底色 `neutral`，内容放在 `surface` 上，再往下不再有第三层。唯一例外是账号抽屉——它用 `surface` + 半透明黑色遮罩浮起，此时阴影是必要的。

不用投影表达「卡片可点」。可点性由颜色和 `state layer`（按下时叠加 `onSurface` 12% 透明度）表达。

## Shapes

形状语言是**柔和但规整**：卡片 16px，按钮与输入框 12px，状态胶囊与复选框取 `full`。分隔线不带圆角。

规则只有一条：**同一屏内不混用直角与圆角**。抽屉顶部两角 24px，底角为直角（贴屏幕下沿）。

## Components

- **card-entry-primary:** 首页的主入口（教务系统）。整块可点，蓝底白字，88px 高。
- **card-entry:** 首页的次入口（WebVPN）。白底墨字、1px 描边，与主卡同尺寸——**不缩小、不弱化到看不清**，只是不上色。
- **bar / bar-tab / bar-tab-active:** 浏览页底栏。「教务系统 / WebVPN / 账号」三项等宽，激活项用 `primary`，其余用 `secondary`。
- **status-pill / status-pill-alert / status-pill-done:** 一句话交代当前状态。普通状态用白底墨字；需要用户出手时用 `warning`；办妥时用 `success`。
- **button-primary / button-ghost / button-danger-text:** 主动作、次动作、破坏性动作。破坏性动作永远是文字按钮，**不做成实心红按钮**，避免误触。
- **sheet:** 账号抽屉。顶部圆角，内部行高 56px。
- **input-field / field-label:** 仅在需要用户输入时使用。**密码类字段不存在于本设计系统的界面里**（见 `docs/APP-UX.md` 的凭据边界）。
- **divider:** 1px 分隔线，只用在底栏上沿与抽屉分组之间。

## Do's and Don'ts

- Do 每屏只有一个 `primary` 色的元素；它必须就是下一步。
- Do 用一句话说清状态，动词开头（「正在自动填写账号…」「已进入教务系统」）。
- Do 在用户出手前就把话说清楚：需要他做什么、为什么、做完会怎样。
- Do 保持 4.5:1 以上的文字对比度；深色模式下同步校验。
- Don't 用颜色表达「可点」以外的任何含义。
- Don't 用 toast、弹窗堆叠或加载遮罩；状态用胶囊与抽屉内的行内文案表达。
- Don't 在界面里出现自绘的账号/密码输入框。
- Don't 用动画表达进度；进度用文字与真实百分比。
- Don't 在深色模式下强制反色学校页面——登录页必须保持原样可读。

## 落到 Android 时本文件表达不了的语义

这些必须在写代码时主动处理，不能默认由 token 推导出来：

- **State layer / ripple:** 按下、聚焦态的叠加色，M3 用 `onSurface` 按透明度叠加。
- **Tonal elevation:** M3 用色调而非阴影表达层级；抽屉以外的面不要加 `shadow`。
- **动态取色（Material You，API 31+）:** 本应用**关闭**动态取色。品牌蓝是产品身份的一部分，且状态语义色（success/warning）被壁纸改色会误导用户。
- **深色模式:** 支持跟随系统，但 WebView 内**不启用**算法反色（`isAlgorithmicDarkeningAllowed = false`），学校页面保持原样。
- **无障碍:** 每个图标按钮要有 `contentDescription`；状态变化用 live region 播报；TalkBack 顺序为「页面内容 → 状态 → 底栏」。
- **字号放大:** 真机 `font_scale` 实测 1.1×，所有单行文案按 1.3× 预留宽度。

## 落到 PC（Windows）时本文件表达不了的语义

PC 端是**桌面窗口**，不是手机界面放大，也不是把手机界面居中。颜色 token 与语义角色（primary 是唯一驱动色、破坏性动作不做实心红、深度靠明度分层）全部沿用；**字号与密度必须重定**。以下每一条都是被实测推翻过假设的地方，不能由 token 推导出来：

### 字号：手机档不能当 DIP 用

`typography` 里的 `labelSmall 11px` 是给 6 寸屏底栏标签的。在 1080 DIP 宽的桌面窗口里，11px 比学校页面正文还小，会形成「大框小字」——这是最容易被忽略、也最容易被用户一眼看出的失真。桌面按下面的档位重新定义，**角色与 `typography` 一一对应，只换数值**：

| 角色 | DESIGN.md 手机档 | PC 落地档（DIP） | 用在哪 |
| --- | --- | --- | --- |
| caption | bodySmall 12 | **12** | 辅助说明、对话框脚注、页面标题 |
| body | bodyMedium 14 | **13** | 工具栏状态、对话框正文 |
| label | labelLarge 14 | **13** | 按钮文字、页签、字段标签 |
| title | titleMedium 16 | **15** | 对话框标题、分组标题 |
| appName | — | **13 / 600** | 自绘标题栏的应用名 |

一屏之内仍然最多两种字重（400 与 600），页签的选中态**不靠加粗**表达（会在切换时引起横向抖动），靠主色 + 底边指示条。

### 图标：用 Windows 的原生图标字体，不用文本字形

`←` `→` `⟳` `⚙` `×` 这类字符来自 Segoe UI 与符号字体的**回退链**：笔画粗细、字形大小、基线彼此不一致，高 DPI 下无法对齐，也无法跟随 `Foreground` 统一换色。Windows 的原生图标来源是 **`Segoe Fluent Icons`**（Win11；`Segoe MDL2 Assets` 作为 Win10 回退），矢量、随 DPI 重光栅化、颜色跟随前景色：

| 用途 | 码位 |
| --- | --- |
| 后退 / 前进 / 刷新 | `E72B` / `E72A` / `E72C` |
| 设置（齿轮） | `E713` |
| 最小化 / 最大化 / 还原 | `E921` / `E922` / `E923` |
| 关闭 | `E8BB` |
| 勾选（复选框） | `E73E` |

应用自身的标记（圆形满底 + 白色描边折角纸）用矢量画（`Ellipse` + `Path`），与 `pc/tools/make-app-icon.ps1` 共用同一套几何比例。

### 状态层与密度（鼠标端）

- **悬停 / 按下**：`#EDF1F6` / `#E2E9F1`；窗口按钮悬停 `#E9EDF2`，关闭键悬停 `#C42B1C` 白字（Windows 惯例，这是唯一允许红色实心的地方）。
- **鼠标目标**：工具栏图标按钮 36×36、窗口按钮 46×36、对话框按钮高 36。触屏的 48px 不适用。
- **工具栏高 44**，分隔线高 20 且与内容等高（不是一条高过文字的孤立竖线）。
- **密度基准**：`E.1` 标题栏 36 / 工具栏 44 / 横幅 padding 14×9 / 对话框内容 20。

### 边框与标题栏

窗口是**自绘标题栏**：应用标记 + 应用名 + 当前页面标题 + 系统样式的三个窗口按钮。落地用 WPF 原生 `WindowChrome`（`CaptionHeight` + `ResizeBorderThickness` + `IsHitTestVisibleInChrome`），**拖动、双击最大化、贴边贴靠、Alt+Space 系统菜单全部保持系统行为**。

两条硬约束（都踩过）：

1. **不要写 `WindowStyle="None"`。** 它会连带去掉 `WS_CAPTION`，系统对"无标题栏窗口"做最大化时按整个显示器算尺寸、无视任务栏。保留默认窗口样式即可——`WindowChrome` 通过 `WM_NCCALCSIZE` 把非客户区清零，系统标题栏本来就不会被绘制。
2. **圆角交给 DWM**（`DWMWA_WINDOW_CORNER_PREFERENCE`）。自己画的圆角只是"看起来圆"，窗口矩形仍然是方的，四角会露出窗口底色。

### 窗口图标是一项资产，不是可选项

没有 `Icon` 的窗口会在标题栏与任务栏显示框架的默认占位图标（一眼"半成品"）。图标由 `pc/tools/make-app-icon.ps1` 生成多尺寸 `.ico`：16/20/24/32/40/48 用 32bpp BMP、64/128/256 用 PNG，每个尺寸**原生绘制**而不是缩放大图。

### 无障碍

每个图标按钮必须有 `AutomationProperties.Name`；"当前入口"用 `RadioButton`（互斥语义）而不是手工换色的 `Button`，读屏才会正确播报。

## 落到 iOS 时本文件表达不了的语义

iOS 与 Android 同属**手机形态**，所以 `typography` 那一档可以照用（与 PC 相反）；不同的只是平台机制。

- **单位**：`px` → **pt**（`16px` → `16.pt`），字号沿用手机档（`titleMedium 16` / `bodyMedium 14` / `bodySmall 12` / `labelMedium 12` / `labelSmall 11`），**不要**套用 PC 那套桌面字号。
- **字体**：系统默认（SF Pro / 苹方），**不打包自定义字体**——与 Android 同样的理由。
- **深色模式**：本文件只给了浅色 token，深色取值取 **Android 端 `Theme.kt` 的 `DarkColors`**（`primary #5B9BD5`、背景 `#121417`、面 `#1B1E22`、墨 `#E8EAED`、次要 `#A2A9B0`、线 `#2C3136`、成功 `#6FBF95`、警告 `#E0A85C`、错误 `#F2B8B5`），落地在 `ios/CampusEntry/App/Theme.swift`。**不要只做浅色**——那会在深色系统下变成一片刺眼的白。唯一例外：Android 没有定义深色下的 `primary-deep`（它只作按下态用），iOS 侧按下态是从 `primary` 派生的，已在代码里标注。
- **图标**：用 **SF Symbols**（`Image(systemName:)`）。它就是 iOS 的原生图标来源，地位对应 Windows 的 `Segoe Fluent Icons`、Android 的 Material Symbols。**不要**用 emoji 或普通文字充当图标。
- **触控目标**：`spacing.touch` (48) 在 iOS 上**适用**（iOS 也是触屏），与 Android 同一条约束。
- **底栏**：48pt，图标与标签同排；状态胶囊贴在底栏正上方——与 Android 完全一致。
- **应用图标**：**满幅正方形、不画圆角、不能有 alpha**（圆角与遮罩由系统施加；带透明会被 Xcode 与 App Store 拒绝）。现代 Xcode 只需一张 1024×1024，由 `ios/tools/make-app-icon.ps1` 生成。底板形状与 Windows 不同是刻意的，理由见上面「应用标记」一节。
- **无障碍**：每个图标按钮要有 `accessibilityLabel`；"当前入口"要能被读屏正确播报；破坏性动作必须走系统确认弹窗（`.alert` + `role: .destructive`）。
