package dev.example.index_relay_probe

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.Executors

/** The only writer of audio, tombstones, receiver checkpoints and transcription jobs. */
class RelayEngine private constructor(private val context: Context) {
    companion object {
        @Volatile private var instance: RelayEngine? = null
        fun get(context: Context): RelayEngine = instance ?: synchronized(this) {
            instance ?: RelayEngine(context.applicationContext).also { instance = it }
        }
    }
    private val database = Executors.newSingleThreadExecutor()
    private val network = Executors.newSingleThreadExecutor()
    private val delivery by lazy { DeliveryQueue(context,store) }
    private val inference = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val store = RelayStore(context)
    private val audio = File(context.noBackupFilesDir, "relay/audio").apply { mkdirs() }
    @Volatile private var storageFailed = false
    private var active: String? = null
    private var activeToken: Long? = null
    private val workers = mutableMapOf<String, CompletableFuture<Boolean>>()
    val receiver = AtomicReference<ReceiverConfig?>(null)
    private val listeners = mutableMapOf<String, () -> Unit>()
    init { database.execute {
        try {
            store.writableDatabase.execSQL("UPDATE recordings SET phase='queued',attempt=NULL WHERE phase='processing'")
            receiver.set(store.config()); prune(); delivery.recover(); RelayWork.schedule(context); planDelivery()
        } catch (_: Exception) { storageFailed = true; ReceiverRuntime.status = "保存情報を開けません。自動処理を停止しました。" }
    } }
    fun listen(listener: () -> Unit): String {
        val key = UUID.randomUUID().toString(); database.execute { listeners[key] = listener }; return key
    }
    fun unlisten(key: String) { database.execute { listeners.remove(key) } }
    fun invalidate() { database.execute { changed() } }
    private fun changed() { listeners.values.toList().forEach { callback -> main.post { callback() } } }
    private fun file(id: String, corrected: Boolean = false): File {
        require(id.matches(Regex("[a-f0-9]{64}")))
        return File(audio, id + if (corrected) ".prepared.wav" else ".wav")
    }
    private fun exists(id: String) = store.rows("SELECT id FROM recordings WHERE id=?", arrayOf(id)).isNotEmpty()
    private fun cleanupAudio() {
        val ids = store.rows("SELECT id FROM recordings").map { it["id"] as String }.toSet()
        if (active?.let { !exists(it) } == true) activeToken?.let { WhisperRecognizer.cancel(it) }
        audio.listFiles()?.forEach { f -> if (f.name.substringBefore('.') !in ids) f.delete() }
    }
    private fun prune() {
        val limit = store.setting("historyLimit")
        store.transaction { db ->
            db.execSQL("INSERT OR IGNORE INTO tombstones SELECT id FROM recordings WHERE id NOT IN (SELECT id FROM recordings ORDER BY createdAt DESC,rowid DESC LIMIT ?)", arrayOf(limit))
            db.execSQL("DELETE FROM recordings WHERE id NOT IN (SELECT id FROM recordings ORDER BY createdAt DESC,rowid DESC LIMIT ?)", arrayOf(limit))
            delivery.pruneDeleted(db)
        }
        DeliveryWork.cancelInvalid(this)
        cleanupAudio()
    }
    private fun <T> submit(action: () -> T): CompletableFuture<T> {
        val future = CompletableFuture<T>()
        database.execute { try { check(!storageFailed); future.complete(action()) } catch (e: Exception) { future.completeExceptionally(e) } }
        return future
    }
    // Debug harness is the only caller; no production channel exposes this inspection.
    fun inspectForTests(): CompletableFuture<Map<String, Any?>> = submit {
        store.snapshot(active != null) + mapOf(
            "frontier" to store.config()?.frontier?.encode(),
            "tombstones" to store.rows("SELECT id FROM tombstones"),
            "schema" to store.readableDatabase.version,
            "audioFiles" to (audio.listFiles()?.map { it.name } ?: emptyList()),
            "flutterActivityRequired" to false)
    }
    fun configuration(): CompletableFuture<ReceiverConfig?> = submit { store.config() }
    fun configureReceiver(address: String, simulation: Boolean, enabled: Boolean): CompletableFuture<ReceiverConfig> = submit {
        require(if (simulation) (BuildConfig.DEBUG && BuildConfig.PREVIEW) && address == "fixture" else address.matches(Regex("[0-9A-F]{2}(:[0-9A-F]{2}){5}")))
        val previous = store.config()
        val config = if (previous?.address == address && previous.simulation == simulation) previous.copy(enabled = enabled)
            else ReceiverConfig(address, simulation, enabled, UUID.randomUUID().toString(), ReceiveFrontier())
        store.writableDatabase.execSQL("INSERT OR REPLACE INTO receiver VALUES (1,?,?,?,?,?)",
            arrayOf<Any>(config.address, if(simulation) 1 else 0, if(enabled) 1 else 0, config.session, config.frontier.encode()))
        receiver.set(config); changed(); config
    }
    fun disableReceiver(): CompletableFuture<Unit> = submit {
        store.writableDatabase.execSQL("UPDATE receiver SET enabled=0 WHERE singleton=1")
        receiver.set(store.config()); changed()
    }
    private fun updateFrontier(session: String, frontier: ReceiveFrontier) {
        store.writableDatabase.execSQL("UPDATE receiver SET frontier=? WHERE singleton=1 AND session=?", arrayOf(frontier.encode(), session))
    }
    fun observeRange(session: String, first: Int, last: Int): CompletableFuture<Unit> = submit {
        val config = requireNotNull(store.config()); check(config.session == session && config.enabled)
        updateFrontier(session, config.frontier.observed(first, last)); receiver.set(store.config())
    }
    fun event(code: String, key: String? = null) { database.execute {
        if (storageFailed) return@execute
        require(code.matches(Regex("[A-Z_]{1,50}")))
        store.writableDatabase.execSQL("INSERT INTO events(time,code,recordingKey) VALUES (?,?,?)", arrayOf<Any?>(System.currentTimeMillis(),code,key))
        store.writableDatabase.execSQL("DELETE FROM events WHERE seq NOT IN (SELECT seq FROM events ORDER BY seq DESC LIMIT 150)")
        changed()
    } }
    fun receive(event: ReceivedAudio, fault: ((String) -> Unit)? = null): CompletableFuture<String> = submit {
        val config = requireNotNull(store.config()); check(config.enabled && config.session == event.session)
        require(event.contiguous && event.start in 0..65535 && event.end in 0..65535)
        require(((event.end - event.start) and 65535) + 1 <= 8192)
        val wav = AudioPreparation.encode(event.samples, event.rate)
        val hash = MessageDigest.getInstance("SHA-256")
        hash.update("${config.session}|${event.rate}|${event.start}|${event.end}|".toByteArray()); hash.update(wav)
        val id = hash.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
        val deleted = store.rows("SELECT id FROM tombstones WHERE id=?", arrayOf(id)).isNotEmpty()
        val duplicate = exists(id)
        if (!deleted && !duplicate) {
            val temp = File(audio, "$id.part")
            try {
                temp.outputStream().use { it.write(wav); it.fd.sync() }
                check(temp.renameTo(file(id)))
            } finally { temp.delete() }
            val directoryFD = android.system.Os.open(audio.absolutePath, android.system.OsConstants.O_RDONLY, 0)
            try { android.system.Os.fsync(directoryFD) } finally { android.system.Os.close(directoryFD) }
            fault?.invoke("after_file")
        }
        val frontier = config.frontier.saved(event.start, event.end)
        store.transaction { db ->
            if (!deleted && !duplicate) {
                val time = event.recordedAt.takeIf { it in 1_577_836_800_000..4_102_444_800_000 } ?: System.currentTimeMillis()
                db.execSQL("INSERT INTO recordings(id,createdAt,phase,samples,sampleRate,simulation) VALUES (?,?,?,?,?,?)",
                    arrayOf<Any>(id,time,if(event.samples.size.toDouble()/event.rate >= .1) "queued" else "needsAttention",event.samples.size,event.rate,if(config.simulation) 1 else 0))
            }
            updateFrontier(config.session, frontier)
        }
        // DB commit and synchronous WAV flush precede every published resume position.
        fault?.invoke("after_db")
        receiver.set(store.config()); prune(); changed()
        if (!deleted && !duplicate) { this.event("AUDIO_SAVED", id.take(12)); RelayWork.schedule(context) }
        id
    }
    fun runWork(id: String): CompletableFuture<Boolean> {
        val future = CompletableFuture<Boolean>()
        database.execute { try { check(!storageFailed); workers[id] = future; pump() } catch (_: Exception) { workers.remove(id); future.complete(false) } }
        return future
    }
    fun stopWork(id: String) { database.execute {
        workers.remove(id)?.complete(false)
        if (workers.isEmpty() && active != null) {
            activeToken?.let { WhisperRecognizer.cancel(it) }
            store.writableDatabase.execSQL("UPDATE recordings SET phase='queued',attempt=NULL WHERE id=? AND phase='processing'", arrayOf(active))
            changed()
        }
    } }
    // Debug harness only: replay an ASR-completion fixture through the same ingest transaction.
    fun completedTextFixture(id: String, text: String): CompletableFuture<Unit> = submit {
        check((BuildConfig.DEBUG && BuildConfig.PREVIEW)); require(id.matches(Regex("[a-f0-9]{64}")) && text.length <= 10000)
        store.transaction { db ->
            db.execSQL("INSERT INTO recordings(id,createdAt,phase,text,samples) VALUES (?,?,'done',?,16000)",arrayOf<Any>(id,System.currentTimeMillis(),text))
            delivery.ingest(db,id,text)
        }
        prune(); changed(); notifyDelivery(); planDelivery()
    }
    fun takeDelivery(): CompletableFuture<DeliveryClaim?> = submit { delivery.claim().also { changed(); notifyDelivery() } }
    fun deliveryActive(claim: DeliveryClaim): CompletableFuture<Boolean> = submit { delivery.active(claim) }
    fun completeDelivery(claim: DeliveryClaim, result: DeliveryOutcome): CompletableFuture<Unit> = submit {
        delivery.complete(claim,result); changed(); notifyDelivery()
    }
    private fun notifyDelivery() {
        if(store.rows("SELECT id FROM deliveries WHERE phase IN ('confirmation','needsAttention','unknown') LIMIT 1").isNotEmpty()) DeliveryNotice.show(context)
    }
    private fun planDelivery() { delivery.nextDelay()?.let { DeliveryWork.schedule(context,it) } }
    fun scheduleDelivery(): CompletableFuture<Unit> = submit { planDelivery() }
    private fun connectedDestination(args: Map<*,*>?, result: MethodChannel.Result) {
        submit { delivery.prepareEdit(requireNotNull(args)) }.whenComplete { edit, error ->
            if(error != null) { deliveryError(error,result); return@whenComplete }
            network.execute {
                try {
                    val target = DeliveryApi.verify(edit.provider,edit.secret,edit.chat,DeliveryApi.transport())
                    submit { delivery.commitEdit(edit,target); planDelivery(); changed(); store.snapshot(active != null) }.whenComplete { value, failure ->
                        if(failure != null) deliveryError(failure,result) else main.post { result.success(value) }
                    }
                } catch(e: Exception) { deliveryError(e,result) }
            }
        }
    }
    private fun deliveryError(error: Throwable, result: MethodChannel.Result) {
        val cause = if(error is java.util.concurrent.CompletionException) error.cause else error
        val message = (cause as? DeliveryError)?.userMessage ?: "操作を完了できません。通信・設定・保存領域を確認してください。"
        main.post { result.error("DELIVERY_ERROR",message,null) }
    }
    fun call(method: String, args: Map<*, *>?, result: MethodChannel.Result) {
        if(method == "saveConnectedDestination") { connectedDestination(args,result); return }
        database.execute {
            try {
                check(!storageFailed)
                when (method) {
                    "snapshot" -> Unit
                    "receiveMock" -> {
                        check(BuildConfig.PREVIEW)
                        val wav = args?.get("wav") as? ByteArray ?: error("Invalid WAV")
                        val samples = AudioPreparation.parse(wav)
                        val id = MessageDigest.getInstance("SHA-256").digest(UUID.randomUUID().toString().toByteArray()).joinToString("") { "%02x".format(it.toInt() and 255) }
                        val f = file(id)
                        try {
                            f.outputStream().use { it.write(wav); it.fd.sync() }
                            store.transaction { db -> db.execSQL("INSERT INTO recordings(id,createdAt,phase,samples) VALUES (?,?,?,?)", arrayOf<Any>(id, System.currentTimeMillis(), "queued", samples.size)) }
                        } catch (e: Exception) { f.delete(); throw e }
                        prune()
                    }
                    "deleteRecordings" -> {
                        val ids = (args?.get("ids") as? List<*>)?.map { it as String } ?: error("Invalid IDs")
                        require(ids.size <= 200)
                        store.transaction { db ->
                            ids.forEach { id -> file(id); db.execSQL("INSERT OR IGNORE INTO tombstones(id) VALUES (?)", arrayOf(id)); db.execSQL("DELETE FROM recordings WHERE id=?", arrayOf(id)) }
                            delivery.pruneDeleted(db)
                        }
                        DeliveryWork.cancelInvalid(this)
                        cleanupAudio()
                    }
                    "saveSettings" -> {
                        val limit = (args?.get("historyLimit") as? Number)?.toInt() ?: error("Invalid limit")
                        val confirmation = args["requiresConfirmation"] as? Boolean ?: error("Invalid confirmation")
                        require(limit in 1..200)
                        store.transaction { db ->
                            db.execSQL("UPDATE settings SET value=? WHERE key='historyLimit'", arrayOf(limit))
                            db.execSQL("UPDATE settings SET value=? WHERE key='requiresConfirmation'", arrayOf(if(confirmation) 1 else 0))
                        }; prune()
                    }
                    "saveDestination" -> {
                        val id = (args?.get("id") as? String)?.also { UUID.fromString(it) } ?: UUID.randomUUID().toString()
                        val name = (args?.get("name") as? String)?.trim() ?: ""
                        val provider = args?.get("provider") as? String ?: ""
                        val prefix = (args?.get("prefix") as? String)?.trim() ?: ""
                        val hint = (args?.get("targetHint") as? String)?.trim() ?: ""
                        require(name.length in 1..80 && prefix.length <= 200 && provider in listOf("discord", "telegram"))
                        require(hint.isEmpty() || if(provider == "telegram") hint.toLongOrNull()?.let { it < 0 && it.toString() == hint } == true else hint.toULongOrNull()?.let { it > 0u && it.toString() == hint } == true)
                        val old = store.rows("SELECT identity FROM destinations WHERE id=?",arrayOf(id)).firstOrNull()
                        if(old != null) throw DeliveryError("既存の送り先は接続確認の画面から編集してください。")
                        store.writableDatabase.execSQL("INSERT INTO destinations(id,name,provider,prefix,targetHint) VALUES (?,?,?,?,?)", arrayOf(id,name,provider,prefix,hint))
                    }
                    "deleteDestination" -> {
                        val id = args?.get("id") as? String ?: error("Invalid ID"); UUID.fromString(id)
                        delivery.removeDestination(id)
                    }
                    "toggleDestination" -> {
                        delivery.toggle(args?.get("id") as String,args["enabled"] as Boolean)
                        DeliveryWork.cancelInvalid(this); planDelivery()
                    }
                    "approveDelivery", "retryDelivery", "cancelDelivery", "dismissUnknown" -> {
                        delivery.action(method,requireNotNull(args)); planDelivery()
                    }
                    "retryTranscription" -> {
                        val id = args?.get("id") as? String ?: error("Invalid ID"); require(file(id).isFile)
                        store.writableDatabase.execSQL("UPDATE recordings SET phase='queued',detail=NULL WHERE id=? AND phase='needsAttention'", arrayOf(id))
                    }
                    else -> { main.post { result.notImplemented() }; return@execute }
                }
                if (method == "receiveMock" || method == "retryTranscription") RelayWork.schedule(context)
                val snapshot = store.snapshot(active != null)
                main.post { result.success(snapshot) }
                if (method != "snapshot") changed()
                pump()
            } catch (e: Exception) { if(e is DeliveryError) deliveryError(e,result) else main.post { result.error("LOCAL_STATE_ERROR", "保存情報または入力内容を確認してください。", null) } }
        }
    }
    fun withAudio(id: String, result: MethodChannel.Result, action: (ByteArray) -> Unit) {
        database.execute {
            try {
                require(exists(id)); val prepared = file(id, true)
                // Prepared files are deterministic derived data; original audio is retained.
                if (!prepared.isFile) {
                    val temp = File(audio, id + ".prepared.part")
                    try {
                        temp.outputStream().use { out -> out.write(AudioPreparation.prepare(file(id).readBytes())); out.fd.sync() }
                        check(temp.renameTo(prepared))
                    } finally { temp.delete() }
                }
                val bytes = prepared.readBytes()
                main.post { action(bytes) }
            } catch (_: Exception) { main.post { result.error("AUDIO_UNAVAILABLE", "音声が削除されたか、利用できません。", null) } }
        }
    }
    private fun pump() {
        if (active != null) return
        if (workers.isEmpty()) return
        val row = store.rows("SELECT * FROM recordings WHERE phase='queued' ORDER BY createdAt,rowid LIMIT 1").firstOrNull()
        if (row == null) { val pending = workers.values.toList(); workers.clear(); pending.forEach { it.complete(true) }; return }
        val id = row["id"] as String; val token = UUID.randomUUID().toString(); active = id
        val nativeToken = WhisperRecognizer.nextToken(); activeToken = nativeToken
        store.writableDatabase.execSQL("UPDATE recordings SET phase='processing',attempt=? WHERE id=?", arrayOf(token,id)); changed()
        inference.execute {
            var output: Map<String, Any>? = null
            var guidance = "音声の再生と端末の空き容量を確認し、再試行してください（音声は最大5分）。"
            try { output = WhisperRecognizer.recognize(context, AudioPreparation.prepare(file(id).readBytes()), nativeToken) }
            catch (e: RecognitionFailure) { guidance = e.guidance }
            catch (_: Exception) {} catch (_: LinkageError) { guidance = "文字起こしエンジンを読み込めません。対応するアプリ版を再インストールしてください。" }
            val done = output
            database.execute {
                try {
                    // Update only, never insert: deleted/pruned recordings cannot be resurrected.
                    if (done != null) store.transaction { db ->
                        val updated = db.compileStatement("UPDATE recordings SET phase='done',text=?,engine=?,elapsedMs=?,detail=NULL WHERE id=? AND phase='processing' AND attempt=?").use { statement ->
                            statement.bindString(1,done["text"] as String); statement.bindString(2,done["engine"] as String); statement.bindLong(3,done["elapsedMs"] as Long); statement.bindString(4,id); statement.bindString(5,token); statement.executeUpdateDelete()
                        }
                        if(updated == 1) delivery.ingest(db,id,done["text"] as String)
                    }
                    else store.writableDatabase.execSQL("UPDATE recordings SET phase='needsAttention',detail=? WHERE id=? AND phase='processing' AND attempt=?", arrayOf(guidance,id,token))
                } catch (_: Exception) { workers.values.forEach { it.complete(false) }; workers.clear() }
                finally { active = null; activeToken = null; changed(); notifyDelivery(); planDelivery(); pump() }
            }
        }
    }
}
