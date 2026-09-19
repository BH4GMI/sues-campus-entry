package app.webvpn.entry

import android.util.Log
import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.security.KeyStore
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * 真机上的密钥库与存储路径。
 *
 * 电脑上的单元测试跑的是 JVM AES，**证明不了 AndroidKeyStore 这条路能通**：密钥别名、密钥生成参数、
 * GCM 标签校验、以及「密钥不可导出」这条性质，只有设备上才存在。所以这一份必须在设备上跑
 * （`.\gradlew :app:connectedDebugAndroidTest`）。
 */
@RunWith(AndroidJUnit4::class)
class AndroidKeyStoreBackendTest {

    private companion object {
        /** 测试密钥别名前缀：收尾清理按它筛（产品别名不带这个前缀）。 */
        const val TestAliasPrefix = "campus-entry-test-"
        const val TAG = "教务直达"
    }

    private val alias = "$TestAliasPrefix${System.nanoTime()}"
    private lateinit var backend: AndroidKeyStoreBackend

    @Before
    fun setUp() {
        backend = AndroidKeyStoreBackend(alias)
    }

    /**
     * 收尾：**测试自己造的东西必须自己清掉——这是用户的设备。**
     *
     * 三样：两个测试用 SharedPreferences 文件、以及密钥库里带测试前缀的别名。
     * 最后一样原先每轮漏 11 把（JUnit 每个用例新建一次测试类实例，别名又带纳秒时间戳），
     * 用户看不见但会一直攒——所以这里按**前缀**清，连以前几轮留下的也一起收掉。
     * 产品的数据（`credentials.xml`、真实密钥别名）绝不碰。
     */
    @After
    fun tearDown() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        context.deleteSharedPreferences("credential_test")
        context.deleteSharedPreferences("credential_test_persist")
        Log.i(TAG, "测试收尾：清掉 ${purgeTestKeystoreAliases(TestAliasPrefix)} 把测试密钥")
    }

    @Test
    fun 收尾会清掉测试自己造的密钥别名() {
        val temporary = "$TestAliasPrefix${System.nanoTime()}"
        AndroidKeyStoreBackend(temporary).seal("x".toByteArray())   // 建出密钥
        val before = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        assertTrue("前提：别名应当已存在", before.containsAlias(temporary))

        assertTrue("收尾应当至少清掉这一把", purgeTestKeystoreAliases(TestAliasPrefix) >= 1)

        val after = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        assertFalse("测试别名不该留在用户的密钥库里", after.containsAlias(temporary))
    }

    @Test
    fun 密钥库往返() {
        val plain = "2021001\nhunter2".toByteArray()
        val sealed = backend.seal(plain)
        assertArrayEquals(plain, backend.open(sealed))
    }

    @Test
    fun 每次加密的密文都不同() {
        val plain = "same".toByteArray()
        // IV 每次由系统随机生成，所以同一明文两次加密的结果必须不同
        assertFalse(backend.seal(plain).contentEquals(backend.seal(plain)))
    }

    @Test
    fun 篡改一个字节就解不开() {
        val sealed = backend.seal("hunter2".toByteArray())
        sealed[sealed.size - 1] = (sealed[sealed.size - 1].toInt() xor 0x01).toByte()
        try {
            backend.open(sealed)
            fail("改过的密文不该解得开")
        } catch (expected: CryptoException) {
            // 正是要的结果：GCM 标签拒收，不返回猜测出来的明文
        }
    }

    @Test
    fun 删掉密钥之后旧密文解不开() {
        val sealed = backend.seal("hunter2".toByteArray())
        backend.destroy()
        try {
            backend.open(sealed)
            fail("密钥换过之后旧密文不该解得开")
        } catch (expected: CryptoException) {
        }
    }

    @Test
    fun 密钥不允许导出() {
        backend.seal("触发一次密钥生成".toByteArray())
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val entry = keyStore.getEntry(alias, null) as KeyStore.SecretKeyEntry
        // 这是「加密到底保护了什么」的根据：密钥材料留在系统密钥库（有硬件时留在硬件里），
        // 连本应用自己都拿不到它的字节，能拿到的只是「用它」的能力。
        assertNull("密钥库里的密钥必须不可导出", entry.secretKey.encoded)
    }

    @Test
    fun 保存读取与清除() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val prefs = context.getSharedPreferences("credential_test", Context.MODE_PRIVATE)
        prefs.edit().clear().commit()
        val repository = CredentialRepository(prefs, CredentialStore(backend), backend)

        assertNull("一开始没有账号", repository.savedUsername())

        val username = "2021001"
        val password = "hunter2".toCharArray()
        assertTrue("保存必须真的落盘", repository.save(username, password))

        assertEquals(username, repository.savedUsername())
        val credential = repository.load()
        assertTrue(credential != null)
        assertEquals(username, credential!!.username)
        assertEquals("hunter2", String(credential.password))
        credential.clear()

        // 落盘的是密文，不是明文
        val raw = prefs.getString("credential_blob", null)
        assertTrue(raw != null && raw.isNotEmpty())
        assertFalse("密码不能以明文落盘", raw!!.contains("hunter2"))

        repository.clear()
        assertNull("清除之后不该还能读到", repository.savedUsername())
        assertNull(prefs.getString("credential_blob", null))
    }

    @Test
    fun 换新实例仍能读到同一个账号() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val prefs = context.getSharedPreferences("credential_test_persist", Context.MODE_PRIVATE)
        prefs.edit().clear().commit()
        CredentialRepository(prefs, CredentialStore(backend), backend)
                .save("2021002", "hunter3".toCharArray())

        // 模拟「重开应用」：同一份 prefs + 同一把密钥库密钥，但对象是新的
        val reopened = CredentialRepository(prefs, CredentialStore(backend), backend)
        assertEquals("2021002", reopened.savedUsername())
    }
}
