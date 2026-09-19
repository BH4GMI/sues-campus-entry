package app.webvpn.entry

import android.util.Log
import java.security.KeyStore

/**
 * 仪表测试自己造的密钥库别名，测试自己清掉——**这是用户的设备**。
 *
 * 为什么需要它：`AndroidKeyStoreBackendTest` 与 `EntryHostDomTest` 都用「带时间戳的唯一别名」
 * 建密钥，而 JUnit 每个用例都会新建一次测试类实例——于是**每跑一轮就漏 11 把测试密钥**
 * 在设备的密钥库里（别名不同，永远不会被复用也不会被回收）。这些东西用户看不见，
 * 但会一直攒；测试不留垃圾是基本要求。
 *
 * 只删带测试前缀的别名：产品用的别名（`AndroidKeyStoreBackend` 的默认别名）绝不在其中。
 */
internal fun purgeTestKeystoreAliases(vararg prefixes: String): Int {
    val keyStore = try {
        KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    } catch (e: Exception) {
        Log.w("教务直达", "测试收尾：打不开密钥库，跳过清理", e)
        return 0
    }
    var removed = 0
    for (alias in keyStore.aliases().toList()) {
        if (prefixes.none { alias.startsWith(it) }) continue
        try {
            keyStore.deleteEntry(alias)
            removed++
        } catch (e: Exception) {
            // 删不掉不算失败：可能存在别的测试正在用的别名
        }
    }
    return removed
}
