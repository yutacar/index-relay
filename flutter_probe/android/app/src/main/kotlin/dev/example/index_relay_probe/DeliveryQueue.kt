package dev.example.index_relay_probe

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import java.util.UUID

data class DeliveryEdit(val id: String, val revision: Long?, val name: String, val provider: String, val prefix: String, val chat: String, val secret: String, val enabled: Boolean)
data class DeliveryClaim(val id: String, val attempt: String, val provider: String, val target: String, val text: String, val mentions: String, val secret: String)

/** Only accessed on RelayEngine's DB executor. No network calls on that executor. */
class DeliveryQueue(private val context: Context, private val store: RelayStore) {
    private val vault = CredentialVault(context)
    companion object {
        val terminal = listOf("sent","cancelled")
        fun create(db: SQLiteDatabase) {
            db.execSQL("ALTER TABLE destinations ADD COLUMN identity TEXT NOT NULL DEFAULT ''")
            db.execSQL("ALTER TABLE destinations ADD COLUMN kind TEXT NOT NULL DEFAULT ''")
            db.execSQL("ALTER TABLE destinations ADD COLUMN enabled INTEGER NOT NULL DEFAULT 0")
            db.execSQL("ALTER TABLE destinations ADD COLUMN credentialKey TEXT")
            db.execSQL("ALTER TABLE destinations ADD COLUMN revision INTEGER NOT NULL DEFAULT 0")
            db.execSQL("CREATE TABLE providerCooldown(provider TEXT PRIMARY KEY,until INTEGER NOT NULL)")
            db.execSQL("CREATE TABLE deliverySeen(recordingID TEXT PRIMARY KEY)")
            // Existing transcripts form a baseline. Adding a destination never backfills them.
            db.execSQL("INSERT INTO deliverySeen SELECT id FROM recordings WHERE phase='done'")
            db.execSQL("CREATE TABLE deliveries(id TEXT PRIMARY KEY,recordingID TEXT NOT NULL,destinationID TEXT NOT NULL,destinationName TEXT NOT NULL,provider TEXT NOT NULL,targetIdentity TEXT NOT NULL,target TEXT NOT NULL,text TEXT NOT NULL,mentions TEXT NOT NULL,createdAt INTEGER NOT NULL,confirmationRequired INTEGER NOT NULL,phase TEXT NOT NULL,attempt TEXT,attempts INTEGER NOT NULL DEFAULT 0,retryAfter INTEGER,receipt TEXT,detail TEXT,UNIQUE(recordingID,destinationID))")
            db.execSQL("CREATE INDEX deliveries_due ON deliveries(phase,retryAfter)")
        }
        fun title(phase: String) = when(phase) {
            "confirmation" -> "確認待ち"; "queued" -> "送信待ち"; "sending" -> "送信中"; "sent" -> "送信済み"
            "retryWaiting" -> "再試行待ち"; "needsAttention" -> "要対応"; "unknown" -> "結果不明"; else -> "送信しない"
        }
    }
    fun recover() { store.writableDatabase.execSQL("UPDATE deliveries SET phase='unknown',detail='前回の送信結果を回収できません。送り先で確認してください。自動再送は行いません。' WHERE phase='sending'") }
    fun prepareEdit(args: Map<*,*>): DeliveryEdit {
        val id = (args["id"] as? String)?.also { UUID.fromString(it) } ?: UUID.randomUUID().toString()
        val old = store.rows("SELECT * FROM destinations WHERE id=?",arrayOf(id)).firstOrNull()
        val name = (args["name"] as? String)?.trim() ?: ""
        val provider = args["provider"] as? String ?: ""
        val prefix = (args["prefix"] as? String)?.trim() ?: ""
        val chat = (args["targetHint"] as? String)?.trim() ?: ""
        if (name.length !in 1..80 || prefix.length > 200 || provider !in listOf("discord","telegram")) throw DeliveryError("表示名・接頭語・サービスを確認してください。")
        if (old != null && old["provider"] != provider) throw DeliveryError("サービスの変更は新しい送り先として追加してください。")
        val input = (args["secret"] as? String)?.trim() ?: ""
        val secret = if(input.isNotEmpty()) input else try { vault.load(UUID.fromString(old?.get("credentialKey") as? String)) } catch (_: Exception) { throw DeliveryError("資格情報を入力してください。保存済みの値は画面へ読み出しません。") }
        if(secret.length > 16384) throw DeliveryError("資格情報を確認してください。")
        return DeliveryEdit(id, old?.get("revision") as? Long,name,provider,prefix,chat,secret,args["enabled"] as? Boolean ?: true)
    }
    fun commitEdit(edit: DeliveryEdit, target: VerifiedTarget) {
        val old = store.rows("SELECT * FROM destinations WHERE id=?",arrayOf(edit.id)).firstOrNull()
        if((old?.get("revision") as? Long) != edit.revision) throw DeliveryError("設定が変更されました。開き直して登録してください。")
        if(old?.get("identity")?.let { it != "" && it != target.identity } == true) throw DeliveryError("登録済みと異なる送り先です。新しい送り先として追加してください。")
        if(store.rows("SELECT id FROM destinations WHERE identity=? AND id<>?",arrayOf(target.identity,edit.id)).isNotEmpty()) throw DeliveryError("同じ送り先は登録済みです。")
        val key = UUID.randomUUID(); vault.save(key,edit.secret)
        try {
            store.writableDatabase.execSQL("INSERT OR REPLACE INTO destinations(id,name,provider,prefix,targetHint,identity,kind,enabled,credentialKey,revision) VALUES (?,?,?,?,?,?,?,?,?,?)",
                arrayOf<Any>(edit.id,edit.name,edit.provider,edit.prefix,target.target,target.identity,target.kind,if(edit.enabled) 1 else 0,key.toString(),(edit.revision ?: 0)+1))
        } catch(e: Exception) { vault.remove(key); throw e }
        // The DB points to the new encrypted file before the old one is removed.
        try { (old?.get("credentialKey") as? String)?.let { vault.remove(UUID.fromString(it)) } } catch (_: Exception) {}
    }
    fun toggle(id: String, enabled: Boolean) {
        val old = store.rows("SELECT * FROM destinations WHERE id=?",arrayOf(id)).firstOrNull() ?: throw DeliveryError("送り先が見つかりません。")
        if(enabled && (old["identity"] == "" || old["credentialKey"] == null)) throw DeliveryError("資格情報を登録して送り先を確認してください。")
        store.writableDatabase.execSQL("UPDATE destinations SET enabled=?,revision=revision+1 WHERE id=?",arrayOf<Any>(if(enabled) 1 else 0,id))
        if(!enabled) store.writableDatabase.execSQL("UPDATE deliveries SET phase='unknown',detail='送信中に送り先を停止しました。投稿先で結果を確認してください。' WHERE destinationID=? AND phase='sending'",arrayOf(id))
    }
    fun removeDestination(id: String) {
        if(store.rows("SELECT id FROM deliveries WHERE destinationID=? AND phase NOT IN ('sent','cancelled')",arrayOf(id)).isNotEmpty()) throw DeliveryError("未完了の送信があります。送信一覧で確認・取消を済ませてください。")
        val key = store.rows("SELECT credentialKey FROM destinations WHERE id=?",arrayOf(id)).firstOrNull()?.get("credentialKey") as? String
        store.writableDatabase.execSQL("DELETE FROM destinations WHERE id=?",arrayOf(id))
        try { key?.let { vault.remove(UUID.fromString(it)) } } catch (_: Exception) {}
    }
    fun ingest(db: SQLiteDatabase, recordingID: String, text: String) {
        if(store.rows("SELECT recordingID FROM deliverySeen WHERE recordingID=?",arrayOf(recordingID)).isNotEmpty()) return
        val confirmation = store.setting("requiresConfirmation") == 1
        for (destination in store.rows("SELECT * FROM destinations WHERE enabled=1 AND identity<>'' AND credentialKey IS NOT NULL")) {
            val provider = destination["provider"] as String; val prefix = destination["prefix"] as String
            val content = DeliveryApi.text(prefix,text); val valid = DeliveryApi.validText(provider,content)
            db.execSQL("INSERT OR IGNORE INTO deliveries(id,recordingID,destinationID,destinationName,provider,targetIdentity,target,text,mentions,createdAt,confirmationRequired,phase,detail) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                arrayOf<Any?>(UUID.randomUUID().toString(),recordingID,destination["id"],destination["name"],provider,destination["identity"],destination["targetHint"],content,DeliveryApi.mentions(prefix),System.currentTimeMillis(),if(confirmation) 1 else 0,if(!valid) "needsAttention" else if(confirmation) "confirmation" else "queued",if(valid) null else "文字数上限を超えています。本文を短く編集してください。"))
        }
        db.execSQL("INSERT OR IGNORE INTO deliverySeen VALUES (?)",arrayOf(recordingID))
    }
    fun pruneDeleted(db: SQLiteDatabase) { db.execSQL("DELETE FROM deliveries WHERE recordingID NOT IN (SELECT id FROM recordings)") }
    fun publicJobs() = store.rows("SELECT id,recordingID,destinationID,destinationName,provider,text,createdAt,confirmationRequired,phase,attempts,retryAfter,receipt,detail FROM deliveries ORDER BY createdAt DESC,rowid DESC").map { it + ("title" to title(it["phase"] as String)) }
    fun publicDestinations() = store.rows("SELECT id,name,provider,prefix,targetHint,identity,kind,enabled FROM destinations ORDER BY rowid").map { it + mapOf("enabled" to (it["enabled"] == 1L),"verified" to (it["identity"] != "")) }
    fun recordingStatus(id: String): Map<String,Any> {
        val phases = store.rows("SELECT phase FROM deliveries WHERE recordingID=?",arrayOf(id)).map { it["phase"] as String }
        if(phases.isEmpty()) return mapOf("deliveryTitle" to "未連携", "deliveryComplete" to false)
        val complete = phases.all { it == "sent" }
        val priority = listOf("unknown","needsAttention","confirmation","sending","retryWaiting","queued","cancelled","sent")
        val selected = priority.first { it in phases }
        return mapOf("deliveryTitle" to if(complete) "連携済み（${phases.size}件）" else "${title(selected)}（${phases.count { it == "sent" }}/${phases.size}件送信済み）", "deliveryComplete" to complete)
    }
    fun action(method: String, args: Map<*,*>) {
        val id = args["id"] as? String ?: throw DeliveryError("送信項目を選択してください。")
        val job = store.rows("SELECT * FROM deliveries WHERE id=?",arrayOf(id)).firstOrNull() ?: throw DeliveryError("送信状況が変わりました。画面を開き直してください。")
        val phase = job["phase"] as String
        when(method) {
            "cancelDelivery" -> {
                if(phase in listOf("sending","sent","unknown")) throw DeliveryError("送信結果を確認してください。")
                store.writableDatabase.execSQL("UPDATE deliveries SET phase='cancelled',detail=NULL WHERE id=?",arrayOf(id))
            }
            "dismissUnknown" -> {
                if(phase != "unknown") throw DeliveryError("送信状況が変わりました。")
                store.writableDatabase.execSQL("UPDATE deliveries SET phase='cancelled',detail='投稿先で結果を確認し、再送しないことを選択しました。' WHERE id=?",arrayOf(id))
            }
            else -> {
                if(phase !in listOf("confirmation","needsAttention","retryWaiting","unknown")) throw DeliveryError("送信状況が変わりました。")
                if(phase == "unknown" && args["allowUnknown"] != true) throw DeliveryError("重複投稿の可能性を確認してから再送してください。")
                if(phase == "retryWaiting" && (job["retryAfter"] as? Long ?: 0) > System.currentTimeMillis()) throw DeliveryError("指定された待機時間の後に再試行してください。")
                val content = args["text"] as? String ?: job["text"] as String
                if(!DeliveryApi.validText(job["provider"] as String,content)) throw DeliveryError("本文が空か文字数上限を超えています。")
                val target = store.rows("SELECT identity FROM destinations WHERE id=?",arrayOf(job["destinationID"] as String)).firstOrNull()
                if(target?.get("identity") != job["targetIdentity"]) throw DeliveryError("送り先が一致しません。設定を確認してください。")
                store.writableDatabase.execSQL("UPDATE deliveries SET phase='queued',text=?,detail=NULL,retryAfter=NULL,attempts=0 WHERE id=?",arrayOf(content,id))
            }
        }
    }
    fun claim(): DeliveryClaim? {
        if(store.rows("SELECT id FROM deliveries WHERE phase='sending' LIMIT 1").isNotEmpty()) return null
        val now = System.currentTimeMillis()
        for(job in store.rows("SELECT j.* FROM deliveries j JOIN destinations d ON d.id=j.destinationID AND d.enabled=1 AND d.identity=j.targetIdentity WHERE j.phase IN ('queued','retryWaiting') ORDER BY j.createdAt,j.rowid")) {
            val cooldown = store.rows("SELECT until FROM providerCooldown WHERE provider=?",arrayOf(job["provider"] as String)).firstOrNull()?.get("until") as? Long ?: 0
            if(cooldown > now || (job["retryAfter"] as? Long ?: 0) > now) continue
            val id = job["id"] as String
            val credential = try {
                val key = store.rows("SELECT credentialKey FROM destinations WHERE id=?",arrayOf(job["destinationID"] as String)).first()["credentialKey"] as String
                vault.load(UUID.fromString(key))
            } catch (_: Exception) {
                store.writableDatabase.execSQL("UPDATE deliveries SET phase='needsAttention',detail='資格情報を読み出せません。設定から再入力してください。' WHERE id=?",arrayOf(id)); continue
            }
            val attempt = UUID.randomUUID().toString()
            store.writableDatabase.execSQL("UPDATE deliveries SET phase='sending',attempt=?,attempts=attempts+1,detail=NULL,retryAfter=NULL WHERE id=?",arrayOf(attempt,id))
            return DeliveryClaim(id,attempt,job["provider"] as String,job["target"] as String,job["text"] as String,job["mentions"] as String,credential)
        }
        return null
    }
    fun active(claim: DeliveryClaim) = store.rows("SELECT id FROM deliveries WHERE id=? AND attempt=? AND phase='sending'",arrayOf(claim.id,claim.attempt)).isNotEmpty()
    fun complete(claim: DeliveryClaim, result: DeliveryOutcome) {
        val job = store.rows("SELECT * FROM deliveries WHERE id=? AND attempt=? AND phase='sending'",arrayOf(claim.id,claim.attempt)).firstOrNull() ?: return
        if(result.pauseProvider) store.writableDatabase.execSQL("UPDATE destinations SET enabled=0,revision=revision+1 WHERE provider=?",arrayOf(claim.provider))
        if(result.phase == "retryWaiting") {
            val due = System.currentTimeMillis()+result.seconds*1000
            store.writableDatabase.execSQL("INSERT OR REPLACE INTO providerCooldown(provider,until) VALUES (?,MAX(?,COALESCE((SELECT until FROM providerCooldown WHERE provider=?),0)))",arrayOf<Any>(claim.provider,due,claim.provider))
        }
        var outcome = result
        if(result.phase == "retryWaiting" && (job["attempts"] as Long) >= 5) outcome = DeliveryOutcome("needsAttention","再試行が続いています。設定・通信状態を確認してください。")
        val detail = outcome.detail ?: when(outcome.phase) {
            "unknown" -> "投稿が成立した可能性があります。投稿先で確認してください。自動再送は行いません。"
            "retryWaiting" -> "未投稿と判断できる応答です。時間を置いて再試行します。"
            else -> null
        }
        store.writableDatabase.execSQL("UPDATE deliveries SET phase=?,detail=?,receipt=?,retryAfter=? WHERE id=? AND attempt=? AND phase='sending'",
            arrayOf<Any?>(outcome.phase,detail,outcome.receipt,if(outcome.phase == "retryWaiting") System.currentTimeMillis()+outcome.seconds*1000 else null,claim.id,claim.attempt))
    }
    fun nextDelay(): Long? {
        if(store.rows("SELECT id FROM deliveries WHERE phase='sending' LIMIT 1").isNotEmpty()) return null
        val now = System.currentTimeMillis()
        return store.rows("SELECT j.provider,j.retryAfter FROM deliveries j JOIN destinations d ON d.id=j.destinationID AND d.enabled=1 AND d.identity=j.targetIdentity WHERE j.phase IN ('queued','retryWaiting')").map { job ->
            val cooldown = store.rows("SELECT until FROM providerCooldown WHERE provider=?",arrayOf(job["provider"] as String)).firstOrNull()?.get("until") as? Long ?: 0
            maxOf(0L,cooldown-now,(job["retryAfter"] as? Long ?: 0)-now)
        }.minOrNull()
    }
}
