import Foundation

//  ScriptBag.swift —— 从 pc/src/CampusEntry/Core/ScriptBag.cs 逐条移植。
//
//  页面契约 JS 的唯一来源仍然是仓库根 `shared/js/`（13 个文件，与 Android 端同一批物理文件，
//  见 ios/project.yml：`../shared/js` 以 `type: folder` 进包）。这里只负责加载与填充占位符；
//  改文件等于改三端的页面契约——先改 docs/CORE-SPEC.md 与 docs/PROTOCOL.md，再动文件。
//
//  ## 与 PC 端的三处平台差异（本文件的全部非机械改动）
//
//  1. **资源位置**：PC 端把 `shared/js/*.js` 作为程序集内嵌资源读取（LogicalName 形如
//     `CampusEntry.js.probe.js`）；iOS 侧改成 **bundle 资源**，相对路径就是 `js/<name>.js`
//     （folder 形式进包，Bundle 根下就是 `js/`）。因此这里用
//     `Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "js")`。
//  2. **JS → 原生**：PC 端走 WebView2 的 `window.chrome.webview.postMessage(m)`；iOS 侧走
//     **`window.webkit.messageHandlers.entry.postMessage(m)`，通道名固定 `entry`**
//     （宿主 `EntryHost` 用 `contentController.add(self, name: "entry")` 注册）。
//  3. **原生 → JS**：宿主是 `webView.evaluateJavaScript(...)`。WKWebView **直接回传原生对象**
//     （`String` / `NSNumber` / `NSDictionary`），不像 WebView2 那样把返回值再 JSON 包一层引号，
//     所以 **iOS 侧没有 Unquote** —— `EntryHost.eval` 只保留「非字符串结果不当字符串用」这一层
//     防御。同理，垫片 `post({cmd:…})` 的载荷到宿主手里已经是原生字典，不必再解析 JSON 文本。
//
//  ## 垫片的形状（三端必须一致：`EntryHost.userContentController(_:didReceive:)` 按 `cmd` 分派）
//
//  | 共享 JS 里的调用                  | 消息体                                                       |
//  | --------------------------------- | ------------------------------------------------------------ |
//  | `window.entry.armed(a, e)`        | `{cmd:'armed', armed:!!a, expectsSlide:!!e}`                 |
//  | `window.entry.captcha(b, s)`      | `{cmd:'captcha', bg:b, sl:s}`                                |
//  | `window.entry.credential(u, p)`   | `{cmd:'credential', username:u, password:p}`                  |
//  | `window.entry.log(m)`             | `{cmd:'log', message:String(m)}`                              |
//
//  共享 JS 里实际会调用的是 `armed` 与 `credential`（`notice-dialog.js` 只走 `console.log`）；
//  另两条保留是为了与 PC/Android 两端完全一致。垫片只做转发，不含任何判断，
//  并且先判 `if(window.entry)return;` 保证幂等（每份文档创建前注入一次）。
//
//  ## 占位符（与 C# 完全一致，名字一个都不许改）
//
//  | 占位符             | 文件               | 替换值                                        |
//  | ------------------ | ------------------ | --------------------------------------------- |
//  | `__EXPIRED_MARK__` | cas-state.js       | `Sues.passwordExpiredMark`                    |
//  | `__DELTA__`        | drag.js            | `plan.delta`，固定两位小数、小数点必须是 `.`   |
//  | `__USERNAME__`     | fill-and-submit.js | `jsLiteral(username)`                         |
//  | `__PASSWORD__`     | fill-and-submit.js | `jsLiteral(password)`                         |
//  | `__HIDE__`         | notice-dialog.js   | `"true"` / `"false"`                          |
//
//  余下 8 个文件（probe / tick-notice / skip-expired / captcha-watch / captcha-stop /
//  slider-geometry / credential-watch / credential-stop）不带占位符，原样注入。

/// 页面契约 JS 的唯一来源：仓库根 `shared/js/`（与 Android / PC 端同一批文件，这里打包成 bundle 资源）。
/// 只负责加载与填充占位符。
public enum ScriptBag {

    /// 已读入并填好占位符之前的原文缓存（对应 C# 的 `private static readonly Dictionary<string, string> Cache`）。
    private static var cache: [String: String] = [:]

    /// C# 用 `lock (Cache)` 保护缓存；Swift 的静态变量没有内建锁，这里用同一把互斥锁。
    private static let cacheLock = NSLock()

    /// 读一段共享脚本的原文（去掉尾部空白，空文件算错）。
    private static func raw(_ name: String) -> String {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "js") else {
            // C# 抛 InvalidOperationException。这里对应的是打包错误（js/ 没进包）：
            // 立刻大声失败，绝不静默返回空脚本——空脚本的表现是「页面契约静默失效」，最难查。
            fatalError("bundle 资源里没有 js/\(name)")
        }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            fatalError("bundle 资源 js/\(name) 读不出来：\(error)")
        }
        let trimmed = trimEnd(text)
        if trimmed.isEmpty { fatalError("shared/js/\(name) 是空文件") }
        cache[name] = trimmed
        return trimmed
    }

    /// C# 的 `string.TrimEnd()`：只去掉末尾的空白字符（这里不能用 `trimmingCharacters`，那会连头部一起去）。
    private static func trimEnd(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            if text[previous].isWhitespace { end = previous } else { break }
        }
        return String(text[text.startIndex..<end])
    }

    /// 探测门户上的教务系统入口，返回 `portal|<入口地址>` 或 `other`。判据见 `docs/CORE-SPEC.md` §3。
    public static var probe: String { raw("probe.js") }

    /// 停手前的最后一道判据：正文里有没有「确实登录进去了」的标记（`docs/CORE-SPEC.md` §2）。
    /// 返回 `arrival|<命中的标记>` / `arrival|none` / `arrival|err`。
    public static var arrival: String { raw("arrival.js") }

    /// 勾上统一身份认证页那个挂着保密提示的复选框（`name=rememberMe`，是「记住我」）。
    public static var tickNotice: String { raw("tick-notice.js") }

    /// 观察认证页并**原样回报**：优先级在 `Sues.casKindOf`，见 `docs/CORE-SPEC.md` §2。
    public static var casState: String {
        raw("cas-state.js")
            .replacingOccurrences(of: "__EXPIRED_MARK__", with: Sues.passwordExpiredMark)
    }

    /// 处理「密码已过期」提示页：按文字找「点击跳过」，找不到就重载（那正是该按钮做的事）。
    public static var skipExpired: String { raw("skip-expired.js") }

    /// 滑块监视器：接管时机与「同一张图只报一次」的约定见 `docs/CORE-SPEC.md` §5.1。
    public static var captchaWatch: String { raw("captcha-watch.js") }

    /// 停掉页面侧监视器（用户接管、放弃、退到后台、或视图销毁时都必须停）。幂等。
    public static var captchaStop: String { raw("captcha-stop.js") }

    /// 量滑块几何。**只量，不算**：拖动换算全在 `SliderDrag` 里，那里能被单测覆盖。
    public static var sliderGeometry: String { raw("slider-geometry.js") }

    /// 按 `SliderDrag.Plan` 拖动：按下给手柄、移动与抬起给 `document`（页面就是这么监听的）。
    public static func dragJs(_ plan: SliderDrag.Plan) -> String {
        // C# 是 `Delta.ToString("F2", CultureInfo.InvariantCulture)`：两位小数、小数点固定为 `.`。
        // 因此这里显式指定 en_US_POSIX，不能受用户区域设置影响（德语区会变成 `129,00`，
        // 页面拿到就是一个语法错的数字字面量）。
        raw("drag.js").replacingOccurrences(
            of: "__DELTA__",
            with: String(
                format: "%.2f",
                locale: Locale(identifier: "en_US_POSIX"),
                plan.delta))
    }

    /// 在统一身份认证页上填写账号密码、勾「记住我」，然后按下**页面自己的**登录按钮：
    /// 加密发生在页面 `login.js` 的那次点击里，应用只做用户在键盘和鼠标上会做的动作。
    public static func fillAndSubmitJs(_ username: String, _ password: String) -> String {
        raw("fill-and-submit.js")
            .replacingOccurrences(of: "__USERNAME__", with: jsLiteral(username))
            .replacingOccurrences(of: "__PASSWORD__", with: jsLiteral(password))
    }

    /// 捕获用户在官方认证页上**自己按下登录**那一刻的账号密码；是否接受由原生决定。
    /// 监听器持有具名引用，`credential-stop.js` 才能真正摘掉它。
    public static var credentialWatch: String { raw("credential-watch.js") }

    /// 真正摘掉凭据监视器（具名监听器 + 标志位双保险）。幂等。
    public static var credentialStop: String { raw("credential-stop.js") }

    /// 关掉（或恢复）站点的「通知公告」弹窗。结构与安全边界见 `docs/PROTOCOL.md` §9：
    /// 整层摘掉（弹窗 + 遮罩 + 滚动锁，三者一起），只认确实装着公告卡片的那种弹窗，可逆。
    public static func noticeDialogJs(_ hide: Bool) -> String {
        raw("notice-dialog.js").replacingOccurrences(of: "__HIDE__", with: hide ? "true" : "false")
    }

    /// iOS 的传输垫片：`shared/js` 里的回调走 `window.entry.*`（Android 是 addJavascriptInterface，
    /// PC 是 WebView2 的 `chrome.webview.postMessage`），iOS 走 WKWebView 的消息通道。
    /// 垫片只做转发，不含任何判断；每份文档创建前注入，保证先于页面脚本执行。
    ///
    /// 末尾那个空行对应 C# 原始字符串字面量自带的结尾换行，保持逐字节一致（对 JS 语义无影响）。
    public static var entryShim: String {
        """
        (function(){
         if(window.entry)return;
         function post(m){try{window.webkit.messageHandlers.entry.postMessage(m);}catch(e){}}
         window.entry={
          armed:function(a,e){post({cmd:'armed', armed:!!a, expectsSlide:!!e});},
          captcha:function(b,s){post({cmd:'captcha', bg:b, sl:s});},
          credential:function(u,p){post({cmd:'credential', username:u, password:p});},
          log:function(m){post({cmd:'log', message:String(m)});}
         };
        })();

        """
    }

    /// 把一段文本变成可以安全塞进注入脚本的字符串字面量。
    ///
    /// 必须自己转义：账号或密码里可能出现引号、反斜杠、换行，直接拼进 JS 会把脚本拼坏，
    /// 而拼坏的表现是「静默不填」——最难查的那种。
    /// 与 Android 端 `PageJs.jsLiteral`、PC 端 `ScriptBag.JsLiteral` 同一套转义。
    public static func jsLiteral(_ text: String) -> String {
        // C# 是 `new StringBuilder(text.Length + 2)`，Length 数的是 UTF-16 码元。
        var sb = ""
        sb.reserveCapacity(text.utf16.count + 2)
        sb.append("\"")
        for c in text {
            switch c {
            case "\\": sb.append("\\\\")
            case "\"": sb.append("\\\"")
            case "\n": sb.append("\\n")
            case "\r": sb.append("\\r")
            case "\u{2028}": sb.append("\\u2028")
            case "\u{2029}": sb.append("\\u2029")
            default:
                // C# 的判据是 `c < ' '`（UTF-16 码元）。小于 0x20 的都是单字节 ASCII 控制字符，
                // asciiValue 足够；其余字符原样拼进去（含 astral 平面字符，
                // C# 逐个代理项相加与 Swift 按 Character 追加得到同一串）。
                if let code = c.asciiValue, code < 0x20 {
                    let hex = String(code, radix: 16)
                    sb.append("\\u")
                    sb.append(String(repeating: "0", count: 4 - hex.count))
                    sb.append(hex)
                } else {
                    sb.append(c)
                }
            }
        }
        sb.append("\"")
        return sb
    }
}
