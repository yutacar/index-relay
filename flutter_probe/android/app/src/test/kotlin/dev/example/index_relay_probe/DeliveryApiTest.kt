package dev.example.index_relay_probe

import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject

class DeliveryApiTest {
    private val webhook = "https://discord.com/api/webhooks/123/test-token"
    @Test fun strictOriginsAndPaths() {
        assertEquals("$webhook?wait=true",DeliveryApi.webhook(webhook,true))
        for(url in listOf("http://discord.com/api/webhooks/1/x", "$webhook?thread_id=2", "$webhook#x", "https://discord.com:443/api/webhooks/1/x", "https://discord.com.evil.invalid/api/webhooks/1/x", "https://u@discord.com/api/webhooks/1/x", "https://discord.com/api/webhooks/1/%2Fx")) {
            try { DeliveryApi.webhook(url); fail("Unsafe URL accepted") } catch (_: DeliveryError) {}
        }
        try { DeliveryApi.telegram("1:test/attack","sendMessage"); fail() } catch (_: DeliveryError) {}
    }
    @Test fun prefixAndMentionPolicyIsExplicit() {
        assertEquals("メモ 文",DeliveryApi.text(" メモ ","文"))
        assertEquals("文",DeliveryApi.text(" ","文"))
        val policy = JSONObject(DeliveryApi.mentions("<@123> <@!123> <@&456> @everyone @here <@0> <@01>"))
        assertEquals(0,policy.getJSONArray("parse").length()); assertEquals(1,policy.getJSONArray("users").length())
        assertEquals("123",policy.getJSONArray("users").getString(0)); assertEquals("456",policy.getJSONArray("roles").getString(0))
        val payload = JSONObject(DeliveryApi.payload("discord","1","<@999> @everyone",policy.toString()))
        assertFalse(payload.getJSONObject("allowed_mentions").getJSONArray("users").toString().contains("999"))
        val telegram = JSONObject(DeliveryApi.payload("telegram","-1","*x* <tag>","{}"))
        assertFalse(telegram.has("parse_mode")); assertTrue(telegram.getJSONObject("link_preview_options").getBoolean("is_disabled"))
    }
    @Test fun textBoundsAreConservativeUTF16() {
        assertTrue(DeliveryApi.validText("discord","a".repeat(2000)))
        assertFalse(DeliveryApi.validText("discord","a".repeat(2001)))
        assertFalse(DeliveryApi.validText("telegram","a".repeat(4097)))
        assertFalse(DeliveryApi.validText("telegram"," "))
        assertFalse(DeliveryApi.validText("discord","😀".repeat(1001)))
    }
    @Test fun definiteVsAmbiguousOutcomes() {
        fun classify(code: Int?,body: String="{}",notWritten: Boolean=false) = DeliveryApi.classify("discord",DeliveryResponse(code,JSONObject(body),notWritten))
        assertEquals("retryWaiting",classify(null,notWritten=true).phase)
        assertEquals("unknown",classify(null).phase)
        assertEquals("unknown",classify(500).phase)
        assertEquals("unknown",classify(200).phase)
        assertEquals("unknown",classify(204).phase)
        assertEquals("needsAttention",classify(401).phase)
        assertEquals("needsAttention",classify(302).phase)
        assertEquals("123",classify(200,"{\"id\":\"123\"}").receipt)
        assertEquals(3L,classify(429,"{\"retry_after\":2.1}").seconds)
        assertTrue(classify(429,"{\"retry_after\":1e30}").pauseProvider)
        assertEquals(4L,DeliveryApi.classify("telegram",DeliveryResponse(429,JSONObject("{\"parameters\":{\"retry_after\":4}}"))).seconds)
        assertEquals(60L,DeliveryApi.classify("discord",DeliveryResponse(429,JSONObject("{\"retry_after\":4}"),retryHeader=60.0)).seconds)
        val migration=DeliveryApi.classify("telegram",DeliveryResponse(400,JSONObject("{\"ok\":false,\"error_code\":400,\"parameters\":{\"migrate_to_chat_id\":-100123}}")))
        assertEquals("needsAttention",migration.phase); assertTrue(migration.detail!!.contains("-100123"))
        assertEquals("unknown",DeliveryApi.classify("telegram",DeliveryResponse(500,JSONObject("{\"ok\":false,\"error_code\":400,\"parameters\":{\"migrate_to_chat_id\":-100123}}"))).phase)
    }
    @Test fun telegramVerificationRejectsPrivateAndChannel() {
        for(kind in listOf("private","channel")) {
            val http = object:DeliveryTransport {
                override fun cancel() {}
                override fun exchange(url:String,body:String?) = DeliveryResponse(200,JSONObject(if(url.endsWith("getMe")) "{\"ok\":true,\"result\":{\"id\":5,\"is_bot\":true}}" else "{\"ok\":true,\"result\":{\"id\":-1,\"type\":\"$kind\"}}"))
            }
            try { DeliveryApi.verify("telegram","1:test","-1",http); fail("Unsupported chat accepted") } catch (_:DeliveryError) {}
        }
    }
}
