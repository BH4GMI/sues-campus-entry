package app.webvpn.entry

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 系统密钥库（AndroidKeyStore）上的 AES-256-GCM。
 *
 * - 密钥**不可导出**，只在本机、只对本应用可用；设备有硬件密钥库时（TEE / StrongBox）密钥本身
 *   也留在硬件里，导出即失败。
 * - `setUserAuthenticationRequired(false)` 是「全自动登录」的前提：要求解锁才能用密钥就没法自动了。
 *   将来若要做「打开应用验一次指纹」，改的是这里 + `androidx.biometric`，并且必须是用户显式打开的
 *   开关，而不是默认行为。
 * - **刻意不用 `androidx.security:security-crypto`**：该库的 `MasterKey` / `MasterKeys` /
 *   `EncryptedSharedPreferences` / `EncryptedFile` 已被官方弃用，javadoc 明确写着
 *   "Use `javax.crypto.KeyGenerator` with AndroidKeyStore instance instead" /
 *   "Use `android.content.SharedPreferences` instead"。官方的指引就是「直接用系统密钥库 + 普通存储」，
 *   于是这里零新增依赖。
 *
 * 落盘字节的摆法：`[IV 长度][IV][密文+标签]`。IV 由系统每次加密随机生成，必须存下来。
 */
class AndroidKeyStoreBackend(
        private val alias: String = DEFAULT_ALIAS,
) : CryptoBackend {

    override fun seal(plain: ByteArray): ByteArray = crypto("加密") {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val cipherText = cipher.doFinal(plain)
        val iv = cipher.iv
        require(iv.size in 1..MAX_IV) { "IV 长度不合法：${iv.size}" }
        ByteArray(1 + iv.size + cipherText.size).also { out ->
            out[0] = iv.size.toByte()
            iv.copyInto(out, 1)
            cipherText.copyInto(out, 1 + iv.size)
        }
    }

    override fun open(sealed: ByteArray): ByteArray = crypto("解密") {
        if (sealed.size <= 1) throw CryptoException("密文太短")
        val ivLength = sealed[0].toInt() and 0xFF
        if (ivLength <= 0 || 1 + ivLength >= sealed.size) throw CryptoException("密文头部不合法")
        val cipher = Cipher.getInstance(TRANSFORMATION)
        // 标签校验失败会在这里抛 AEADBadTagException（GeneralSecurityException 的子类）：
        // 密文被改过、或密钥已经不是当初那一把。
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, sealed, 1, ivLength))
        cipher.doFinal(sealed, 1 + ivLength, sealed.size - 1 - ivLength)
    }

    override fun destroy() = crypto("删除密钥") {
        keyStore().deleteEntry(alias)
    }

    /**
     * 取密钥；没有就现生成一把。
     *
     * 「没有」包括用户刚清过账号的情况——那时会生成一把**新**密钥，于是旧密文再也解不开，
     * 这正是我们想要的语义，不需要额外分支。
     */
    private fun key(): SecretKey {
        (keyStore().getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        generator.init(KeyGenParameterSpec.Builder(alias, PURPOSE_ENCRYPT or PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(KEY_BITS)
                .setUserAuthenticationRequired(false)
                .build())
        return generator.generateKey()
    }

    private fun keyStore(): KeyStore =
            KeyStore.getInstance(PROVIDER).apply { load(null) }

    /**
     * 把平台的密码学异常统一成 [CryptoException]，上层只需要认一种失败。
     *
     * **捕 `Exception` 而不是只捕 `GeneralSecurityException`**：密钥库这条路上还有别的失败形态——
     * `KeyStore.load(null)` 声明抛 `IOException` / `CertificateException`，`KeyGenerator` 的设备侧
     * 故障会以 `ProviderException`（RuntimeException）冒出来。它们不在 `GeneralSecurityException`
     * 的继承链上，只捕后者就会让异常穿到调用点（`onCreate` / `onPageFinished`）把应用**打崩**，
     * 而不是按契约「当作没有凭据，让用户重登」。
     * （`Error` 不在此列：`catch (Exception)` 不会吞掉 OOM 这类错误。）
     */
    private inline fun <T> crypto(what: String, block: () -> T): T = try {
        block()
    } catch (e: Exception) {
        throw CryptoException("$what 失败", e)
    }

    private companion object {
        const val PROVIDER = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val DEFAULT_ALIAS = "campus-entry-cred-v1"
        const val KEY_BITS = 256
        const val TAG_BITS = 128
        const val MAX_IV = 32

        const val PURPOSE_ENCRYPT = KeyProperties.PURPOSE_ENCRYPT
        const val PURPOSE_DECRYPT = KeyProperties.PURPOSE_DECRYPT
    }
}
