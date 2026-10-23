package dev.example.index_relay_probe

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.io.File

/** All access is serialized by RelayEngine. Flutter never writes these files. */
class RelayStore(context: Context) : SQLiteOpenHelper(context, File(File(context.noBackupFilesDir, "relay").apply { mkdirs() }, "relay.db").absolutePath, null, 3, android.database.DatabaseErrorHandler { throw android.database.sqlite.SQLiteException("Local database unavailable; preserving files") }) {
    private val appContext = context.applicationContext
    fun config(): ReceiverConfig? = rows("SELECT * FROM receiver WHERE singleton=1").firstOrNull()?.let { ReceiverConfig(it["address"] as String, it["simulation"] == 1L, it["enabled"] == 1L, it["session"] as String, ReceiveFrontier.decode(it["frontier"] as String)) }
    override fun onConfigure(db: SQLiteDatabase) { db.execSQL("PRAGMA synchronous=FULL") }
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE settings (key TEXT PRIMARY KEY, value INTEGER NOT NULL)")
        db.execSQL("INSERT INTO settings VALUES ('historyLimit',30),('requiresConfirmation',1)")
        db.execSQL("CREATE TABLE recordings (id TEXT PRIMARY KEY, createdAt INTEGER NOT NULL, phase TEXT NOT NULL, text TEXT NOT NULL DEFAULT '', samples INTEGER NOT NULL, engine TEXT NOT NULL DEFAULT '', elapsedMs INTEGER NOT NULL DEFAULT 0, attempt TEXT, detail TEXT)")
        db.execSQL("CREATE TABLE destinations (id TEXT PRIMARY KEY, name TEXT NOT NULL, provider TEXT NOT NULL, prefix TEXT NOT NULL, targetHint TEXT NOT NULL)")
        createReceiverTables(db)
        DeliveryQueue.create(db)
    }
    private fun createReceiverTables(db: SQLiteDatabase) {
        db.execSQL("ALTER TABLE recordings ADD COLUMN sampleRate INTEGER NOT NULL DEFAULT 16000")
        db.execSQL("ALTER TABLE recordings ADD COLUMN simulation INTEGER NOT NULL DEFAULT 1")
        db.execSQL("CREATE TABLE receiver (singleton INTEGER PRIMARY KEY CHECK(singleton=1), address TEXT NOT NULL, simulation INTEGER NOT NULL, enabled INTEGER NOT NULL, session TEXT NOT NULL, frontier TEXT NOT NULL)")
        db.execSQL("CREATE TABLE tombstones (id TEXT PRIMARY KEY)")
        db.execSQL("CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, time INTEGER NOT NULL, code TEXT NOT NULL, recordingKey TEXT)")
    }
    override fun onUpgrade(db: SQLiteDatabase, old: Int, new: Int) { require(old in 1..2 && new == 3); if(old == 1) createReceiverTables(db); DeliveryQueue.create(db) }
    fun rows(sql: String, args: Array<String> = emptyArray()): List<Map<String, Any?>> = readableDatabase.rawQuery(sql, args).use { c ->
        buildList { while (c.moveToNext()) {
            add(c.columnNames.indices.associate { i -> c.columnNames[i] to when(c.getType(i)) {
                android.database.Cursor.FIELD_TYPE_INTEGER -> c.getLong(i)
                android.database.Cursor.FIELD_TYPE_NULL -> null
                else -> c.getString(i)
            } })
        } }
    }
    fun setting(key: String) = (rows("SELECT value FROM settings WHERE key=?", arrayOf(key)).single()["value"] as Long).toInt()
    fun snapshot(busy: Boolean): Map<String, Any> = mapOf(
        "historyLimit" to setting("historyLimit"), "requiresConfirmation" to (setting("requiresConfirmation") == 1),
        "recordings" to rows("SELECT * FROM recordings ORDER BY createdAt DESC, rowid DESC").map { it + ("simulation" to (it["simulation"] == 1L)) + DeliveryQueue(appContext,this).recordingStatus(it["id"] as String) },
        "destinations" to DeliveryQueue(appContext,this).publicDestinations(), "deliveries" to DeliveryQueue(appContext,this).publicJobs(), "busy" to busy,
        "simulation" to true, "postingAvailable" to true,
        "androidReceiver" to true, "receiverEnabled" to (config()?.enabled == true),
        "receiverRunning" to ReceiverRuntime.running, "receiverStatus" to ReceiverRuntime.status,
        "receiverSimulation" to (config()?.simulation ?: false),
        "receiverCandidates" to ReceiverDevices.candidates(),
        "receiverName" to (config()?.let { if(it.simulation) "試験用リング" else "登録済みIndex01" } ?: "未登録"),
        "receiverPermission" to ReceiverPermissions.ready(context = appContext),
        "capabilities" to ReceiverPermissions.capabilities(appContext),
        "modelStatus" to WhisperRecognizer.status(appContext),
        "receiverEvents" to rows("SELECT time,code,recordingKey FROM events ORDER BY seq DESC LIMIT 50")
    )
    fun transaction(action: (SQLiteDatabase) -> Unit) {
        val db = writableDatabase; db.beginTransaction()
        try { action(db); db.setTransactionSuccessful() } finally { db.endTransaction() }
    }
}
