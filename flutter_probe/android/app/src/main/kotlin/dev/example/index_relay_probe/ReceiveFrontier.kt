package dev.example.index_relay_probe

/** 16-bit ring collection frontier. Non-audio gaps are intentionally NOT acknowledged. */
data class ReceiveFrontier(val next: Int? = null, val committed: Int? = null, val pending: Set<Int> = emptySet()) {
    init { require(listOfNotNull(next, committed).all { it in 0..65535 }); require(pending.size <= 8192 && pending.all { it in 0..65535 }) }
    fun saved(start: Int, end: Int): ReceiveFrontier {
        require(start in 0..65535 && end in 0..65535)
        val count = ((end - start) and 65535) + 1; require(count <= 8192)
        var position = next ?: start; var last = committed
        val waiting = pending.toMutableSet()
        repeat(count) { offset -> val index = (start + offset) and 65535; if (((index - position) and 65535) < 32768) waiting.add(index) }
        require(waiting.size <= 8192)
        while (waiting.remove(position)) { last = position; position = (position + 1) and 65535 }
        return ReceiveFrontier(position, last, waiting)
    }
    fun contains(first: Int, last: Int, value: Int) = if (first <= last) value in first..last else value >= first || value <= last
    fun observed(first: Int, last: Int): ReceiveFrontier {
        require(first in 0..65535 && last in 0..65535)
        return if (committed == last || (next != null && contains(first, last, next))) this else ReceiveFrontier(first)
    }
    fun firstToTransfer(first: Int, last: Int): Int = if (committed == last) last + 1 else observed(first, last).next ?: first
    // Compact fixed numeric format. No device IDs or payloads.
    fun encode() = "${next ?: -1}|${committed ?: -1}|${pending.sorted().joinToString(",")}"
    companion object {
        fun decode(value: String): ReceiveFrontier {
            val fields = value.split('|'); require(fields.size == 3)
            return ReceiveFrontier(fields[0].toInt().takeIf { it >= 0 }, fields[1].toInt().takeIf { it >= 0 },
                fields[2].takeIf { it.isNotEmpty() }?.split(',')?.map { it.toInt() }?.toSet() ?: emptySet())
        }
    }
}
data class ReceiverConfig(val address: String, val simulation: Boolean, val enabled: Boolean, val session: String, val frontier: ReceiveFrontier)
data class ReceivedAudio(val session: String, val samples: ShortArray, val rate: Int, val start: Int, val end: Int,
    val recordedAt: Long, val contiguous: Boolean)
