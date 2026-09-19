package app.webvpn.entry

/**
 * 加解密后端。
 *
 * 这一层是**唯一**与平台密码学打交道的地方：生产实现走 AndroidKeyStore
 * （[AndroidKeyStoreBackend]），单元测试用 JVM 上的 AES-GCM（`JvmAesBackend`）。
 * 上面那层（[CredentialStore]）因此完全不依赖 Android，可以在电脑上跑测试。
 */
interface CryptoBackend {

    /**
     * 加密。
     *
     * 返回值必须**自带 IV 与完整性标签**——AES-GCM 的 IV 是每次加密新生成的，不存下来就解不开，
     * 所以「怎么摆 IV」由实现自己决定，调用方只当它是一段不透明的字节。
     */
    fun seal(plain: ByteArray): ByteArray

    /**
     * 解密并校验完整性。
     *
     * 密文被改过、或密钥换过（例如用户清过账号），必须抛 [CryptoException]，
     * **绝不返回猜测出来的明文**。
     */
    fun open(sealed: ByteArray): ByteArray

    /**
     * 丢弃密钥材料。
     *
     * 之后**旧的密文再也解不开**——这正是「清除账号」要的效果：删掉密钥，比删掉密文更彻底。
     */
    fun destroy()
}

/**
 * 密码学操作失败。
 *
 * 只有一个用途：让上层能把「解不开」与「没保存过」归到同一条处置路径上（当作没有凭据，
 * 让用户重新登录一次），而不是崩溃或猜测。
 */
class CryptoException(message: String, cause: Throwable? = null) : Exception(message, cause)
