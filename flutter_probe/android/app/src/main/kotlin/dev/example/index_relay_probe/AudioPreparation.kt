package dev.example.index_relay_probe

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.*

/** Bounded PCM16 mono input for received and synthetic audio. Same adaptive-30hz algorithm as iOS. */
object AudioPreparation {
    data class PCM(val samples: ShortArray, val rate: Int)
    const val MAX_SECONDS = 300
    fun parse(wav: ByteArray): ShortArray = decode(wav).also { require(it.rate == 16000) }.samples
    fun decode(wav: ByteArray): PCM {
        require(wav.size in 44..33_554_476)
        val b = ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN)
        fun tag(i: Int) = String(wav, i, 4, Charsets.US_ASCII)
        require(tag(0) == "RIFF" && tag(8) == "WAVE" && b.getInt(4) == wav.size - 8)
        var rate = 0
        var offset = 12; var valid = false; var pcm: ShortArray? = null
        while (offset <= wav.size - 8) {
            val size = b.getInt(offset + 4); require(size >= 0 && size <= wav.size - offset - 8)
            val start = offset + 8
            when (tag(offset)) {
                "fmt " -> { require(size >= 16); valid = b.getShort(start).toInt() == 1 && b.getShort(start + 2).toInt() == 1 && b.getInt(start + 4) in 1000..192000 && b.getInt(start + 8) == b.getInt(start + 4) * 2 && b.getShort(start + 12).toInt() == 2 && b.getShort(start + 14).toInt() == 16; rate = b.getInt(start + 4) }
                "data" -> { require(pcm == null && size in 2..33_554_432 && size % 2 == 0); pcm = ShortArray(size / 2) { b.getShort(start + it * 2) } }
            }
            offset = start + size + (size and 1)
        }
        require(valid); val samples = requireNotNull(pcm)
        require(samples.size.toLong() <= rate.toLong() * MAX_SECONDS)
        return PCM(samples, rate)
    }
    fun encode(pcm: ShortArray, rate: Int = 16000): ByteArray {
        require(rate in 1000..192000 && pcm.isNotEmpty() && pcm.size.toLong() <= rate.toLong() * MAX_SECONDS && pcm.size <= 16 * 1024 * 1024)
        val b = ByteBuffer.allocate(44 + pcm.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray()).putInt(b.capacity() - 8).put("WAVEfmt ".toByteArray())
        b.putInt(16).putShort(1).putShort(1).putInt(rate).putInt(rate * 2).putShort(2).putShort(16)
        b.put("data".toByteArray()).putInt(pcm.size * 2); pcm.forEach { b.putShort(it) }; return b.array()
    }
    fun prepare(wav: ByteArray): ByteArray {
        val input = decode(wav)
        val pcm = input.samples
        val dc = pcm.sumOf { it.toLong() }.toDouble() / pcm.size
        // Swift .rounded() uses ties away from zero, then preserves 16-bit wrap.
        val bias = (if (dc >= 0) floor(dc + 0.5) else ceil(dc - 0.5)).toInt()
        fun rounded(x: Double) = (if (x >= 0) floor(x + 0.5) else ceil(x - 0.5)).toInt().coerceIn(-32768, 32767).toShort()
        val countOut = max(1, floor(pcm.size.toDouble() * 16000 / input.rate + 0.5).toInt())
        val centered = ShortArray(countOut) { i ->
            val position = i.toDouble() * input.rate / 16000
            val left = min(position.toInt(), pcm.lastIndex)
            val right = min(left + 1, pcm.lastIndex)
            val fraction = position - left
            rounded((pcm[left].toInt() - bias).toShort() * (1 - fraction) + (pcm[right].toInt() - bias).toShort() * fraction)
        }
        val first = HighPass(0.541196100146197); val second = HighPass(1.306562964876377)
        fun quantize(x: Double) = x.coerceIn(-32768.0, 32767.0).toInt().toShort()
        val filtered = ShortArray(centered.size) { i -> quantize(second.process(quantize(first.process(centered[i].toDouble())).toDouble())) }
        var squares = 0.0; var count = 0
        for (offset in filtered.indices step 320) {
            val end = min(offset + 320, filtered.size)
            val sum = (offset until end).sumOf { filtered[it].toDouble().pow(2) }
            if (sqrt(sum / (end - offset)) > 100) { squares += sum; count += end - offset }
        }
        val rms = if (count > 0) sqrt(squares / count) else 0.0
        val gain = if (rms > 0) (7000 / rms).coerceIn(1.0, 17.0) else 1.0
        return encode(ShortArray(filtered.size) { quantize(filtered[it] * gain) })
    }
    private class HighPass(q: Double) {
        private val omega = 2 * PI * 30 / 16000
        private val cosine = cos(omega); private val alpha = sin(omega) / (2 * q)
        private val b0 = (1 + cosine) / (2 * (1 + alpha)); private val b1 = -(1 + cosine) / (1 + alpha)
        private val a1 = -2 * cosine / (1 + alpha); private val a2 = (1 - alpha) / (1 + alpha)
        private var z1 = 0.0; private var z2 = 0.0
        fun process(input: Double): Double {
            val value = b0 * input + z1
            z1 = b1 * input - a1 * value + z2; z2 = b0 * input - a2 * value
            return value
        }
    }
}
