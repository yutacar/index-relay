package dev.example.index_relay_probe

import android.content.Context
import android.content.Intent
import android.content.BroadcastReceiver
import org.json.JSONObject
import java.io.File

object DeliveryHarness {
    @JvmStatic fun initialize(context: Context) {
        val port = File(context.noBackupFilesDir,"delivery-harness-port").takeIf { it.isFile }?.readText()?.trim()?.toIntOrNull() ?: return
        require(port in 1024..65535)
        DeliveryApi.testNetworkRequired = File(context.noBackupFilesDir,"delivery-harness-network-required").isFile
        DeliveryApi.testTransport = { StrictDeliveryHttp { original ->
            val uri = java.net.URI(original)
            "http://127.0.0.1:$port/${if(uri.host == "discord.com") "discord" else "telegram"}${uri.rawPath}" + (uri.rawQuery?.let { "?$it" } ?: "")
        } }
    }
    fun command(context: Context, intent: Intent, pending: BroadcastReceiver.PendingResult) {
        check(BuildConfig.DEBUG)
        val output = File(context.noBackupFilesDir,"delivery-harness-result.json")
        fun finish(ok: Boolean, code: String = "") {
            val file = android.util.AtomicFile(output); val stream = file.startWrite()
            try { stream.write(JSONObject(mapOf("ok" to ok,"code" to code)).toString().toByteArray()); file.finishWrite(stream) }
            catch(e: Exception) { file.failWrite(stream) }
            finally { pending.finish() }
        }
        try {
            initialize(context)
            val json = JSONObject(File(context.noBackupFilesDir,"delivery-harness-input.json").readText())
            val method = json.getString("method"); val objectArgs = json.optJSONObject("args") ?: JSONObject()
            val args = objectArgs.keys().asSequence().associateWith { key -> objectArgs.get(key).takeIf { it != JSONObject.NULL }?.let { value -> if(value is org.json.JSONArray) (0 until value.length()).map { value.get(it) } else value } }
            val engine = RelayEngine.get(context)
            if(method == "prepareModel") {
                Thread {
                    try { WhisperRecognizer.prepare(context, repair = true); finish(true) }
                    catch (_: Exception) { finish(false,"MODEL_ERROR") }
                }.start()
            } else if(method == "audioFixture") {
                val fixture = File(context.noBackupFilesDir,"compat-fixture.wav")
                require(fixture.length() in 44..9_600_044)
                engine.call("receiveMock",mapOf("wav" to fixture.readBytes()),object:io.flutter.plugin.common.MethodChannel.Result {
                    override fun success(result: Any?) { finish(true) }
                    override fun error(code: String,message: String?,details: Any?) { finish(false,code) }
                    override fun notImplemented() { finish(false,"NOT_IMPLEMENTED") }
                })
            } else if(method == "completedText") {
                engine.completedTextFixture(args["id"] as String,args["text"] as String).whenComplete { _, error -> finish(error == null) }
            } else engine.call(method,args,object:io.flutter.plugin.common.MethodChannel.Result {
                override fun success(result: Any?) { finish(true) }
                override fun error(code: String,message: String?,details: Any?) { finish(false,code) }
                override fun notImplemented() { finish(false,"NOT_IMPLEMENTED") }
            })
        } catch (_: Exception) { finish(false,"HARNESS_ERROR") }
    }
}
