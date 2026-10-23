package dev.example.index_relay_probe

import android.content.Context
import androidx.work.*
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

class DeliveryWork(context: Context, params: WorkerParameters) : Worker(context,params) {
    @Volatile private var claim: DeliveryClaim? = null
    @Volatile private var http: DeliveryTransport? = null
    companion object {
        private val running = ConcurrentHashMap<String,DeliveryWork>()
        fun cancelInvalid(engine: RelayEngine) {
            running.values.forEach { work -> work.claim?.let { c ->
                engine.deliveryActive(c).whenComplete { active, _ -> if(active != true && work.claim?.attempt == c.attempt) work.http?.cancel() }
            } }
        }
        fun schedule(context: Context, delayMs: Long = 0) {
            val mock = (BuildConfig.DEBUG && BuildConfig.PREVIEW) && DeliveryApi.testTransport != null && !DeliveryApi.testNetworkRequired
            val request = OneTimeWorkRequestBuilder<DeliveryWork>()
                .setConstraints(Constraints.Builder().setRequiredNetworkType(if(mock) NetworkType.NOT_REQUIRED else NetworkType.CONNECTED).build())
                .setInitialDelay(delayMs.coerceAtLeast(0),TimeUnit.MILLISECONDS)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL,30,TimeUnit.SECONDS).build()
            WorkManager.getInstance(context).enqueueUniqueWork(if(delayMs > 0) "relay.delivery.retry" else "relay.delivery.now",
                if(delayMs > 0) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.APPEND_OR_REPLACE,request)
        }
    }
    override fun doWork(): Result {
        val engine = RelayEngine.get(applicationContext)
        running[id.toString()] = this
        val deadline = System.nanoTime()+TimeUnit.SECONDS.toNanos(50)
        return try {
            while(!isStopped && System.nanoTime() < deadline) {
                val current = engine.takeDelivery().get() ?: break
                claim = current
                if(isStopped) { engine.completeDelivery(current,DeliveryOutcome("unknown")).get(); break }
                val client = DeliveryApi.transport(); http = client
                if(!engine.deliveryActive(current).get() || isStopped) { client.cancel(); claim = null; continue }
                val result = try {
                    val url = if(current.provider == "discord") DeliveryApi.webhook(current.secret,true) else DeliveryApi.telegram(current.secret,"sendMessage")
                    val payload = DeliveryApi.payload(current.provider,current.target,current.text,current.mentions)
                    DeliveryApi.classify(current.provider,client.exchange(url,payload))
                } catch (_: Exception) { DeliveryOutcome("needsAttention","資格情報・本文・送り先を確認してください。") }
                engine.completeDelivery(current,if(isStopped) DeliveryOutcome("unknown") else result).get()
                http = null; claim = null
            }
            engine.scheduleDelivery().get()
            Result.success()
        } catch (_: Exception) { claim?.let { engine.completeDelivery(it,DeliveryOutcome("unknown")) }; Result.retry() }
        finally { running.remove(id.toString()); http?.cancel(); http = null }
    }
    override fun onStopped() {
        http?.cancel()
        claim?.let { RelayEngine.get(applicationContext).completeDelivery(it,DeliveryOutcome("unknown")) }
    }
}
object DeliveryNotice {
    fun show(context: Context) {
        if(android.os.Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) return
        val manager = context.getSystemService(android.app.NotificationManager::class.java)
        manager.createNotificationChannel(android.app.NotificationChannel("relay.delivery","送信の確認・要対応",android.app.NotificationManager.IMPORTANCE_DEFAULT))
        val open = android.app.PendingIntent.getActivity(context,10,android.content.Intent(context,MainActivity::class.java),android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT)
        val notice = android.app.Notification.Builder(context,"relay.delivery").setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Index Relay").setContentText("確認が必要な送信があります。アプリの送信一覧を開いてください。")
            .setVisibility(android.app.Notification.VISIBILITY_PRIVATE).setContentIntent(open).setAutoCancel(true).build()
        try { manager.notify(502,notice) } catch (_: SecurityException) {}
    }
}
