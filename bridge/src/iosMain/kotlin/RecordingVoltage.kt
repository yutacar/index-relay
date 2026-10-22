// Recording metadata only: never reuse another recording's voltage.
internal class RecordingVoltage(private val capacity: Int = 1024) {
    init { require(capacity > 0) }
    private val values = linkedMapOf<Int, Int>()

    fun record(index: Int, millivolts: Int?) {
        if (index !in 0..65535) return
        values.remove(index)
        if (millivolts == null || millivolts !in 1..65534) return
        values[index] = millivolts
        while (values.size > capacity) values.remove(values.keys.first())
    }

    fun take(start: Int, end: Int): Int? {
        if (start !in 0..65535 || end !in 0..65535) return null
        val distance = (end - start) and 65535
        val matching = values.keys.filter { ((it - start) and 65535) <= distance }
        val latest = matching.maxByOrNull { (it - start) and 65535 }
        val result = latest?.let { values[it] }
        matching.forEach { values.remove(it) }
        return result
    }

    fun clear() { values.clear() }
}
