using System.Reflection;
using System.Text.RegularExpressions;
using CampusEntry.Core;
using Xunit;

namespace CampusEntry.Tests;

/// <summary>
/// 页面脚本的内嵌清单守卫。
///
/// `CampusEntry.csproj` 关掉了默认内嵌（`EnableDefaultEmbeddedResourceItems=false`），改成**显式清单**：
/// 新增一个 `shared/js/*.js` 却忘了往清单里加时，**编译照样通过**，只有真正走到那段流程才会在
/// 运行时炸——2026-09 加 `arrival.js` 时就真踩了一次（门户入口的到达判据会整条失效）。
///
/// 反射遍历所有公开的 string 属性，就不必再维护一份「脚本名单」（那种重复清单本身也是 bug 来源）。
/// </summary>
public class ScriptBagTests
{
    [Fact]
    public void 每个页面脚本都真的取得到内容()
    {
        var properties = typeof(ScriptBag)
            .GetProperties(BindingFlags.Public | BindingFlags.Static)
            .Where(p => p.PropertyType == typeof(string))
            .ToArray();

        Assert.NotEmpty(properties);   // 反射拿不到东西时，这条用例必须失败，不能静默通过

        foreach (var property in properties)
        {
            var text = (string?)property.GetValue(null);
            Assert.False(
                string.IsNullOrWhiteSpace(text),
                $"ScriptBag.{property.Name} 取不到内容（csproj 的内嵌清单漏了这个脚本？）");
        }
    }

    /// <summary>
    /// 占位符（约定：`__全大写__`）必须都被替换掉：漏替换的话注入的 JS 会直接语法错误。
    ///
    /// **不能用 `Contains("__")` 判**——脚本里合法地存在 `window.__portalGroups`、
    /// `.el-dialog__wrapper`（BEM 类名）这类双下划线。`shared/js` 里现存的占位符只有
    /// `__DELTA__` / `__EXPIRED_MARK__` / `__HIDE__` / `__PASSWORD__` / `__USERNAME__` 五个。
    /// </summary>
    [Fact]
    public void 带参数的脚本不留占位符()
    {
        var placeholder = new Regex(@"__[A-Z][A-Z0-9_]*__");
        var scripts = new (string Name, string Text)[]
        {
            ("probe.js", ScriptBag.Probe),
            ("cas-state.js", ScriptBag.CasState),
            ("slider-geometry.js", ScriptBag.SliderGeometry),
            ("drag.js", ScriptBag.DragJs(new SliderDrag.Plan(200, 246, 12.34))),
            ("fill-and-submit.js", ScriptBag.FillAndSubmitJs("u", "p")),
            ("notice-dialog.js", ScriptBag.NoticeDialogJs(hide: true)),
        };

        foreach (var (name, text) in scripts)
        {
            Assert.False(placeholder.IsMatch(text), $"{name} 里还留着没替换的占位符");
        }
    }
}
