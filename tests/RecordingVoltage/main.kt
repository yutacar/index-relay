private var checks = 0
private fun expect(value: Boolean) { checks++; check(value) }
fun main() {
    val values = RecordingVoltage(3)
    expect(values.take(1, 1) == null)
    values.record(1, 3012)
    values.record(2, 2999)
    values.record(6, 2800)
    expect(values.take(1, 2) == 2999) // Latest part of this recording, not another recording.
    expect(values.take(1, 2) == null)
    expect(values.take(3, 5) == null)
    expect(values.take(6, 6) == 2800)
    values.record(65535, 3020)
    values.record(0, 3010)
    values.record(1, 3000)
    expect(values.take(65535, 0) == 3010)
    expect(values.take(1, 1) == 3000)
    values.record(8, 2900)
    values.record(8, null) // A reused index with no voltage must not reuse an old value.
    expect(values.take(8, 8) == null)
    for (invalid in listOf(null, 0, -1, 65535, 65536)) {
        values.record(9, invalid)
        expect(values.take(9, 9) == null)
    }
    values.record(-1, 3000)
    values.record(65536, 3000)
    expect(values.take(0, 65535) == null)
    values.record(1, 3000)
    expect(values.take(-1, 1) == null)
    expect(values.take(1, 65536) == null)
    expect(values.take(1, 1) == 3000)
    for (i in 10..13) values.record(i, 3000 + i)
    expect(values.take(10, 10) == null) // Bounded cache.
    expect(values.take(11, 13) == 3013)
    values.record(10, 3000)
    values.clear()
    expect(values.take(10, 10) == null) // No voltage across receiver sessions.
    values.record(20, 3100)
    values.record(19, 3200) // Callback order is not collection order.
    expect(values.take(19, 20) == 3100)
    values.record(23, 3000)
    values.record(23, 2900)
    expect(values.take(23, 23) == 2900)
    println("RecordingVoltage: $checks checks passed")
}
