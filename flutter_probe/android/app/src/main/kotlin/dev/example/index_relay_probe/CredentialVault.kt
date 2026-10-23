package dev.example.index_relay_probe

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.nio.ByteBuffer
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Step 6 will resolve secrets here at send time. No plaintext fallback or Dart read-back API. */
class CredentialVault(context: Context, private val namespace: String = "destinations") {
    private val folder = run { require(namespace in setOf("destinations", "selftest")); File(context.noBackupFilesDir, "relay/credentials/$namespace").apply { mkdirs() } }
    private val alias = "${context.packageName}.relay.$namespace"
    companion object { private val keyLock = Any() }
    private fun key(): SecretKey = synchronized(keyLock) {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return@synchronized it }
        KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setUserAuthenticationRequired(false).build())
        }.generateKey()
    }
    private fun file(id: UUID) = AtomicFile(File(folder, "$id.bin"))
    fun save(id: UUID, secret: String) {
        require(secret.isNotBlank() && secret.toByteArray().size <= 16_384)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD(id.toString().toByteArray())
        val encrypted = cipher.doFinal(secret.toByteArray())
        val payload = ByteBuffer.allocate(2 + cipher.iv.size + encrypted.size).put(1).put(cipher.iv.size.toByte()).put(cipher.iv).put(encrypted).array()
        val target = file(id); val output = target.startWrite()
        try { output.write(payload); target.finishWrite(output) } catch (e: Exception) { target.failWrite(output); throw e }
    }
    fun load(id: UUID): String {
        val payload = file(id).readFully(); require(payload.size in 30..16_500 && payload[0].toInt() == 1 && payload[1].toInt() == 12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, payload.copyOfRange(2, 14))); cipher.updateAAD(id.toString().toByteArray())
        return cipher.doFinal(payload.copyOfRange(14, payload.size)).toString(Charsets.UTF_8)
    }
    fun remove(id: UUID) { file(id).delete() }
}
