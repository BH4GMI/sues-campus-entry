package app.webvpn.entry

import java.security.GeneralSecurityException
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * 单元测试用的加解密后端：JVM 上的 AES-256-GCM。
 *
 * 它有两个用处：证明 [CryptoBackend] 这个形状不是只为 Android 定制的，以及让 [CredentialStore]
 * 的编解码、版本与完整性处置**在电脑上就能被测到**。真机上的密钥库路径由 `androidTest` 里的
 * `AndroidKeyStoreBackendTest` 覆盖。
 */
class JvmAesBackend : CryptoBackend {

    private var key: SecretKey = newKey()

    override fun seal(plain: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val cipherText = cipher.doFinal(plain)
        val iv = cipher.iv
        return ByteArray(1 + iv.size + cipherText.size).also { out ->
            out[0] = iv.size.toByte()
            iv.copyInto(out, 1)
            cipherText.copyInto(out, 1 + iv.size)
        }
    }

    override fun open(sealed: ByteArray): ByteArray {
        if (sealed.size <= 1) throw CryptoException("密文太短")
        val ivLength = sealed[0].toInt() and 0xFF
        if (ivLength <= 0 || 1 + ivLength >= sealed.size) throw CryptoException("密文头部不合法")
        return try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, sealed, 1, ivLength))
            cipher.doFinal(sealed, 1 + ivLength, sealed.size - 1 - ivLength)
        } catch (e: GeneralSecurityException) {
            throw CryptoException("解密失败", e)
        }
    }

    /**
     * 换一把密钥。
     *
     * 这与真机上的行为一致：清掉账号后密钥库条目被删，下次用时生成的是**新**密钥，
     * 于是旧密文再也解不开。
     */
    override fun destroy() {
        key = newKey()
    }

    private fun newKey(): SecretKey =
            SecretKeySpec(ByteArray(32).also { SecureRandom().nextBytes(it) }, ALGORITHM)

    private companion object {
        const val ALGORITHM = "AES"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val TAG_BITS = 128
    }
}
