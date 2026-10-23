package dev.example.index_relay_probe

import android.app.Activity
import android.content.*
import android.os.Bundle
import java.util.UUID
import java.io.File
import org.json.JSONObject

class ReceiverHarnessActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        check(BuildConfig.DEBUG)
        RelayEngine.get(this).configureReceiver("fixture", true, true).whenComplete { _, error -> runOnUiThread {
            check(error == null); ReceiverDevices.start(this); finish()
        } }
    }
}
class ReceiverHarnessBroadcast : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        check(BuildConfig.DEBUG)
        val engine = RelayEngine.get(context)
        when (intent.getStringExtra("command")) {
            "delivery" -> DeliveryHarness.command(context,intent,goAsync())
            "capture" -> if (!RingReceiveService.fixture(intent.getIntExtra("start", 0), intent.getIntExtra("end", 0), intent.getStringExtra("fault"))) engine.event("FIXTURE_REJECTED")
            "stop" -> context.startService(Intent(context, RingReceiveService::class.java).setAction(RingReceiveService.STOP))
            "inspect" -> {
                val pending = goAsync()
                engine.inspectForTests().whenComplete { value, error ->
                    try {
                        if (error == null) {
                            val file = android.util.AtomicFile(File(context.noBackupFilesDir, "receiver-test-state.json"))
                            val stream = file.startWrite()
                            try { stream.write(JSONObject(value + mapOf("previewDiagnostics" to true, "mockNetworkRequired" to DeliveryApi.testNetworkRequired, "testTransportActive" to (DeliveryApi.testTransport != null), "mockConfigurationPresent" to File(context.noBackupFilesDir, "delivery-harness-port").exists())).toString().toByteArray()); file.finishWrite(stream) }
                            catch(e: Exception) { file.failWrite(stream); throw e }
                        }
                    } finally { pending.finish() }
                }
            }
            "delete" -> engine.call("deleteRecordings", mapOf("ids" to listOf(requireNotNull(intent.getStringExtra("id")))), object : io.flutter.plugin.common.MethodChannel.Result {
                override fun success(result: Any?) { engine.event("FIXTURE_DELETED") }
                override fun error(code: String, message: String?, details: Any?) { engine.event("FIXTURE_DELETE_FAILED") }
                override fun notImplemented() {}
            })
            "cancel-work" -> androidx.work.WorkManager.getInstance(context).cancelUniqueWork("relay.transcription")
            "checkpoint" -> engine.event("CHECKPOINT")
            "vault" -> {
                val pending = goAsync()
                Thread {
                    try {
                        val id = UUID.fromString("10000000-0000-0000-0000-000000000001")
                        val vault = CredentialVault(context, "selftest")
                        val command = intent.getStringExtra("mode")
                        if (command == "save") vault.save(id, "synthetic-secret-not-a-real-token")
                        val result = vault.load(id) == "synthetic-secret-not-a-real-token"
                        File(context.noBackupFilesDir, "vault-test-result.json").writeText(JSONObject(mapOf("ok" to result)).toString())
                        if (command == "remove") vault.remove(id)
                    } catch (_: Exception) {
                        File(context.noBackupFilesDir, "vault-test-result.json").writeText("{\"ok\":false}")
                    } finally { pending.finish() }
                }.start()
            }
        }
    }
}
