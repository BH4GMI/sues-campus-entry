# 教务直达（CampusEntry）

上海工程技术大学教务系统与 WebVPN 门户的快捷入口，提供 Windows 与 Android 两端实现。
应用只做两件事：打开系统，并在用户同意后自动完成登录；不导入任何数据。

应用显示名为「教务直达」，两端一致；磁盘与工程上的标识（可执行文件名、命名空间、数据目录、
工程名）保持 `CampusEntry` 不变。本项目为非官方个人工具，与学校无关，界面上不使用校徽、
校名与印章。

## 功能

- **默认入口：教务系统。** 走统一身份认证的 SSO 支点 `/student/sso/login`，免二次登录；登录后
  落在教务系统首页即停手，页面交给用户。
- **次要入口：WebVPN 门户。** 需要门户内的其它资源时使用；它不会把用户带进教务系统。
- **自动登录。** 应用不自绘输入框，账号密码只在学校的统一身份认证页上输入。用户同意后，把
  **提交时刻**的凭据加密存入平台密钥库，冷启动时自动填写并提交。
- **失败处置。** 密码错误立即删除已存凭据、停用自动登录，并提示服务端剩余次数；服务端累计
  5 次锁定账号，应用不重试。判定规则见 `docs/CORE-SPEC.md` §6。
- 另含滑块验证码自动拖动、「密码已过期」页自动跳过、教务系统首屏公告弹窗按开关收起。

## 两端

| 端 | 技术 | 目录 | 状态 |
| --- | --- | --- | --- |
| Windows | C# / .NET 8 / WPF / WebView2 | `pc/` | 已实现，真实链路实测通过，见 `pc/README.md` |
| Android | Kotlin / Compose / WebView | `android/` | 已实现，单测 73 项、真机仪表测试 20 项通过 |

## 仓库结构

```
shared/js/   两端共用的页面契约脚本（物理上只有这一份）
docs/        跨端契约与实测记录
DESIGN.md    两端视觉 token 的唯一来源
pc/          Windows 端源码、测试与工具
android/     Android 端源码、测试与工具
```

页面契约脚本不复制：Android 以 `assets.srcDir` 打包、Windows 以内嵌资源链接，
改一处两端同时变。

## 文档

| 文档 | 内容 |
| --- | --- |
| `docs/PROTOCOL.md` | 实测的登录链路：网关地址与编码、SSO 支点、门户资源接口、会话特性、认证页要素。改动任何一端前先读它 |
| `docs/CORE-SPEC.md` | 跨端共用的纯逻辑：落点规则、页面身份判据、停手规则、滑块算法与等价测试向量 |
| `docs/APP-UX.md` | 页面逻辑、交互流程、凭据生命周期与安全边界；§9 分期与验证矩阵，§10 已修缺陷 |
| `DESIGN.md` | 两端视觉 token（颜色 / 字体 / 间距 / 圆角 / 组件），可用 `designmd lint` 校验 |
| `pc/README.md` | Windows 端的实现说明、实测记录与已知限制 |

## 构建与测试

### Windows

```powershell
cd pc
dotnet test tests\CampusEntry.Tests\CampusEntry.Tests.csproj    # 70 项单测
dotnet run --project src\CampusEntry
```

### Android

```bash
cd android
./gradlew :app:testDebugUnitTest :app:assembleDebug             # 73 项单测 + 出包
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

真机仪表测试（需连接设备）：

```bash
./gradlew :app:assembleDebug :app:assembleDebugAndroidTest
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb install -r -t app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb shell am instrument -w app.webvpn.entry.test/androidx.test.runner.AndroidJUnitRunner
```

### Android 签名与变体测试

发布包用本地 keystore 通过 AGP 的注入式签名参数构建，口令不落入任何文件：

```bash
./gradlew :app:assembleRelease \
  -Pandroid.injected.signing.store.file=<keystore 路径> \
  -Pandroid.injected.signing.store.password=<store 口令> \
  -Pandroid.injected.signing.key.alias=<别名> \
  -Pandroid.injected.signing.key.password=<key 口令>
```

测试包必须与应用**同变体**：Kotlin 会给 `internal` 成员加变体后缀（`newTab$app_debug` /
`newTab$app_release`），拿 debug 测试包去测 release 应用会以 `NoSuchMethodError` 失败。
测 release 时用：

```bash
./gradlew :app:assembleReleaseAndroidTest -PtestBuildType=release
```

## 测试覆盖的分层

| 层 | Windows | Android |
| --- | --- | --- |
| 判据与状态机（`Sues` / `EntryFlow`） | 单测 70 项 | 单测 73 项 |
| 页面脚本的 DOM 层（`shared/js`） | 经宿主层用例间接覆盖 | 真机 WebView 8 项（含 `<div>` / `<br>` / `&amp;` 向量） |
| 宿主层接线（`EntryHost`） | 真机 WebView2 4 项 | 真机 WebView 4 项 |
| 平台存储（DPAPI / AndroidKeyStore） | 单测 | 真机 8 项 |

宿主层用例测的是「判据有没有被接上」，而不是判据本身——判据与状态机全对、只有接线错时，
单测抓不到。两端的宿主层用例都做过红测：短路对应的闸门后，用例当场失败。

Windows 宿主层用例的运行约束：WebView2 需要 STA 线程与消息泵，用例在一条 STA 线程上创建
`Dispatcher` 与离屏窗口；页面通过 `WebResourceRequested` 拦截，使用真实 URL 与本地伪造响应，
因此不产生任何网络流量；数据目录经 `EntrySettings.DataDirectory` 指向临时目录，不触碰用户
真实的 `entry.json` 与凭据。

## 边界

- 本仓库只做「打开系统」这一件事。课表导入（`get-data` / `.wakeup_schedule`）属于其它项目，
  不在范围内。
- 会话均为会话级 cookie，冷启动必然重新认证一次；这是学校站点的行为，不是本应用的缓存策略。
