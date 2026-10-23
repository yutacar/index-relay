package dev.example.index_relay_probe

import android.app.Application
import android.content.Context
import androidx.work.*
import java.util.concurrent.TimeUnit

class RelayApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        co.touchlab.kermit.Logger.setLogWriters()
        if((BuildConfig.DEBUG && BuildConfig.PREVIEW)) try { Class.forName("dev.example.index_relay_probe.DeliveryHarness").getMethod("initialize",Context::class.java).invoke(null,this) } catch (_: Exception) {}
        RelayEngine.get(this) // Reconcile interrupted jobs without creating a Flutter engine.
    }
}
class RelayWork(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val engine = RelayEngine.get(applicationContext)
        return try { if (engine.runWork(id.toString()).get(8, TimeUnit.MINUTES)) Result.success() else Result.retry() }
        catch (_: Exception) { Result.retry() }
        finally { engine.stopWork(id.toString()) }
    }
    override fun onStopped() { RelayEngine.get(applicationContext).stopWork(id.toString()) }
    companion object {
        fun schedule(context: Context) {
            // Append instead of KEEP: a capture racing the previous worker's completion must not be dropped.
            WorkManager.getInstance(context).enqueueUniqueWork("relay.transcription", ExistingWorkPolicy.APPEND_OR_REPLACE,
                OneTimeWorkRequestBuilder<RelayWork>().setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS).build())
        }
    }
}
