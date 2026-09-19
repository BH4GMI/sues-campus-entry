import SwiftUI

/// P1 入口页：首次使用自动出现一次，之后由账号面板的「入口首页」进入。
///
/// 它存在的唯一理由是**在用户交出账号之前把话说清楚**：会记住账号、存在哪里、怎么撤。
/// 之后它不该挡在打开应用的路上（`EntryHost.home` 为 false 时直接进浏览页）。
struct HomeView: View {

    /// 点某个入口。由根视图交给 `EntryHost.enterFromHome(_:)`。
    let onPick: (Sues.Entry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("教务直达")
                    .font(Theme.Font.headlineSmall)
                    .foregroundStyle(Theme.ink)
                Text("打开教务系统，自动登录")
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.top, Theme.Space.xxxl)
            .padding(.bottom, Theme.Space.xxl)

            EntryCard(
                title: "教务系统",
                subtitle: "自动登录，直达首页",
                primary: true,
                action: { onPick(.jxfw) })

            EntryCard(
                title: "WebVPN",
                subtitle: "访问其他校内资源",
                primary: false,
                action: { onPick(.webvpn) })
                .padding(.top, Theme.Space.md)

            Spacer(minLength: Theme.Space.xxl)

            FirstRunNote()
                .padding(.bottom, Theme.Space.xxl)
        }
        .padding(.horizontal, Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }
}

/// 入口卡片。主入口蓝底白字，次入口白底墨字——**同尺寸、不弱化到看不清**，只是不上色。
private struct EntryCard: View {

    let title: String
    let subtitle: String
    let primary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title)
                    .font(Theme.Font.titleMedium)
                    .foregroundStyle(primary ? Theme.surface : Theme.ink)
                Text(subtitle)
                    .font(Theme.Font.bodySmall)
                    .foregroundStyle(primary ? Theme.surface.opacity(0.85) : Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.xl)
            .frame(minHeight: 88)
            .background(primary ? Theme.primary : Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .stroke(primary ? Color.clear : Theme.line, lineWidth: 1))
        }
        // 视觉高度 88，但可点区域补足到触控下限以上（DESIGN.md：触控目标不小于 48px）
        .frame(minHeight: Theme.Space.touch)
        .buttonStyle(.plain)
    }
}

/// 首次使用的交代。文案与 Android 端逐字一致，只把「系统密钥库」换成 iOS 的准确说法。
private struct FirstRunNote: View {

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("登录后记住账号，下次自动登录")
                .font(Theme.Font.labelLarge)
                .foregroundStyle(Theme.ink)
            Text("密码用系统钥匙串（Keychain）加密，只存本机；随时可在「账号」里清除")
                .font(Theme.Font.bodySmall)
                .foregroundStyle(Theme.secondary)
        }
    }
}
