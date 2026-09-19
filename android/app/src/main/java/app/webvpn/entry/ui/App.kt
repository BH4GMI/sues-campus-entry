package app.webvpn.entry.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import android.widget.FrameLayout
import app.webvpn.entry.EntryHost
import app.webvpn.entry.Notice
import app.webvpn.entry.Sues

@Composable
fun App(host: EntryHost) {
    AppTheme {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize()) {
                if (host.home) HomeScreen(host) else BrowserScreen(host)
                if (host.showAccount) AccountSheet(host)
            }
        }
    }
}

// ---------------------------------------------------------------- P1 入口页

@Composable
private fun HomeScreen(host: EntryHost) {
    Column(Modifier.fillMaxSize().padding(24.dp)) {
        Spacer(Modifier.height(32.dp))
        Text("教务直达", style = MaterialTheme.typography.headlineSmall,
                color = MaterialTheme.colorScheme.onBackground)
        Spacer(Modifier.height(6.dp))
        Text("打开教务系统，自动登录", style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)

        Spacer(Modifier.height(32.dp))
        EntryCard("教务系统", "自动登录，直达首页", primary = true) {
            host.enterFromHome(Sues.Entry.JXFW)
        }
        Spacer(Modifier.height(12.dp))
        EntryCard("WebVPN", "访问其他校内资源", primary = false) {
            host.enterFromHome(Sues.Entry.WEBVPN)
        }

        Spacer(Modifier.weight(1f))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(checked = host.saveAccount, onCheckedChange = { host.changeSaveAccount(it) })
            Column(Modifier.padding(start = 4.dp)) {
                Text("登录后记住账号，下次自动登录", style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onBackground)
                Text("密码用系统密钥库加密，只存本机；随时可在「账号」里清除",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun EntryCard(title: String, subtitle: String, primary: Boolean, onClick: () -> Unit) {
    val background = if (primary) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surface
    val titleColor = if (primary) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface
    val subtitleColor = if (primary) MaterialTheme.colorScheme.onPrimary.copy(alpha = 0.85f)
    else MaterialTheme.colorScheme.onSurfaceVariant
    Surface(
            color = background,
            shape = MaterialTheme.shapes.large,
            border = if (primary) null else androidx.compose.foundation.BorderStroke(
                    1.dp, MaterialTheme.colorScheme.outline),
            modifier = Modifier.fillMaxWidth().height(88.dp).clickable(onClick = onClick),
    ) {
        Column(Modifier.fillMaxSize().padding(horizontal = 20.dp),
                verticalArrangement = Arrangement.Center) {
            Text(title, style = MaterialTheme.typography.titleMedium, color = titleColor)
            Spacer(Modifier.height(4.dp))
            Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = subtitleColor)
        }
    }
}

// ---------------------------------------------------------------- P2 浏览页

@Composable
private fun BrowserScreen(host: EntryHost) {
    Column(Modifier.fillMaxSize()) {
        TabStrip(host)
        Box(Modifier.weight(1f).fillMaxWidth()) {
            WebHost(host)
            val tab = host.activeTab
            if (tab != null && tab.loading && tab.progress in 1..99) {
                LinearProgressIndicator(
                        progress = { tab.progress / 100f },
                        modifier = Modifier.fillMaxWidth().height(2.dp).align(Alignment.TopCenter),
                        color = MaterialTheme.colorScheme.primary,
                        trackColor = Color.Transparent,
                )
            }
            // 状态行**浮在页面之上**、贴着底边：不占布局高度，页面也不会被顶得重排跳动。
            // 底栏因此只剩下它自己那一行。
            Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth()) { NoticeRow(host) }
        }
        BottomBar(host)
    }
}

/** WebView 的宿主。Activity 把当前标签页的 WebView 挂进这个 FrameLayout。 */
@Composable
private fun WebHost(host: EntryHost) {
    AndroidView(
            factory = { context ->
                FrameLayout(context).also { host.attachContainer(it) }
            },
            modifier = Modifier.fillMaxSize(),
    )
}

/**
 * 标签栏。**只有一个标签时不出现**——这个应用是快捷方式，不是浏览器；
 * 平时保持干净，站点真的新开了页面才让它露出来。
 */
@Composable
private fun TabStrip(host: EntryHost) {
    if (host.tabs.size <= 1) return
    Surface(color = MaterialTheme.colorScheme.surface) {
        Column {
            Row(Modifier.fillMaxWidth().height(44.dp).horizontalScroll(rememberScrollState())) {
                host.tabs.forEach { tab ->
                    val active = tab.id == host.activeId
                    Column(Modifier.fillMaxHeight().clickable { host.switchTo(tab.id) }) {
                        Row(Modifier.weight(1f).padding(start = 14.dp, end = 4.dp),
                                verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                    text = tab.title.ifEmpty { "新标签页" },
                                    style = MaterialTheme.typography.labelSmall,
                                    color = if (active) MaterialTheme.colorScheme.primary
                                    else MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.widthIn(max = 132.dp),
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(
                                    text = "✕",
                                    style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier
                                            .clip(RoundedCornerShape(50))
                                            .clickable { host.closeTab(tab.id) }
                                            .padding(horizontal = 8.dp, vertical = 6.dp),
                            )
                        }
                        Box(Modifier.fillMaxWidth().height(2.dp).background(
                                if (active) MaterialTheme.colorScheme.primary else Color.Transparent))
                    }
                    Box(Modifier.width(1.dp).fillMaxHeight()
                            .background(MaterialTheme.colorScheme.outline))
                }
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outline)
        }
    }
}

/** 状态行：只在有事发生时出现，贴在底栏正上方；需要用户出手时不再自动消失。 */
@Composable
private fun NoticeRow(host: EntryHost) {
    val notice = host.notice
    if (notice.text.isEmpty()) return
    val background = when (notice.tone) {
        Notice.Tone.PLAIN -> MaterialTheme.colorScheme.surface
        Notice.Tone.ALERT -> AppColors.warning
        Notice.Tone.DONE -> AppColors.success
    }
    val foreground = when (notice.tone) {
        Notice.Tone.PLAIN -> MaterialTheme.colorScheme.onSurface
        else -> Color.White
    }
    Box(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp)) {
        Surface(color = background, shape = RoundedCornerShape(50.dp), shadowElevation = 3.dp) {
            Row(Modifier.padding(
                    start = 14.dp,
                    end = if (notice.action == null) 14.dp else 4.dp,
                    top = 6.dp,
                    bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(notice.text, style = MaterialTheme.typography.labelMedium, color = foreground)
                if (notice.action != null) {
                    TextButton(onClick = { host.onNoticeAction() }) {
                        Text(
                                text = when (notice.action) {
                                    Notice.Act.RETRY -> "重试"
                                    Notice.Act.UNDO_SAVE -> "撤销"
                                    Notice.Act.CLEAR_ACCOUNT -> "清除账号"
                                },
                                style = MaterialTheme.typography.labelMedium,
                                color = foreground,
                        )
                    }
                }
            }
        }
    }
}

/** 底栏三项：教务系统 / WebVPN / 账号。「返回」交给系统返回键，省下的位置给账号。 */
@Composable
private fun BottomBar(host: EntryHost) {
    Column {
        HorizontalDivider(color = MaterialTheme.colorScheme.outline)
        Row(Modifier.fillMaxWidth().height(48.dp).background(MaterialTheme.colorScheme.surface)) {
            val entry = host.activeTab?.entry
            BarItem("教务系统", entry == Sues.Entry.JXFW, Modifier.weight(1f)) {
                host.openEntry(Sues.Entry.JXFW)
            }
            BarItem("WebVPN", entry == Sues.Entry.WEBVPN, Modifier.weight(1f)) {
                host.openEntry(Sues.Entry.WEBVPN)
            }
            BarItem("账号", false, Modifier.weight(1f)) { host.openAccount() }
        }
    }
}

@Composable
private fun BarItem(label: String, active: Boolean, modifier: Modifier, onClick: () -> Unit) {
    Box(
            modifier = modifier.fillMaxHeight().clickable(onClick = onClick),
            contentAlignment = Alignment.Center,
    ) {
        Text(
                text = label,
                style = MaterialTheme.typography.labelSmall,
                color = if (active) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

// ---------------------------------------------------------------- P3 账号抽屉

@Composable
private fun AccountSheet(host: EntryHost) {
    val interaction = remember { MutableInteractionSource() }
    Box(Modifier.fillMaxSize()) {
        Box(Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = 0.45f))
                .clickable(interactionSource = interaction, indication = null) { host.closeAccount() })
        Column(
                Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp))
                        .background(MaterialTheme.colorScheme.surface)
                        // 吃掉落在卡片上的点击，别透到遮罩上把抽屉关掉
                        .clickable(interactionSource = interaction, indication = null) {}
                        .padding(bottom = 20.dp),
        ) {
            Box(Modifier.fillMaxWidth().padding(top = 10.dp, bottom = 6.dp),
                    contentAlignment = Alignment.Center) {
                Box(Modifier.width(36.dp).height(4.dp)
                        .clip(RoundedCornerShape(50))
                        .background(MaterialTheme.colorScheme.outline))
            }
            Text("账号", style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.padding(start = 20.dp, top = 6.dp, bottom = 6.dp))

            SheetRow("入口首页", trailing = "›", onClick = { host.openHome() })
            SheetRow(
                    title = if (host.savedUsername != null) "已保存：${mask(host.savedUsername!!)}"
                    else "未保存账号",
                    onClick = null,
            )
            SheetRow(
                    title = "自动登录",
                    trailing = null,
                    onClick = null,
                    content = {
                        Switch(checked = host.saveAccount,
                                onCheckedChange = { host.changeSaveAccount(it) })
                    },
            )
            SheetRow(
                    title = "收起公告弹窗",
                    subtitle = "站点那个没有关闭按钮的公告弹窗",
                    onClick = null,
                    content = {
                        Switch(checked = host.hideNotices,
                                onCheckedChange = { host.changeHideNotices(it) })
                    },
            )
            SheetRow("清除缓存 · 退出登录",
                    subtitle = "清掉学校的登录状态，保存的密码不动",
                    onClick = { host.clearSession() })
            SheetRow("清除账号",
                    subtitle = "删掉保存的密码，登录状态不动",
                    danger = true,
                    onClick = { host.clearAccount() })
            SheetRow("改用其他账号",
                    subtitle = "退出登录并删除保存的密码",
                    onClick = { host.switchAccount() })

            Text(
                    text = "密码用系统密钥库加密后存放在本机，应用只在学校的统一身份认证页面上填写，" +
                            "从不发送到别处。清除后立即失效。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
            )
        }
    }
}

@Composable
private fun SheetRow(
        title: String,
        subtitle: String? = null,
        trailing: String? = null,
        danger: Boolean = false,
        onClick: (() -> Unit)?,
        content: (@Composable () -> Unit)? = null,
) {
    Row(
            modifier = Modifier
                    .fillMaxWidth()
                    .height(if (subtitle == null) 52.dp else 66.dp)
                    .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
                    .padding(horizontal = 20.dp),
            verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                    text = title,
                    style = MaterialTheme.typography.bodyMedium,
                    color = if (danger) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
            )
            if (subtitle != null) {
                Text(
                        text = subtitle,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        if (content != null) content()
        if (trailing != null) {
            Text(trailing, style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
    HorizontalDivider(color = MaterialTheme.colorScheme.outline, thickness = 0.5.dp)
}

/** 界面上的账号一律打码：别人从旁边扫一眼看不到完整学号。 */
private fun mask(username: String): String =
        if (username.length <= 4) "****" else username.take(4) + "****"
