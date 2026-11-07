package io.github.jayvoid.shiori

import android.content.Context
import android.content.pm.ApplicationInfo
import android.security.keystore.KeyInfo
import android.system.Os
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.KeyStore
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory

@RunWith(AndroidJUnit4::class)
class SessionVaultTest {
    private val TEST_FILE_NAME = "integration-session-v1.bin"
    private val TEST_KEY_ALIAS = "io.github.jayvoid.shiori.test-session.v1"
    private fun newVault(now: () -> Long = System::currentTimeMillis) =
        SessionVault(context, keyAlias = TEST_KEY_ALIAS, fileName = TEST_FILE_NAME, now = now)

    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val vault = newVault()
    private val file = File(context.noBackupFilesDir, TEST_FILE_NAME)
    private val session = "synthetic_session_12345678"

    @Before fun before() { vault.clear() }
    @After fun after() { vault.clear() }

    @Test fun roundTripAfterRecreationUsesNonExportable256BitKey() {
        vault.write(session)
        assertEquals(session, newVault().read()["session"])
        assertFalse(String(file.readBytes(), Charsets.UTF_8).contains(session))
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val key = store.getKey(TEST_KEY_ALIAS, null) as SecretKey
        assertNull(key.encoded)
        val info = SecretKeyFactory.getInstance("AES", "AndroidKeyStore")
            .getKeySpec(key, KeyInfo::class.java) as KeyInfo
        assertEquals(256, info.keySize)
        assertArrayEquals(arrayOf("GCM"), info.blockModes)
        assertEquals(context.noBackupFilesDir, file.parentFile)
        assertEquals(0x180, Os.stat(file.path).st_mode and 0x1ff)
        assertEquals(0, context.applicationInfo.flags and ApplicationInfo.FLAG_ALLOW_BACKUP)
    }

    @Test fun everyWriteUsesFreshNonceAndCiphertext() {
        vault.write(session)
        val first = file.readBytes()
        vault.write(session)
        val second = file.readBytes()
        assertFalse(first.copyOfRange(1, 13).contentEquals(second.copyOfRange(1, 13)))
        assertFalse(first.contentEquals(second))
        assertEquals(session, vault.read()["session"])
    }

    @Test fun tamperingIsRejectedAndBothFileAndKeyAreDeleted() {
        vault.write(session)
        val bytes = file.readBytes()
        bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
        file.writeBytes(bytes)
        assertEquals(true, vault.read()["discarded"])
        assertCleared()
    }

    @Test fun missingKeyCannotRestoreCiphertext() {
        vault.write(session)
        KeyStore.getInstance("AndroidKeyStore").apply {
            load(null)
            deleteEntry(TEST_KEY_ALIAS)
        }
        assertEquals(true, vault.read()["discarded"])
        assertCleared()
    }

    @Test fun replacedKeyCannotReadOldCiphertext() {
        vault.write(session)
        val old = file.readBytes()
        vault.clear()
        vault.write(session)
        file.writeBytes(old)
        assertEquals(true, vault.read()["discarded"])
        assertCleared()
    }

    @Test fun expirationAndUnsupportedVersionFailClosed() {
        val start = System.currentTimeMillis()
        newVault { start }.write(session)
        assertEquals(true, newVault {
            start + SessionVault.MAX_AGE_MS
        }.read()["discarded"])
        assertCleared()
        vault.write(session)
        val bytes = file.readBytes()
        bytes[0] = 2
        file.writeBytes(bytes)
        assertEquals(true, vault.read()["discarded"])
        assertCleared()
    }

    @Test fun logoutDeletesKeyAndFileAndInvalidInputIsNotSaved() {
        vault.write(session)
        vault.clear()
        assertCleared()
        assertNull(vault.read()["session"])
        try {
            vault.write("bad\r\nCookie: injected")
            fail("Invalid session accepted")
        } catch (_: IllegalArgumentException) { }
        assertCleared()
    }

    private fun assertCleared() {
        assertFalse(file.exists())
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        assertFalse(store.containsAlias(TEST_KEY_ALIAS))
    }
}
