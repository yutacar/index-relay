fun main() {
    var checks = 0
    fun verify(value: Boolean) { check(value); checks++ }
    // Native scan stop, scope cancellation, five delegate releases, buffer release.
    val expected = (0 until 8).toList()
    for (failed in -1 until 8) {
        val calls = mutableListOf<Int>()
        var referencesReleased = false
        val stages = expected.map { index ->
            {
                calls.add(index)
                if (index == 7) referencesReleased = true
                if (index == failed) throw IllegalStateException("do not expose native details")
            }
        }
        verify(runReceiverShutdown(*stages.toTypedArray()) == (failed == -1))
        verify(calls == expected)
        verify(referencesReleased)
    }
    verify(runReceiverShutdown())
    println("ReceiverShutdown: $checks checks passed")
}
