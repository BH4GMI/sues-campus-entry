package app.webvpn.entry

import android.content.SharedPreferences
import android.util.Base64
import android.util.Log

/**
 * 凭据在本机的存放处：**密文**放 SharedPreferences，**密钥**由系统密钥库保管。
 *
 * 这里是唯一一处 Android 存储依赖；编解码、版本与完整性处置全在 [CredentialStore] 里，
 * 能在电脑上单测。密钥永远不以任何形式出现在这个类里——它连读都读不到（不可导出）。
 */
class CredentialRepository(
        private val prefs: SharedPreferences,
        private val store: CredentialStore,
        private val backend: CryptoBackend,
) {

    /**
     * 保存。返回是否真的落盘了。
     *
     * 用 `commit()` 而不是 `apply()`：调用方要据此告诉用户「已记住账号」，而那句提示不能撒谎——
     * 提交完立刻被杀进程时，`apply()` 有可能还没写下去。
     */
    fun save(username: String, password: CharArray): Boolean {
        val blob = try {
            store.encode(username, password)
        } catch (e: Exception) {
            // 编码失败（账号/密码为空、密钥库不可用）：按契约返回 false，让界面说「没能保存」——
            // 异常从这里穿出去的话会打在导航回调上，把「存不下账号」变成「应用崩了」。
            Log.w(TAG, "凭据编码失败，按未保存处理", e)
            return false
        }
        return try {
            prefs.edit().putString(KEY_BLOB, Base64.encodeToString(blob, Base64.NO_WRAP)).commit()
        } catch (e: Exception) {
            Log.w(TAG, "凭据写盘失败，按未保存处理", e)
            false
        } finally {
            // 密文已经交出去了，临时字节立刻擦掉
            blob.fill(0)
        }
    }

    /** 读出一组可用凭据；没有或解不开都返回 null。**拿到就必须 `clear()`。** */
    fun load(): Credential? = try {
        when (val saved = store.decode(blob())) {
            is SavedCredential.Loaded -> saved.credential
            SavedCredential.Absent -> null
            SavedCredential.Unreadable -> {
                // 不静默：处置一样（让用户重登），但排障时要分得清「没存过」与「解不开」
                Log.w(TAG, "已保存的凭据解不开，按未保存处理")
                null
            }
        }
    } catch (e: Exception) {
        // 契约是「没有或解不开都返回 null」：任何意外都归到这一条
        Log.w(TAG, "读取凭据失败，按未保存处理", e)
        null
    }

    /**
     * 已经保存的账号名，用来在界面上显示（打码后显示）。
     *
     * 解出来拿到名字就立刻把密码擦掉——不为了画一行字，把密码留在内存里。
     */
    fun savedUsername(): String? {
        val credential = load() ?: return null
        try {
            return credential.username
        } finally {
            credential.clear()
        }
    }

    /** 清除：删密文**并且删密钥**。只删密文的话密钥还在，剩下的只有运气。 */
    fun clear() {
        // 两步都不允许把异常放出去：调用点在界面动作与导航回调里
        try {
            prefs.edit().remove(KEY_BLOB).commit()
        } catch (e: Exception) {
            Log.w(TAG, "凭据密文删除失败", e)
        }
        try {
            backend.destroy()
        } catch (e: Exception) {
            Log.w(TAG, "密钥删除失败；密文已删，旧凭据不可再解", e)
        }
    }

    private fun blob(): ByteArray? {
        val text = prefs.getString(KEY_BLOB, null) ?: return null
        return try {
            Base64.decode(text, Base64.NO_WRAP)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "凭据密文不是合法的 Base64", e)
            null
        }
    }

    private companion object {
        const val TAG = "教务直达"
        const val KEY_BLOB = "credential_blob"
    }
}
