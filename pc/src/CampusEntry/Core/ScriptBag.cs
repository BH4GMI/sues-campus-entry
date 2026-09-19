using System.IO;
using System.Reflection;
using System.Text;

namespace CampusEntry.Core;

/// <summary>
/// 页面契约 JS 的唯一来源：仓库根 <c>shared/js/</c>（与 Android 端同一批文件，链接成本工程内嵌资源）。
/// 这里只负责加载与填充占位符；改文件等于改两端的页面契约——先改 docs 再动文件。
/// </summary>
public static class ScriptBag
{
    private static readonly Dictionary<string, string> Cache = new();

    private static string Raw(string name)
    {
        lock (Cache)
        {
            if (Cache.TryGetValue(name, out var cached)) return cached;
            using var stream = Assembly.GetExecutingAssembly()
                    .GetManifestResourceStream($"CampusEntry.js.{name}")
                    ?? throw new InvalidOperationException($"内嵌资源里没有 js/{name}");
            using var reader = new StreamReader(stream, Encoding.UTF8);
            var text = reader.ReadToEnd().TrimEnd();
            if (text.Length == 0) throw new InvalidOperationException($"shared/js/{name} 是空文件");
            Cache[name] = text;
            return text;
        }
    }

    public static string Probe => Raw("probe.js");

    /// <summary>停手前的最后一道判据：正文里有没有「确实登录进去了」的标记（CORE-SPEC §2）。</summary>
    public static string Arrival => Raw("arrival.js");

    public static string TickNotice => Raw("tick-notice.js");

    public static string CasState => Raw("cas-state.js").Replace("__EXPIRED_MARK__", Sues.PasswordExpiredMark);

    public static string SkipExpired => Raw("skip-expired.js");

    public static string CaptchaWatch => Raw("captcha-watch.js");

    public static string CaptchaStop => Raw("captcha-stop.js");

    public static string SliderGeometry => Raw("slider-geometry.js");

    public static string DragJs(SliderDrag.Plan plan) =>
            Raw("drag.js").Replace("__DELTA__", plan.Delta.ToString("F2", System.Globalization.CultureInfo.InvariantCulture));

    public static string FillAndSubmitJs(string username, string password) =>
            Raw("fill-and-submit.js")
                    .Replace("__USERNAME__", JsLiteral(username))
                    .Replace("__PASSWORD__", JsLiteral(password));

    public static string CredentialWatch => Raw("credential-watch.js");

    public static string CredentialStop => Raw("credential-stop.js");

    public static string NoticeDialogJs(bool hide) =>
            Raw("notice-dialog.js").Replace("__HIDE__", hide ? "true" : "false");

    /// <summary>
    /// PC 端的传输垫片：shared/js 里的回调走 <c>window.entry.*</c>（Android 是 addJavascriptInterface），
    /// WebView2 的官方通道是 <c>chrome.webview.postMessage</c>。垫片只做转发，不含任何判断。
    /// 每份文档创建前注入（AddScriptToExecuteOnDocumentCreated），保证先于页面脚本执行。
    /// </summary>
    public static string EntryShim => """
(function(){
 if(window.entry)return;
 function post(m){try{window.chrome.webview.postMessage(m);}catch(e){}}
 window.entry={
  armed:function(a,e){post({cmd:'armed',armed:!!a,expectsSlide:!!e});},
  captcha:function(b,s){post({cmd:'captcha',bg:b,sl:s});},
  credential:function(u,p){post({cmd:'credential',username:u,password:p});},
  log:function(m){post({cmd:'log',message:String(m)});}
 };
})();
""";

    /// <summary>
    /// 把一段文本变成可以安全塞进注入脚本的字符串字面量。
    /// 账号或密码里可能出现引号、反斜杠、换行，直接拼进 JS 会把脚本拼坏（表现为「静默不填」）。
    /// 与 Android 端 PageJs.jsLiteral 同一套转义。
    /// </summary>
    public static string JsLiteral(string text)
    {
        var sb = new StringBuilder(text.Length + 2);
        sb.Append('"');
        foreach (var c in text)
        {
            switch (c)
            {
                case '\\': sb.Append("\\\\"); break;
                case '"': sb.Append("\\\""); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\u2028': sb.Append("\\u2028"); break;
                case '\u2029': sb.Append("\\u2029"); break;
                default:
                    if (c < ' ') sb.Append("\\u").Append(((int)c).ToString("x4"));
                    else sb.Append(c);
                    break;
            }
        }
        sb.Append('"');
        return sb.ToString();
    }
}


