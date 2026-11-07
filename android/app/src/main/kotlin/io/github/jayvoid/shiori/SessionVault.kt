package io.github.jayvoid.shiori

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.system.Os
import android.util.AtomicFile
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Device-bound authenticated encryption. No password or raw key is written to disk. */
class SessionVault(context: Context, private val now: () -> Long = System::currentTimeMillis) {
    companion object {
        const val FILE_NAME = "pixiv-session-v1.bin"
        const val KEY_ALIAS = "io.github.jayvoid.shiori.pixiv-session.v1"
        const val MAX_AGE_MS = 30L * 24 * 60 * 60 * 1000
        private const val VERSION: Byte = 1
        private val AAD = "io.github.jayvoid.shiori/pixiv-session/v1".toByteArray(Charsets.UTF_8)
        private val SESSION = Regex("^[A-Za-z0-9_%.-]{8,512}$")
    }

    private val file = AtomicFile(File(context.noBackupFilesDir, FILE_NAME))
    private fun keyStore() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun newKey(): SecretKey = KeyGenerator.getInstance("AES", "AndroidKeyStore").run {
        init(KeyGenParameterSpec.Builder(KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(256)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .build())
        generateKey()
    }

    @Synchronized
    fun write(session: String) {
        require(SESSION.matches(session)) { "Invalid session" }
        val savedAt = now()
        val plain = JSONObject().put("session", session).put("savedAt", savedAt)
            .put("expiresAt", savedAt + MAX_AGE_MS).toString().toByteArray(Charsets.UTF_8)
        try {
            val key = (keyStore().getKey(KEY_ALIAS, null) as? SecretKey) ?: newKey()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            // Let the provider generate a fresh random nonce on EVERY write.
            cipher.init(Cipher.ENCRYPT_MODE, key)
            cipher.updateAAD(AAD)
            check(cipher.iv.size == 12)
            val encrypted = byteArrayOf(VERSION) + cipher.iv + cipher.doFinal(plain)
            val stream = file.startWrite()
            try {
                Os.fchmod(stream.fd, 0x180) // 0600
                stream.write(encrypted)
                file.finishWrite(stream)
            } catch (error: Exception) {
                file.failWrite(stream)
                throw error
            }
        } catch (error: Exception) {
            // Never restore the previous account after a failed replacement.
            clear()
            throw error
        } finally {
            plain.fill(0)
        }
    }

    @Synchronized
    fun read(): Map<String, Any?> {
        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) {
            return mapOf("session" to null, "discarded" to false)
        }
        try {
            val encrypted = file.openRead().use { input ->
                // Bound reads before allocating; malformed files cannot exhaust memory.
                val bytes = ByteArray(4097)
                var count = 0
                while (count < bytes.size) {
                    val read = input.read(bytes, count, bytes.size - count)
                    if (read < 0) break
                    count += read
                }
                require(count in 30..4096 && bytes[0] == VERSION)
                bytes.copyOf(count)
            }
            val key = keyStore().getKey(KEY_ALIAS, null) as? SecretKey
                ?: throw IllegalStateException("Missing device key")
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, encrypted.copyOfRange(1, 13)))
            cipher.updateAAD(AAD)
            val plain = cipher.doFinal(encrypted, 13, encrypted.size - 13)
            try {
                val data = JSONObject(String(plain, Charsets.UTF_8))
                val session = data.getString("session")
                val savedAt = data.getLong("savedAt")
                val expiresAt = data.getLong("expiresAt")
                val current = now()
                require(SESSION.matches(session) && savedAt > 0 && savedAt <= current &&
                    expiresAt == savedAt + MAX_AGE_MS && expiresAt > current)
                return mapOf("session" to session, "discarded" to false)
            } finally {
                plain.fill(0)
            }
        } catch (_: Exception) {
            // Missing key, authentication failure, expiration or corruption: fail closed.
            clear()
            return mapOf("session" to null, "discarded" to true)
        }
    }

    @Synchronized
    fun clear() {
        try {
            keyStore().deleteEntry(KEY_ALIAS)
        } finally {
            file.delete()
        }
        check(!file.baseFile.exists())
    }
}
