import SwiftUI
import WebKit

/// P2 浏览页：整页就是站点，上面一条页面标题、下面一条底栏，状态一句话贴在底栏正上方。
///
/// 与 Android 的形态一致（手机形态）；PC 那套自绘标题栏 + 工具栏是**桌面惯例**，不搬到手机上。
struct BrowserView: View {

    let webView: WKWebView
    let title: String
    let notice: Notice
    let activeEntry: Sues.Entry

    /// 点底栏的入口。
    let onSelect: (Sues.Entry) -> Void
    /// 点状态行上的动作（重试 / 撤销）。
    let onNoticeAction: () -> Void
    /// 打开账号面板。
    let onOpenAccount: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar

            WebViewContainer(webView: webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 状态一句话：贴在底栏正上方（`DESIGN.md` 的 status-pill 位置）。
            // 空文本表示「没有状态」，此时整行不占位——不要留一条空白横条。
            if !notice.text.isEmpty {
                StatusPill(notice: notice, onAction: onNoticeAction)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.top, Theme.Space.sm)
            }

            BottomBar(
                activeEntry: activeEntry,
                onSelect: onSelect,
                onOpenAccount: onOpenAccount)
        }
        .background(Theme.background)
    }

    private var topBar: some View {
        Text(title.isEmpty ? "教务直达" : title)
            .font(Theme.Font.labelLarge)
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Theme.surface)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
    }
}

/// 把 `EntryHost` 已经持有的 `WKWebView` 放进 SwiftUI。
///
/// **不要在这里创建 `WKWebView`**：宿主在它的 `init` 里就已经建好，并且挂了传输垫片
/// （`ScriptBag.entryShim`）、消息通道、导航代理与标题 KVO。这里只负责显示。
struct WebViewContainer: UIViewRepresentable {

    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    /// 没有需要同步的状态：页面状态由 `WKWebView` 自己持有，界面状态走 `EntryHost.onChanged`。
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// 状态胶囊。普通状态白底墨字；需要用户出手时用 warning；办妥时用 success。
struct StatusPill: View {

    let notice: Notice
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Text(notice.text)
                .font(Theme.Font.labelMedium)
                .foregroundStyle(foreground)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if let label = actionLabel {
                Button(label, action: onAction)
                    .font(Theme.Font.labelMedium)
                    .foregroundStyle(foreground)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .stroke(notice.tone == .plain ? Theme.line : Color.clear, lineWidth: 1))
    }

    private var background: Color {
        switch notice.tone {
        case .alert: return Theme.warning
        case .done: return Theme.success
        case .plain: return Theme.surface
        }
    }

    private var foreground: Color {
        switch notice.tone {
        case .alert, .done: return Theme.surface
        case .plain: return Theme.ink
        }
    }

    /// 可点的动作。只有宿主明确给了动作才显示按钮，不自己发明动作。
    private var actionLabel: String? {
        switch notice.kind {
        case .retry: return "重试"
        case .undoSave: return "撤销"
        case .clearAccount: return "清除账号"
        case NoticeKind.none: return nil
        }
    }
}

/// 底栏：教务系统 / WebVPN / 账号。前两项是互斥的「当前入口」，第三项是面板。
private struct BottomBar: View {

    let activeEntry: Sues.Entry
    let onSelect: (Sues.Entry) -> Void
    let onOpenAccount: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            tab("教务系统", systemImage: "graduationcap", active: activeEntry == .jxfw) {
                onSelect(.jxfw)
            }
            tab("WebVPN", systemImage: "globe", active: activeEntry == .webvpn) {
                onSelect(.webvpn)
            }
            // 「账号」不是当前入口，所以永远不是激活态（激活态表示"正在看哪个系统"）
            tab("账号", systemImage: "person.crop.circle", active: false, action: onOpenAccount)
        }
        .frame(height: 48)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    private func tab(
        _ label: String,
        systemImage: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                Text(label)
                    .font(Theme.Font.labelSmall)
            }
            .foregroundStyle(active ? Theme.primary : Theme.secondary)
            .frame(maxWidth: .infinity)
            // 视觉高度 48 已经达到触控下限，这里再补一层可点区域，不缩水
            .frame(minHeight: Theme.Space.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
