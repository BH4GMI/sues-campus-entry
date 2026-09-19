package app.webvpn.entry

/**
 * 一组账号密码。密码用 [CharArray] 承载，用完可以**真的擦掉**——Java 的 `String` 不可变，
 * 一旦变成 String 就再也擦不干净了（这一点在 `docs/APP-UX.md` §6.5 里对用户说清楚了）。
 */
class Credential(val username: String, val password: CharArray) {

    /** 擦掉密码。调用之后这个对象不可再用。 */
    fun clear() {
        password.fill('\u0000')
    }
}

/** 读取已保存凭据的结果。 */
sealed class SavedCredential {

    /** 没保存过，或者密文短得根本不成形。 */
    object Absent : SavedCredential()

    /** 解出来了。**用完必须 `credential.clear()`**。 */
    class Loaded(val credential: Credential) : SavedCredential()

    /** 密文在，但解不开或格式不认（被改过、密钥换过、版本比本应用新）。 */
    object Unreadable : SavedCredential()
}

/**
 * 凭据的落盘编解码与完整性处置。**纯逻辑、不依赖 Android**，可以在 JVM 上直接单测。
 *
 * 落盘形态（一个 blob）：
 *
 * ```
 * [0]      格式版本，目前是 1
 * [1..]    加解密后端产出的字节（自带 IV 与完整性标签）
 * ```
 *
 * 明文形态（交后端加密之前）：长度前缀的两段——
 *
 * ```
 * [用户名长度 u16 大端][用户名 UTF-8][密码 UTF-8]
 * ```
 *
 * 用长度前缀而不是分隔符：用户名或密码里出现任何字符都不会把两段串起来。
 *
 * 版本号只有认得的才解；认不出的一律归 [SavedCredential.Unreadable] 并**在日志里说一声**，
 * 不静默当成「没保存过」——两种情况的处理虽然一样（让用户重登），但排障时差别很大。
 */
class CredentialStore(private val backend: CryptoBackend) {

    /**
     * 编码。
     *
     * 账号为空或密码为空会抛 [IllegalArgumentException]：**宁可在这里炸，也不要存下一组
     * 永远登不进去的凭据**——那会让应用每次启动都自动替用户消耗一次失败次数。
     */
    fun encode(username: String, password: CharArray): ByteArray {
        require(username.isNotBlank()) { "账号不能为空" }
        require(password.isNotEmpty()) { "密码不能为空" }
        val plain = frame(username, password)
        try {
            return byteArrayOf(VERSION) + backend.seal(plain)
        } finally {
            plain.fill(0)
        }
    }

    /** 解码。任何不正常的情况都返回 [SavedCredential.Absent] 或 [SavedCredential.Unreadable]，不抛。 */
    fun decode(blob: ByteArray?): SavedCredential {
        if (blob == null || blob.size <= 1) return SavedCredential.Absent
        if (blob[0] != VERSION) return SavedCredential.Unreadable

        val plain = try {
            backend.open(blob.copyOfRange(1, blob.size))
        } catch (e: CryptoException) {
            return SavedCredential.Unreadable
        }
        try {
            val credential = unframe(plain) ?: return SavedCredential.Unreadable
            return SavedCredential.Loaded(credential)
        } finally {
            plain.fill(0)
        }
    }

    private fun frame(username: String, password: CharArray): ByteArray {
        val user = username.toByteArray(Charsets.UTF_8)
        val pass = String(password).toByteArray(Charsets.UTF_8)
        try {
            val out = ByteArray(HEADER + user.size + pass.size)
            out[0] = (user.size ushr 8).toByte()
            out[1] = user.size.toByte()
            user.copyInto(out, HEADER)
            pass.copyInto(out, HEADER + user.size)
            return out
        } finally {
            pass.fill(0)
        }
    }

    private fun unframe(plain: ByteArray): Credential? {
        if (plain.size <= HEADER) return null
        val length = ((plain[0].toInt() and 0xFF) shl 8) or (plain[1].toInt() and 0xFF)
        if (length <= 0 || HEADER + length >= plain.size) return null
        val username = String(plain, HEADER, length, Charsets.UTF_8)
        val password = String(plain, HEADER + length, plain.size - HEADER - length, Charsets.UTF_8)
        return Credential(username, password.toCharArray())
    }

    private companion object {
        const val VERSION: Byte = 1
        const val HEADER = 2
    }
}
