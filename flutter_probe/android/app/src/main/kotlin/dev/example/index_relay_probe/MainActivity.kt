package dev.example.index_relay_probe

import android.app.Activity
import android.content.Intent
import android.media.MediaPlayer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

object NativeWhisper {
    init { System.loadLibrary("index_probe") }
    external fun transcribe(model: String, audio: FloatArray, token: Long): String
    external fun cancel(token: Long)
}
class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private var listener: String? = null
    private var player: MediaPlayer? = null
    private var playbackPending: MethodChannel.Result? = null
    private var playbackGeneration = 0
    private var exportResult: MethodChannel.Result? = null
    private var exportBytes: ByteArray? = null
    private var attached = false
    private var receiverPermissionResult: MethodChannel.Result? = null
    private var receiverPermissionAction: (() -> Unit)? = null
    private var visible = false
    override fun onStart() { super.onStart(); visible = true }
    override fun onStop() { visible = false; super.onStop() }
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
    }
    private fun receiverPermission(result: MethodChannel.Result, action: () -> Unit) {
        if (!visible || android.os.Build.VERSION.SDK_INT < 31 || receiverPermissionResult != null) {
            result.error("RECEIVER_UNAVAILABLE", "Android 12以降で画面を開いて操作してください。", null); return
        }
        if (ReceiverPermissions.ready(this)) { action(); return }
        receiverPermissionResult = result; receiverPermissionAction = action
        requestPermissions(ReceiverPermissions.required(), 902)
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 903) { RelayEngine.get(applicationContext).invalidate(); return }
        if (requestCode != 902) return
        val result = receiverPermissionResult; val action = receiverPermissionAction
        receiverPermissionResult = null; receiverPermissionAction = null
        if (ReceiverPermissions.ready(this) && visible) action?.invoke()
        else result?.error("PERMISSION_REQUIRED", "近くのデバイス（Bluetooth）を許可してください。再表示されない場合はアプリの権限設定で変更できます。", null)
    }
    private fun receiverCall(method: String, args: Map<*, *>?, result: MethodChannel.Result) {
        val engine = RelayEngine.get(applicationContext)
        when (method) {
            "scanReceiver" -> receiverPermission(result) {
                try { ReceiverDevices.scan(this); engine.call("snapshot", null, result) }
                catch (_: Exception) { result.error("BLUETOOTH_UNAVAILABLE", "Bluetoothをオンにし、自動受信を停止して探索してください。", null) }
            }
            "enableReceiver" -> receiverPermission(result) {
                val address = (args?.get("address") as? String)?.uppercase()
                    ?: engine.receiver.get()?.takeIf { !it.simulation }?.address
                if (address == null || !ReceiverPermissions.radioReady(this)) {
                    result.error("RECEIVER_NOT_CONFIGURED", "Bluetoothをオンにし、探索したリングを選んでください。", null); return@receiverPermission
                }
                engine.configureReceiver(address, false, true).whenComplete { _, error -> runOnUiThread {
                    try {
                        check(error == null && visible); ReceiverDevices.start(this)
                        engine.call("snapshot", null, result)
                    } catch (_: Exception) { engine.disableReceiver(); result.error("RECEIVER_START_FAILED", "受信を開始できません。権限・Bluetoothを確認してください。", null) }
                } }
            }
            "disableReceiver" -> engine.disableReceiver().whenComplete { _, error -> runOnUiThread {
                ReceiverDevices.stop(); stopService(Intent(this, RingReceiveService::class.java))
                if (error == null) engine.call("snapshot", null, result)
                else result.error("RECEIVER_STOP_FAILED", "設定を保存できません。", null)
            } }
            "openBluetoothSettings" -> { startActivity(Intent(android.provider.Settings.ACTION_BLUETOOTH_SETTINGS)); result.success(true) }
        }
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        attached = true
        val relay = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "index_relay/relay")
        val engine = RelayEngine.get(applicationContext)
        listener = engine.listen { if (attached && !isDestroyed) relay.invokeMethod("stateChanged", null) }
        relay.setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *>
            when (call.method) {
                "openApplicationSettings" -> {
                    startActivity(Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:$packageName")))
                    result.success(true)
                }
                "prepareModel" -> worker.execute {
                    try { WhisperRecognizer.prepare(applicationContext, repair = true); runOnUiThread { engine.call("snapshot", null, result) } }
                    catch (_: Exception) { runOnUiThread { result.error("MODEL_ERROR", "モデルを準備できません。空き容量を確認し、モデルの準備を再実行してください。", null) } }
                }
                "applicationInfo" -> result.success(mapOf("version" to BuildConfig.VERSION_NAME,"build" to BuildConfig.VERSION_CODE.toString()))
                "requestDeliveryNotifications" -> {
                    if(android.os.Build.VERSION.SDK_INT >= 33 && visible) requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),903)
                    result.success(true)
                }
                "scanReceiver", "enableReceiver", "disableReceiver", "openBluetoothSettings" -> receiverCall(call.method, args, result)
                "playAudio", "exportAudio", "audioBytes" -> {
                    val id = args?.get("id") as? String
                    if (id == null) result.error("INVALID_ID", "音声を選択してください。", null)
                    else engine.withAudio(id, result) { bytes ->
                        when (call.method) {
                            "audioBytes" -> result.success(bytes)
                            "playAudio" -> play(bytes, result)
                            else -> export(bytes, result)
                        }
                    }
                }
                "stopAudio" -> { stopPlayer(); result.success(true) }
                else -> engine.call(call.method, args, result)
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "index_relay/probe").setMethodCallHandler { call, result ->
            if(!BuildConfig.PREVIEW) { result.notImplemented(); return@setMethodCallHandler }
            when (call.method) {
                "nativeReady" -> { NativeWhisper.cancel(0L); result.success(true) }
                "capabilities" -> result.success(HaversineProbe.capabilities())
                "prepareAudio" -> {
                    val bytes = call.argument<ByteArray>("wav")
                    try { result.success(AudioPreparation.prepare(requireNotNull(bytes))) }
                    catch (_: Exception) { result.error("INVALID_WAV", "16kHz mono PCM16 WAVが必要です。", null) }
                }
                "transcribeFixture" -> {
                    val bytes = call.argument<ByteArray>("wav")
                    worker.execute {
                        try {
                            val payload = WhisperRecognizer.recognize(applicationContext, requireNotNull(bytes))
                            runOnUiThread { result.success(payload) }
                        } catch (_: LinkageError) { runOnUiThread { result.error("NATIVE_ENGINE_UNAVAILABLE", "認識エンジンを利用できません。", null) } }
                        catch (_: Exception) { runOnUiThread { result.error("TRANSCRIPTION_FAILED", "音声またはモデルを確認してください。", null) } }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
    private fun stopPlayer() {
        playbackGeneration += 1
        val pending = playbackPending; playbackPending = null
        player?.release(); player = null
        pending?.success(false)
        File(cacheDir, "relay-playback.wav").delete()
    }
    private fun play(bytes: ByteArray, result: MethodChannel.Result) {
        stopPlayer()
        val generation = playbackGeneration
        // The small local WAV is copied on a worker before async preparation.
        worker.execute {
            try {
                val f = File(cacheDir, "relay-playback.wav"); f.writeBytes(bytes)
                runOnUiThread {
                    if (!attached || isDestroyed || generation != playbackGeneration) { result.success(false); return@runOnUiThread }
                    val p = MediaPlayer(); player = p; playbackPending = result
                    try {
                        p.setDataSource(f.absolutePath)
                        p.setOnPreparedListener { if (player === it) { it.start(); val pending = playbackPending; playbackPending = null; pending?.success(true) } }
                        p.setOnCompletionListener { if (player === it) stopPlayer() }
                        p.setOnErrorListener { media, _, _ -> if (player === media) { val pending = playbackPending; playbackPending = null; stopPlayer(); pending?.error("PLAYBACK_FAILED", "音声を再生できません。", null) }; true }
                        p.prepareAsync()
                    } catch (_: Exception) { playbackPending = null; stopPlayer(); result.error("PLAYBACK_FAILED", "音声を再生できません。", null) }
                }
            } catch (_: Exception) { runOnUiThread { result.error("PLAYBACK_FAILED", "音声を再生できません。", null) } }
        }
    }
    private fun export(bytes: ByteArray, result: MethodChannel.Result) {
        if (exportResult != null) { result.error("EXPORT_BUSY", "保存画面を閉じてください。", null); return }
        exportBytes = bytes; exportResult = result
        try {
            startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE); type = "audio/wav"; putExtra(Intent.EXTRA_TITLE, "IndexRelay-corrected.wav")
            }, 803)
        } catch (_: Exception) { exportBytes = null; exportResult = null; result.error("EXPORT_FAILED", "保存画面を開けません。", null) }
    }
    @Deprecated("Android activity result compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != 803) { super.onActivityResult(requestCode, resultCode, data); return }
        val result = exportResult; val bytes = exportBytes; exportResult = null; exportBytes = null
        val uri = data?.data
        if (result == null) return
        if (resultCode != Activity.RESULT_OK || uri == null || bytes == null) { result.success(false); return }
        worker.execute {
            try {
                requireNotNull(contentResolver.openOutputStream(uri, "w")).use { it.write(bytes) }
                runOnUiThread { result.success(true) }
            } catch (_: Exception) { runOnUiThread { result.error("EXPORT_FAILED", "保存できませんでした。", null) } }
        }
    }
    override fun onResume() {
        super.onResume()
        // Cold starts must await DB restoration rather than reading the initially empty atomic cache.
        RelayEngine.get(applicationContext).configuration().whenComplete { config, error -> runOnUiThread {
            if (error == null && visible && !isDestroyed && config?.enabled == true && !config.simulation && ReceiverPermissions.ready(this) && !ReceiverRuntime.running) {
                try { ReceiverDevices.start(this) } catch (_: Exception) { ReceiverRuntime.update(this, "受信を再開するには設定からオンにしてください。") }
            }
        } }
    }
    override fun onPause() { ReceiverDevices.stop(); stopPlayer(); super.onPause() }
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        attached = false; listener?.let { RelayEngine.get(applicationContext).unlisten(it) }; listener = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
    override fun onDestroy() { receiverPermissionResult?.error("ACTIVITY_CLOSED", "画面を閉じました。", null); receiverPermissionResult = null; receiverPermissionAction = null; attached = false; listener?.let { RelayEngine.get(applicationContext).unlisten(it) }; listener = null; stopPlayer(); worker.shutdown(); super.onDestroy() }
}
