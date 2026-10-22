// Never stringify external reasons, exception messages, names or unknown error domains.
// These values reach app diagnostics, shared reports and (in Debug only) the console.
internal fun receiverBluetoothFailure(@Suppress("UNUSED_PARAMETER") reason: Any? = null): String =
    "Bluetooth接続失敗: bluetooth_failure"

internal fun receiverFailureCategory(error: Throwable?): String = when (error) {
    null -> "none"
    is IllegalArgumentException -> "invalid_argument"
    is IllegalStateException -> "invalid_state"
    else -> "other"
}

internal fun receiverFailureDomain(domain: String?): String = when (domain) {
    "CBErrorDomain" -> "CBErrorDomain"
    "CBATTErrorDomain" -> "CBATTErrorDomain"
    "NSURLErrorDomain" -> "NSURLErrorDomain"
    "NSCocoaErrorDomain" -> "NSCocoaErrorDomain"
    else -> "other"
}
