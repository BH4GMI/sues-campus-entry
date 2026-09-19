import SwiftUI

/// P3 账号面板（对应 Android 的账号抽屉；iOS 上用 sheet）。
///
/// 这里是**唯一的破坏性动作集合**：清除缓存（退出登录）、清除账号、改用其他账号。
/// 破坏性动作永远是文字或描边按钮，不做成实心红（`DESIGN.md`），避免误触。
struct AccountSheet: View {

    let savedUsername: String?
    let saveAccount: Bool
    let hideNotices: Bool

    /// 开/关自动登录。
    let onChangeSaveAccount: (Bool) -> Void
    /// 开/关「收起公告弹窗」。
    let onChangeHideNotices: (Bool) -> Void
    /// 回到入口首页。
    let onOpenHome: () -> Void
    /// 清除登录状态（删 cookie），不动保存的密码。
    let onClearSession: () -> Void
    /// 删除保存的账号密码，不动登录状态。
    let onClearAccount: () -> Void
    /// 退出登录并删除保存的密码，重新走一遍首次登录。
    let onSwitchAccount: () -> Void
    let onClose: () -> Void

    @State private var confirmClearAccount = false
    @State private var confirmSwitchAccount = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onOpenHome()
                    } label: {
                        row(title: "入口首页", detail: nil)
                    }

                    LabeledContent {
                        Text(savedUsername == nil ? "未保存账号" : "已保存：\(mask(savedUsername!))")
                            .font(Theme.Font.bodyMedium)
                            .foregroundStyle(Theme.secondary)
                    } label: {
                        Text("账号").font(Theme.Font.bodyMedium).foregroundStyle(Theme.ink)
                    }
                }

                Section {
                    Toggle(isOn: Binding(get: { saveAccount }, set: onChangeSaveAccount)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动登录").font(Theme.Font.bodyMedium).foregroundStyle(Theme.ink)
                            Text("登录后记住账号，下次自动填写")
                                .font(Theme.Font.bodySmall).foregroundStyle(Theme.secondary)
                        }
                    }
                    Toggle(isOn: Binding(get: { hideNotices }, set: onChangeHideNotices)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("收起公告弹窗").font(Theme.Font.bodyMedium).foregroundStyle(Theme.ink)
                            Text("站点那个没有关闭按钮的公告弹窗")
                                .font(Theme.Font.bodySmall).foregroundStyle(Theme.secondary)
                        }
                    }
                }

                Section {
                    Button {
                        onClearSession()
                    } label: {
                        destructiveRow(title: "清除缓存 · 退出登录",
                                       detail: "清掉学校的登录状态，保存的密码不动",
                                       tone: Theme.primary)
                    }

                    Button {
                        confirmClearAccount = true
                    } label: {
                        destructiveRow(title: "清除账号",
                                       detail: "删掉保存的密码，登录状态不动",
                                       tone: Theme.error)
                    }
                    .disabled(savedUsername == nil)

                    Button {
                        confirmSwitchAccount = true
                    } label: {
                        destructiveRow(title: "改用其他账号",
                                       detail: "退出登录并删除保存的密码",
                                       tone: Theme.primary)
                    }
                } footer: {
                    Text("密码用系统钥匙串（Keychain）加密后存放在本机，应用只在学校的统一身份认证页面上填写，"
                        + "从不发送到别处。清除后立即失效。")
                        .font(Theme.Font.bodySmall)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .navigationTitle("账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭", action: onClose)
                }
            }
        }
        // 破坏性动作要确认（`docs/APP-UX.md` §4：不可逆操作必须确认）
        .alert("删除加密保存在本机的账号密码？删除后下次要重新手动登录。", isPresented: $confirmClearAccount) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { onClearAccount() }
        }
        .alert("清掉登录状态与本机账号，重新走一遍首次登录？", isPresented: $confirmSwitchAccount) {
            Button("取消", role: .cancel) {}
            Button("继续", role: .destructive) { onSwitchAccount() }
        }
    }

    private func row(title: String, detail: String?) -> some View {
        HStack {
            Text(title).font(Theme.Font.bodyMedium).foregroundStyle(Theme.ink)
            Spacer()
            if let detail {
                Text(detail).font(Theme.Font.bodySmall).foregroundStyle(Theme.secondary)
            }
        }
    }

    /// 破坏性动作的呈现：标题 + 一句后果说明，永远不是实心红按钮。
    private func destructiveRow(title: String, detail: String, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.Font.labelLarge).foregroundStyle(tone)
            Text(detail).font(Theme.Font.bodySmall).foregroundStyle(Theme.secondary)
        }
    }

    /// 与 Android 端同一套：只露前 4 位，其余打码。
    private func mask(_ username: String) -> String {
        username.count <= 4 ? "****" : String(username.prefix(4)) + "****"
    }
}
