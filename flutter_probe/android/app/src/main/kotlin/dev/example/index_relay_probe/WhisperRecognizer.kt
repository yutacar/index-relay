package dev.example.index_relay_probe

import android.content.Context
import java.io.File
import java.security.MessageDigest

class RecognitionFailure(val guidance: String) : Exception()

object WhisperRecognizer {
    private val tokens = java.util.concurrent.atomic.AtomicLong(0)
    private const val SHA = "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
    @Volatile private var stage = "unprepared"
    @Volatile private var verified = false
    fun status(context: Context) = if (stage == "unprepared" && File(context.noBackupFilesDir, "ggml-base.bin").isFile) "unchecked" else stage
    private fun update(context: Context, value: String) { stage = value; RelayEngine.get(context).invalidate() }
    fun nextToken() = tokens.incrementAndGet()
    fun cancel(token: Long) { NativeWhisper.cancel(token) }
    private fun valid(file: File): Boolean {
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(256 * 1024)
            while (true) { val n = input.read(buffer); if (n < 0) break; hash.update(buffer, 0, n) }
        }
        return hash.digest().joinToString("") { "%02x".format(it.toInt() and 255) } == SHA
    }
    // Preparation and inference share one lane; no file copying/hashing on the UI or DB executor.
    @Synchronized fun prepare(context: Context, repair: Boolean = false): File {
        val model = File(context.noBackupFilesDir, "ggml-base.bin")
        if (verified) return model
        val temp = File(context.noBackupFilesDir, "ggml-base.part")
        try {
            update(context, "checking")
            if (!model.isFile || (repair && !valid(model))) {
                update(context, "copying")
                context.assets.open("flutter_assets/assets/ggml-base.bin").use { input ->
                    temp.outputStream().use { output -> input.copyTo(output); output.fd.sync() }
                }
                check(valid(temp)); check(temp.renameTo(model))
            }
            check(valid(model))
            verified = true; update(context, "ready")
            return model
        } catch (_: Exception) {
            update(context, "failed")
            throw RecognitionFailure("設定の「端末内モデル」で準備を再実行してください。空き容量も確認してください。")
        } finally { temp.delete() }
    }
    @Synchronized fun recognize(context: Context, wav: ByteArray, token: Long = nextToken()): Map<String, Any> {
        val model = prepare(context)
        val samples = AudioPreparation.parse(wav)
        if (!samples.any { it.toInt() != 0 }) throw RecognitionFailure("音声が無音です。リングのボタンを押しながら話して録音し直してください。")
        val start = System.nanoTime()
        val text = NativeWhisper.transcribe(model.absolutePath, FloatArray(samples.size) { samples[it] / 32768.0f }, token).trim()
        if (text.isEmpty()) throw RecognitionFailure("認識結果が空です。音声を再生して内容を確認し、再試行または録音し直してください。")
        return mapOf("text" to text, "offline" to true, "engine" to "whisper.cpp 1.9.5 / base / ja",
            "samples" to samples.size, "elapsedMs" to (System.nanoTime() - start) / 1_000_000)
    }
}
