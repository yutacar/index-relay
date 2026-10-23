package dev.example.index_relay_probe

import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import android.bluetooth.BluetoothAdapter
import android.os.*
import kotlinx.coroutines.*
import java.lang.ref.WeakReference

class RingReceiveService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var loading: Job? = null
    private var receiving: Job? = null
    private var config: ReceiverConfig? = null
    private var wake: PowerManager.WakeLock? = null
    private var lastNotification = 0L
    private val engine by lazy { RelayEngine.get(applicationContext) }
    private val radio = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (config?.simulation == false) {
                receiving?.cancel(); receiving = null
                if (ReceiverPermissions.radioReady(context)) begin()
                else ReceiverRuntime.update(context, "Bluetoothがオフです。オンにすると再開します。")
            }
        }
    }
    companion object {
        const val STOP = "dev.example.index_relay_probe.STOP_RECEIVER"
        private var current = WeakReference<RingReceiveService>(null)
        // Reachable only from the debug source-set harness. The release manifest exposes no injection component.
        fun fixture(start: Int, end: Int, stage: String?): Boolean {
            val service = current.get() ?: return false
            if (service.config?.simulation != true || !(BuildConfig.DEBUG && BuildConfig.PREVIEW)) return false
            service.scope.launch {
                try {
                    val input = withContext(Dispatchers.IO) { AudioPreparation.decode(service.assets.open("flutter_assets/assets/japanese.wav").use { it.readBytes() }) }
                    val cfg = requireNotNull(service.config)
                    val event = ReceivedAudio(cfg.session, input.samples, input.rate, start, end, System.currentTimeMillis(), stage != "incomplete")
                    withContext(Dispatchers.IO) {
                        if (service.engine.receiver.get()?.frontier?.next == null) service.engine.observeRange(cfg.session, start, end).get()
                        service.engine.receive(event) { if (it == stage) error("Injected persistence failure") }.get() }
                    service.engine.event("FIXTURE_SAVED")
                } catch (_: Exception) { service.engine.event("FIXTURE_FAILED") }
            }
            return true
        }
    }
    override fun onCreate() {
        super.onCreate(); current = WeakReference(this)
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(radio, filter, RECEIVER_EXPORTED) else registerReceiver(radio, filter)
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("relay.receiver", "リングの自動受信", NotificationManager.IMPORTANCE_LOW))
    }
    private fun notification(text: String): Notification {
        val open = PendingIntent.getActivity(this, 1, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this, 2, Intent(this, RingReceiveService::class.java).setAction(STOP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(this, "relay.receiver").setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("Index Relay 自動受信").setContentText(text).setOngoing(true).setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "停止", stop).build()).build()
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) { engine.disableReceiver(); stopSelf(); return START_NOT_STICKY }
        if (!ReceiverPermissions.ready(this)) { stopSelf(); return START_NOT_STICKY }
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(501, notification("録音を待機しています。"), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            else startForeground(501, notification("録音を待機しています。"))
        } catch (_: Exception) { engine.event("FOREGROUND_START_FAILED"); stopSelf(); return START_NOT_STICKY }
        ReceiverRuntime.running = true
        loading?.cancel()
        loading = scope.launch {
            val cfg = try { withContext(Dispatchers.IO) { engine.configuration().get() } }
                catch (e: CancellationException) { throw e }
                catch (_: Exception) { ReceiverRuntime.update(applicationContext, "保存情報を開けません。受信を停止します。"); stopSelf(); return@launch }
            if (cfg == null || !cfg.enabled || (cfg.simulation && !(BuildConfig.DEBUG && BuildConfig.PREVIEW))) { stopSelf(); return@launch }
            if (config?.session != cfg.session) { receiving?.cancel(); receiving = null }
            config = cfg
            ReceiverRuntime.update(applicationContext, if(cfg.simulation) "試験用サービスで受信を待機しています。" else "リングの録音を待機しています。")
            begin()
        }
        return START_STICKY
    }

    private fun begin() {
        if (receiving?.isActive == true) return
        val cfg = config ?: return
        if (cfg.simulation) return // Same durable acceptance path, without claiming virtual packets are real BLE.
        receiving = scope.launch {
            var delayMs = 2_000L
            while (isActive) {
                if (!ReceiverPermissions.ready(this@RingReceiveService)) { engine.event("PERMISSION_REQUIRED"); stopSelf(); break }
                try {
                    AndroidRingReceiver(applicationContext, cfg, engine, status = { text ->
                        ReceiverRuntime.update(applicationContext, text)
                        if (SystemClock.elapsedRealtime() - lastNotification > 2_000) { getSystemService(NotificationManager::class.java).notify(501, notification(text)); lastNotification = SystemClock.elapsedRealtime() }
                    }, transferring = { active ->
                        if (active) {
                            wake?.let { if(it.isHeld) it.release() }
                            wake = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "IndexRelay:transfer").also { it.acquire(300_000) }
                        } else { wake?.let { if(it.isHeld) it.release() }; wake = null }
                    }, saved = { event -> withContext(Dispatchers.IO) { engine.receive(event).get() } }).run()
                } catch (e: CancellationException) { throw e }
                catch (_: SecurityException) { engine.event("PERMISSION_REQUIRED"); stopSelf(); break }
                catch (_: Exception) { engine.event("RECEIVER_RECONNECT"); ReceiverRuntime.update(applicationContext, "接続を再開します。保存した録音は保持しています。") }
                delay(delayMs); delayMs = (delayMs * 2).coerceAtMost(60_000)
            }
        }
    }
    override fun onDestroy() {
        scope.cancel(); receiving = null; wake?.let { if(it.isHeld) it.release() }; wake = null
        unregisterReceiver(radio); current = WeakReference(null)
        ReceiverRuntime.running = false; ReceiverRuntime.update(this, "自動受信は停止中です。")
        stopForeground(STOP_FOREGROUND_REMOVE); super.onDestroy()
    }
    override fun onBind(intent: Intent?) = null
}
