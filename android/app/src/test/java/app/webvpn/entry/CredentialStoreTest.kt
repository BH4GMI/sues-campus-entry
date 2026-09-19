package app.webvpn.entry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * 凭据编解码、版本与完整性处置。
 *
 * 这里测的是**根因层**：明文怎么摆、什么情况算「解不开」、什么情况算「没保存过」。
 * 上层（界面、自动登录）依赖这些语义，改之前先看 `docs/APP-UX.md` §6。
 */
class CredentialStoreTest {

    private val backend = JvmAesBackend()
    private val store = CredentialStore(backend)

    @Test
    fun 往返() {
        val blob = store.encode("2021001", "correct horse".toCharArray())
        val loaded = store.decode(blob)
        assertTrue(loaded is SavedCredential.Loaded)
        val credential = (loaded as SavedCredential.Loaded).credential
        assertEquals("2021001", credential.username)
        assertEquals("correct horse", String(credential.password))
        credential.clear()
    }

    @Test
    fun 中文账号与长密码同样往返() {
        val password = "密码里有中文与符号 !@#$%^&*()_+-=[]{}|;':\",./<>?".toCharArray()
        val blob = store.encode("张三丰", password)
        val credential = (store.decode(blob) as SavedCredential.Loaded).credential
        assertEquals("张三丰", credential.username)
        assertEquals(String(password), String(credential.password))
        credential.clear()
    }

    @Test
    fun 两段不会被串起来() {
        // 用长度前缀而不是分隔符：账号和密码里出现任何字符都不该把两段串了
        val blob = store.encode("a:b|c\n100", "|:x\n".toCharArray())
        val credential = (store.decode(blob) as SavedCredential.Loaded).credential
        assertEquals("a:b|c\n100", credential.username)
        assertEquals("|:x\n", String(credential.password))
        credential.clear()
    }

    @Test
    fun 落盘的是密文账号和密码都看不见() {
        val blob = store.encode("2021001", "hunter2".toCharArray())
        val asText = String(blob, Charsets.ISO_8859_1)
        // 账号与密码一起进密文，所以两个都不该以明文出现
        assertFalse("密码不能以明文落盘", asText.contains("hunter2"))
        assertFalse("账号也不以明文落盘", asText.contains("2021001"))
    }

    @Test
    fun 密文被改一个字节就解不开() {
        val blob = store.encode("2021001", "hunter2".toCharArray())
        blob[blob.size - 1] = (blob[blob.size - 1].toInt() xor 0x01).toByte()
        assertEquals(SavedCredential.Unreadable, store.decode(blob))
    }

    @Test
    fun 版本号被改就认不出来() {
        val blob = store.encode("2021001", "hunter2".toCharArray())
        blob[0] = 9
        assertEquals(SavedCredential.Unreadable, store.decode(blob))
    }

    @Test
    fun 换过密钥之后旧密文解不开() {
        val blob = store.encode("2021001", "hunter2".toCharArray())
        backend.destroy()
        assertEquals(SavedCredential.Unreadable, store.decode(blob))
    }

    @Test
    fun 没保存过与残缺密文() {
        assertEquals(SavedCredential.Absent, store.decode(null))
        assertEquals(SavedCredential.Absent, store.decode(ByteArray(0)))
        assertEquals("只有版本号，连密文都没有", SavedCredential.Absent, store.decode(byteArrayOf(1)))
    }

    @Test
    fun 明文形态不合法时归为解不开() {
        // 用不加密的后端直接构造明文形态的 blob，专门测格式校验分支
        val plain = CredentialStore(PlainBackend)
        // 长度前缀说 5 个字节，实际只剩 1 个
        assertEquals(SavedCredential.Unreadable, plain.decode(byteArrayOf(1, 0, 5) + "a".toByteArray()))
        // 长度前缀为 0：没有账号
        assertEquals(SavedCredential.Unreadable, plain.decode(byteArrayOf(1, 0, 0, 1, 2)))
        // 只有长度前缀，没有账号也没有密码
        assertEquals(SavedCredential.Unreadable, plain.decode(byteArrayOf(1, 0, 1)))
        // 有账号但密码是空的
        assertEquals(SavedCredential.Unreadable, plain.decode(byteArrayOf(1, 0, 1, 'a'.code.toByte())))
    }

    @Test
    fun 空账号或空密码直接拒绝不落盘() {
        // 存下一组永远登不进去的凭据，会让应用每次启动都替用户消耗一次失败次数
        try {
            store.encode("", "hunter2".toCharArray())
            fail("空账号应当被拒绝")
        } catch (e: IllegalArgumentException) {
            assertNotNull(e.message)
        }
        try {
            store.encode("2021001", CharArray(0))
            fail("空密码应当被拒绝")
        } catch (e: IllegalArgumentException) {
            assertNotNull(e.message)
        }
    }

    @Test
    fun 擦掉密码之后读不到原值() {
        val credential = Credential("2021001", "hunter2".toCharArray())
        credential.clear()
        assertEquals("\u0000\u0000\u0000\u0000\u0000\u0000\u0000", String(credential.password))
        assertNull(credential.password.firstOrNull { it != '\u0000' })
    }

    /** 不加密的后端：用来构造任意「明文形态」的 blob，测格式校验分支。 */
    private object PlainBackend : CryptoBackend {
        override fun seal(plain: ByteArray): ByteArray = plain
        override fun open(sealed: ByteArray): ByteArray = sealed
        override fun destroy() = Unit
    }
}
