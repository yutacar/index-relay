private fun checkSame(actual: String, expected: String) { check(actual == expected) }
fun main() {
    // A toString that would leak or throw must never be invoked.
    val explosive = object { override fun toString(): String = error("SECRET_SHOULD_NEVER_BE_EVALUATED") }
    val values = listOf(null, "Test-Person iPhone", "token_SAMPLE_SECRET_VALUE", "日本語端末", "12345678-1234-1234-1234-123456789abc", explosive)
    for (value in values) checkSame(receiverBluetoothFailure(value), "Bluetooth接続失敗: bluetooth_failure")
    checkSame(receiverFailureCategory(null), "none")
    checkSame(receiverFailureCategory(IllegalArgumentException("SECRET")), "invalid_argument")
    checkSame(receiverFailureCategory(IllegalStateException("SECRET")), "invalid_state")
    checkSame(receiverFailureCategory(Exception("Test-Person iPhone")), "other")
    val custom = object : Exception("SECRET") { override fun toString(): String = error("NEVER") }
    checkSame(receiverFailureCategory(custom), "other")
    for (domain in listOf("CBErrorDomain", "CBATTErrorDomain", "NSURLErrorDomain", "NSCocoaErrorDomain"))
        checkSame(receiverFailureDomain(domain), domain)
    for (domain in listOf(null, "Person-iPhone", "token_SAMPLE_SECRET_VALUE", "CBErrorDomain_SECRET", "日本語"))
        checkSame(receiverFailureDomain(domain), "other")
    println("ReceiverDiagnostics: 20 checks passed")
}
