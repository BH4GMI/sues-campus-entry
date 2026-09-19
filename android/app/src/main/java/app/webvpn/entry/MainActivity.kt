package app.webvpn.entry

import android.os.Bundle
import android.webkit.WebView
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.appcompat.app.AppCompatActivity
import app.webvpn.entry.ui.App

/**
 * 「教务直达」——打开校内两个系统的快捷方式。
 *
 * 这一层只做三件事：装配（密钥库 / 凭据库 / 宿主）、把宿主交给 Compose、把返回键交给系统。
 * 导航规则在 [EntryFlow]，页面管理在 [EntryHost]，凭据在 [CredentialStore]，拖动换算在 [SliderDrag]。
 */
class MainActivity : AppCompatActivity() {

    private lateinit var host: EntryHost

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (BuildConfig.DEBUG) {
            // 只在 debug 构建里打开 WebView 远程调试：这样可以把手机上**真实页面**挂到 adb 上量 DOM
            // （「通知公告」那串卡片的规则就是这么量的）。release 构建不留这个口子——
            // 开着它，任何能连 adb 的人都能读到页面内容。
            WebView.setWebContentsDebuggingEnabled(true)
        }

        val backend = AndroidKeyStoreBackend()
        val repository = CredentialRepository(
                getSharedPreferences(PREFS_CREDENTIAL, MODE_PRIVATE),
                CredentialStore(backend),
                backend)
        host = EntryHost(this, getSharedPreferences(PREFS_ENTRY, MODE_PRIVATE), repository)

        setContent {
            App(host)
            BackHandler {
                val tab = host.activeTab
                when {
                    host.showAccount -> host.closeAccount()
                    !host.home && tab != null && tab.web.canGoBack() -> tab.web.goBack()
                    else -> finish()
                }
            }
        }

        // 已经决定过就不再经过首页：这是个快捷方式，不该多一次点击
        if (!host.home && host.tabs.isEmpty()) host.openEntry(Sues.Entry.JXFW)
    }

    override fun onResume() {
        super.onResume()
        // 后台时停掉的页面监视器，回来要装回去（幂等），否则自动滑块会静默失效
        host.onResume()
    }

    override fun onPause() {
        super.onPause()
        // 页面侧监视器住在页面里，不受 Activity 状态控制，离开时必须停掉
        host.onPause()
    }

    override fun onDestroy() {
        host.onDestroy()
        super.onDestroy()
    }

    private companion object {
        /** 网关前缀等与页面无关的偏好。 */
        const val PREFS_ENTRY = "entry"

        /** 凭据密文单独一个文件，方便「清除账号」与备份排除。 */
        const val PREFS_CREDENTIAL = "credentials"
    }
}
