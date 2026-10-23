package dev.example.index_relay_probe

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothManager
import android.bluetooth.le.*
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.*
import java.util.UUID

object ReceiverPermissions {
    fun required(): Array<String> = buildList {
        if (Build.VERSION.SDK_INT >= 31) { add(Manifest.permission.BLUETOOTH_SCAN); add(Manifest.permission.BLUETOOTH_CONNECT) }
    }.toTypedArray()
    fun notifications(context: Context) = androidx.core.app.NotificationManagerCompat.from(context).areNotificationsEnabled()
    fun networkReady(context: Context): Boolean {
        val manager = context.getSystemService(android.net.ConnectivityManager::class.java)
        val caps = manager?.getNetworkCapabilities(manager.activeNetwork) ?: return false
        return caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }
    fun capabilities(context: Context): Map<String, Any> = mapOf(
        "api" to Build.VERSION.SDK_INT, "supported" to (Build.VERSION.SDK_INT >= 31),
        "bluetooth" to ready(context), "radio" to radioReady(context), "notifications" to notifications(context), "network" to networkReady(context)
    )
    fun ready(context: Context) = Build.VERSION.SDK_INT >= 31 && required().all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
    fun radioReady(context: Context): Boolean = try {
        ready(context) && context.getSystemService(BluetoothManager::class.java)?.adapter?.isEnabled == true
    } catch (_: SecurityException) { false }
}
object ReceiverRuntime {
    @Volatile var running = false
    @Volatile var status = "自動受信は停止中です。"
    fun update(context: Context, value: String) { status = value; RelayEngine.get(context).invalidate() }
}
object ReceiverDevices {
    const val SERVICE = "607B5C9B-3700-4E94-F44A-2DF900BCB0C3"
    private val found = java.util.concurrent.ConcurrentHashMap<String, String>()
    private val main = Handler(Looper.getMainLooper())
    private var scanner: BluetoothLeScanner? = null
    private var callback: ScanCallback? = null
    fun candidates(): List<Map<String,String>> = found.entries.sortedBy { it.key }.map { mapOf("address" to it.key, "name" to it.value) }
    fun scan(context: Context) {
        check(ReceiverPermissions.radioReady(context)); check(!ReceiverRuntime.running)
        stop(); found.clear()
        val native = requireNotNull(context.getSystemService(BluetoothManager::class.java)?.adapter?.bluetoothLeScanner)
        val cb = object : ScanCallback() {
            override fun onScanResult(type: Int, result: ScanResult) {
                try { found[result.device.address.uppercase()] = result.scanRecord?.deviceName?.take(80) ?: "Index01"; RelayEngine.get(context).invalidate() }
                catch (_: SecurityException) { stop(); ReceiverRuntime.update(context, "Bluetoothの権限を確認してください。") }
            }
            override fun onScanFailed(errorCode: Int) { stop(); ReceiverRuntime.update(context, "探索を開始できません。Bluetoothと権限を確認してください。") }
        }
        scanner = native; callback = cb
        try {
            native.startScan(listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(UUID.fromString(SERVICE))).build()),
                ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), cb)
            ReceiverRuntime.update(context, "リングを探索しています（15秒）。")
            main.postDelayed({ if (callback === cb) { stop(); ReceiverRuntime.update(context, if (found.isEmpty()) "見つかりませんでした。リングを近づけ、他のアプリの接続を停止して再探索してください。" else "探索が終了しました。リングを選択してください。") } }, 15_000)
        } catch (e: Exception) { stop(); throw e }
    }
    fun stop() {
        val cb = callback; callback = null
        try { if (cb != null) scanner?.stopScan(cb) } catch (_: SecurityException) {} finally { scanner = null }
    }
    fun start(context: Context) {
        stop()
        val intent = Intent(context, RingReceiveService::class.java)
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
    }
}
