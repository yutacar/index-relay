package dev.example.index_relay_probe

import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL

class DeliveryError(val userMessage: String) : Exception() // Never retain URLs, tokens or provider response text.
data class VerifiedTarget(val target: String, val kind: String, val identity: String)
data class DeliveryResponse(val status: Int?, val json: JSONObject?, val notWritten: Boolean = false, val retryHeader: Double? = null)
data class DeliveryOutcome(val phase: String, val detail: String? = null, val receipt: String? = null, val seconds: Long = 0, val pauseProvider: Boolean = false)
interface DeliveryTransport {
    fun exchange(url: String, body: String?): DeliveryResponse
    fun cancel()
}
object DeliveryApi {
    // Set only by the DUMP-protected debug source-set harness, never through Dart or saved settings.
    @Volatile var testTransport: (() -> DeliveryTransport)? = null
    @Volatile var testNetworkRequired = false
    fun transport(): DeliveryTransport = if ((BuildConfig.DEBUG && BuildConfig.PREVIEW)) testTransport?.invoke() ?: StrictDeliveryHttp() else StrictDeliveryHttp()
    fun positive(value: String) = value.toULongOrNull()?.let { it > 0u && it.toString() == value } == true
    fun negative(value: String) = value.toLongOrNull()?.let { it < 0 && it.toString() == value } == true
    fun webhook(secret: String, posting: Boolean = false): String {
        val uri = try { URI(secret.trim()) } catch (_: Exception) { throw DeliveryError("Webhook URLを確認してください。") }
        if (uri.scheme != "https" || uri.host !in listOf("discord.com", "discordapp.com") || uri.rawUserInfo != null || uri.port != -1 || uri.rawQuery != null || uri.rawFragment != null ||
            !Regex("^/api/(?:v[0-9]+/)?webhooks/[0-9]+/[A-Za-z0-9._-]+/?$").matches(uri.rawPath ?: "")) throw DeliveryError("通常のDiscord Webhook URLを入力してください。")
        return "https://discord.com${uri.rawPath.trimEnd('/')}" + if (posting) "?wait=true" else ""
    }
    fun telegram(token: String, method: String): String {
        if (!Regex("^[0-9]+:[A-Za-z0-9_-]+$").matches(token) || method !in listOf("getMe", "getChat", "sendMessage")) throw DeliveryError("Botトークンを確認してください。")
        return "https://api.telegram.org/bot$token/$method"
    }
    private fun checked(response: DeliveryResponse): JSONObject {
        if (response.status !in 200..299) throw DeliveryError("送り先を確認できません。通信・資格情報・権限を確認してください。")
        return response.json ?: throw DeliveryError("送り先情報を確認できませんでした。")
    }
    fun verify(provider: String, secret: String, chat: String, http: DeliveryTransport): VerifiedTarget {
        return when (provider) {
            "discord" -> {
                val data = checked(http.exchange(webhook(secret), null))
                val channel = data.optString("channel_id"); val guild = data.optString("guild_id")
                if (data.optInt("type") != 1 || !positive(channel) || !positive(guild)) throw DeliveryError("Discordの送り先情報を確認できません。")
                VerifiedTarget(channel, "channel", "discord:$guild:$channel")
            }
            "telegram" -> {
                if (!(negative(chat) || Regex("^@[A-Za-z0-9_]{1,64}$").matches(chat))) throw DeliveryError("TelegramのグループIDを確認してください。")
                val me = checked(http.exchange(telegram(secret, "getMe"), null))
                val bot = me.optJSONObject("result"); val botID = bot?.opt("id")?.takeIf { it is Number }?.toString() ?: ""
                if (!me.optBoolean("ok") || bot?.optBoolean("is_bot") != true || !positive(botID)) throw DeliveryError("Bot情報を確認できません。")
                val data = checked(http.exchange(telegram(secret, "getChat"), JSONObject().put("chat_id",chat).toString()))
                val result = data.optJSONObject("result"); val kind = result?.optString("type") ?: ""
                val id = result?.opt("id")?.takeIf { it is Number }?.toString() ?: ""
                if (!data.optBoolean("ok") || kind !in listOf("group","supergroup") || !negative(id)) throw DeliveryError("Telegramはグループ・スーパーグループのみ対応しています。DM・チャンネルは登録できません。")
                VerifiedTarget(id, kind, "telegram:$botID:$id:$kind")
            }
            else -> throw DeliveryError("サービスを確認してください。")
        }
    }
    fun mentions(prefix: String): String {
        val users = linkedSetOf<String>(); val roles = linkedSetOf<String>()
        Regex("<@([!&]?)([0-9]{1,20})>").findAll(prefix).forEach { match ->
            val id = match.groupValues[2]; val target = if (match.groupValues[1] == "&") roles else users
            if (positive(id) && target.size < 100) target.add(id)
        }
        return JSONObject().put("parse",JSONArray()).put("users",JSONArray(users.toList())).put("roles",JSONArray(roles.toList())).toString()
    }
    fun text(prefix: String, transcript: String) = prefix.trim().let { if(it.isEmpty()) transcript else "$it $transcript" }
    fun validText(provider: String, text: String) = text.isNotBlank() && text.length <= if(provider == "discord") 2000 else 4096
    fun payload(provider: String, target: String, text: String, mentions: String): String {
        if (!validText(provider,text)) throw DeliveryError("本文が空か文字数上限を超えています。短く編集してください。")
        return if (provider == "discord") JSONObject().put("content",text).put("allowed_mentions",JSONObject(mentions)).toString()
        else { if(!negative(target)) throw DeliveryError("グループIDを確認してください。")
            JSONObject().put("chat_id",target).put("text",text).put("link_preview_options",JSONObject().put("is_disabled",true)).toString() }
    }
    fun classify(provider: String, response: DeliveryResponse): DeliveryOutcome {
        val status = response.status ?: return if(response.notWritten) DeliveryOutcome("retryWaiting",seconds=30) else DeliveryOutcome("unknown")
        val json = response.json
        // An API response proving rejection is necessary to retry a POST automatically.
        if (status == 429) {
            val raw = listOfNotNull(json?.optDouble("retry_after",Double.NaN), json?.optJSONObject("parameters")?.optDouble("retry_after",Double.NaN), response.retryHeader)
                .filter { it.isFinite() && it >= 0 }.maxOrNull() ?: 30.0
            if(raw > 604800) return DeliveryOutcome("needsAttention","長い待機時間が指定されたため、このサービスの送り先を停止しました。設定を確認してください。",pauseProvider=true)
            return DeliveryOutcome("retryWaiting",seconds=kotlin.math.ceil(raw.coerceAtLeast(1.0)).toLong())
        }
        if (status >= 500) return DeliveryOutcome("unknown")
        if (provider == "telegram" && (status == 400 || status in 200..299) && json?.opt("ok") == false && json.optInt("error_code") == 400) {
            val next = json.optJSONObject("parameters")?.opt("migrate_to_chat_id")?.takeIf { it is Number }?.toString() ?: ""
            if(negative(next)) return DeliveryOutcome("needsAttention","グループが移行しました。新しいID（$next）で送り先を追加し直してください。自動では付け替えません。")
        }
        if (status !in 200..299) return DeliveryOutcome("needsAttention","投稿が拒否されました（HTTP $status）。設定・権限を確認してください。")
        if (provider == "telegram" && json?.opt("ok") == false) return DeliveryOutcome("needsAttention","Telegramが投稿を拒否しました。設定・権限を確認してください。")
        val id = if(provider == "discord") json?.opt("id")?.takeIf { it is String }?.toString()
            else if(json?.opt("ok") == true) json.optJSONObject("result")?.opt("message_id")?.takeIf { it is Number }?.toString() else null
        return if (id != null && positive(id)) DeliveryOutcome("sent",receipt=id) else DeliveryOutcome("unknown")
    }
}

/** Fixed official origins, no redirects, no cookies/cache, no transparent streaming POST retry. */
class StrictDeliveryHttp(private val debugEndpoint: ((String) -> String)? = null) : DeliveryTransport {
    @Volatile private var connection: HttpURLConnection? = null
    @Volatile private var cancelled = false
    override fun cancel() { cancelled = true; connection?.disconnect() }
    override fun exchange(url: String, body: String?): DeliveryResponse {
        var writeStarted = false
        var current: HttpURLConnection? = null
        try {
            if(cancelled) return DeliveryResponse(null,null)
            val mapped = if((BuildConfig.DEBUG && BuildConfig.PREVIEW)) debugEndpoint?.invoke(url) ?: url else url
            if(mapped == url) {
                val uri = URI(url)
                require(uri.scheme == "https" && uri.host in listOf("discord.com","api.telegram.org"))
            }
            current = URL(mapped).openConnection() as HttpURLConnection
            connection = current
            if(cancelled) return DeliveryResponse(null,null)
            current.instanceFollowRedirects = false; current.useCaches = false
            current.connectTimeout = 15_000; current.readTimeout = 15_000
            current.setRequestProperty("Connection","close")
            current.setRequestProperty("Accept","application/json")
            current.requestMethod = if(body == null) "GET" else "POST"
            if(body != null) {
                val bytes = body.toByteArray(Charsets.UTF_8)
                current.doOutput = true; current.setFixedLengthStreamingMode(bytes.size)
                current.setRequestProperty("Content-Type","application/json; charset=utf-8")
                current.connect()
                current.outputStream.use { output -> writeStarted = true; output.write(bytes); output.flush() }
            }
            val status = current.responseCode
            val stream = if(status < 400) current.inputStream else current.errorStream
            val bytes = stream?.use { it.readNBytesBounded(262144) }
            val json = try { bytes?.let { JSONObject(String(it,Charsets.UTF_8)) } } catch (_: Exception) { null }
            val header = current.getHeaderField("Retry-After")
            val delay = header?.toDoubleOrNull() ?: try { header?.let { (java.time.ZonedDateTime.parse(it,java.time.format.DateTimeFormatter.RFC_1123_DATE_TIME).toInstant().toEpochMilli()-System.currentTimeMillis())/1000.0 } } catch (_: Exception) { null }
            return DeliveryResponse(status,json,retryHeader=delay)
        } catch (_: Exception) { return DeliveryResponse(null,null,notWritten = !writeStarted && !cancelled) }
        finally { current?.disconnect(); connection = null }
    }
    private fun java.io.InputStream.readNBytesBounded(limit: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream(); val buffer = ByteArray(4096); val deadline = System.nanoTime()+java.util.concurrent.TimeUnit.SECONDS.toNanos(30)
        while(true) { check(System.nanoTime() < deadline); val n = read(buffer); if(n < 0) return out.toByteArray(); check(out.size()+n <= limit); out.write(buffer,0,n) }
    }
}
