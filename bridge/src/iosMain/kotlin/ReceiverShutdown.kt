// Each stage must run even when a native stop or cancellation callback fails.
// Never return or log external exception messages from cleanup.
internal fun runReceiverShutdown(vararg stages: () -> Unit): Boolean {
    var complete = true
    for (stage in stages) {
        try { stage() }
        catch (_: Exception) { complete = false }
    }
    return complete
}
