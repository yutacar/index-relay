@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, kotlinx.cinterop.BetaInteropApi::class, kotlin.time.ExperimentalTime::class)

import coredevices.haversine.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.cinterop.*
import platform.Foundation.*
import platform.darwin.NSObject
import HaversineSatelliteLibrary.*
import coredevices.haversine.ppcommon.PPCollection

class RingReceiver(
    private val ringId: String,
    private val onEvent: (String) -> Unit,
    private val onRaw: (NSData, Int) -> Unit,
    private val onAudio: (NSData, NSData?, Int, Int, String, Boolean) -> Unit
) {
    private val receptionEnabled = MutableStateFlow(true)
    private var scanInstalled = false
    private var continuousMode = false
    private val durableCursor = MutableStateFlow<Int?>(null)

    @Throws(Exception::class)
    fun enableContinuousMode() { check(scope == null); continuousMode = true }

    @Throws(Exception::class)
    fun setDurableCursor(index: Int) {
        require(index in -1..65535)
        durableCursor.value = if (index < 0) null else index
    }

    private val captureLock = NSRecursiveLock()
    private val captured = linkedMapOf<Int, ByteArray>()
    private var capturedBytes = 0
    private var captureProxy: CaptureTransferDelegate? = null
    private var originalDelegate: HaversineCollectionTransferDelegateProtocol? = null
    private var scope: CoroutineScope? = null
    private var manager: KMPHaversineSatelliteManager? = null
    private var lastFirmware: String? = null
    private var cursorNotified = false
    private var ringDetected = false

    @Throws(Exception::class)
    fun start() {
        if (scope != null) return
        receptionEnabled.value = true
        scanInstalled = false
        onEvent("受信ブリッジ: pause-resume-v1")
        withCaptureLock { captured.clear(); capturedBytes = 0 }
        cursorNotified = false
        ringDetected = false
        lastFirmware = null
        co.touchlab.kermit.Logger.setLogWriters()
        // Supervisor children can fail outside the collector's try/catch. On Native,
        // an unhandled launch exception otherwise terminates the entire application.
        val errors = CoroutineExceptionHandler { _, error ->
            if (error !is CancellationException) {
                onEvent("受信子タスクの例外: ${receiverFailureCategory(error)}")
                scope?.cancel()
                onEvent("受信失敗")
            }
        }
        val runScope = CoroutineScope(SupervisorJob() + Dispatchers.Main + errors)
        scope = runScope
        val storage = object : CollectionIndexStorage {
            override val lastSuccessfulCollectionIndex = durableCursor
            override fun setLastSuccessfulCollectionIndex(index: Int?) {
                // The app owns the cursor: it advances only via setDurableCursor after audio is durably saved.
                if (!cursorNotified) {
                    cursorNotified = true
                    onEvent("受信位置通知あり（アプリ側の保存完了まで受信位置は確定しない。以後の同種通知は省略）")
                }
            }
        }
        val debug = object : KMPHaversineDebugDelegate {
            override fun shouldReadRxRSSI(satellite: KMPHaversineSatellite) = false
            override fun handleHaversineDebugInfo(info: KMPHaversineDebugInfo) {}
            override fun handleRxRSSI(rssi: Float, satellite: KMPHaversineSatellite) {}
        }
        val hacks = object : KMPHaversineHacksDelegate {
            override fun shouldWipeCollectionsBeforeTransfer(satellite: KMPHaversineSatellite) = false
            override fun wipedCollectionsBeforeTransfer(satellite: KMPHaversineSatellite) {
                onEvent("警告: 消去通知を受信しました。試験を停止してください。")
                stop()
            }
        }
        runScope.launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                onEvent("Haversineマネージャーを生成します。")
                val receiver = KMPHaversineSatelliteManager(
            pairedSatelliteIdProvider = { if (receptionEnabled.value) ringId else null }, debugDelegate = debug, hacksDelegate = hacks,
            collectionIndexStorage = storage, hwVersion = Pair(11, 0), scope = runScope,
            updateJsonProvider = { null }
        )
                manager = receiver
                val environment = receiver.wrap.environment()
                val delegate = environment.transferDelegate()
                    ?: throw IllegalStateException("Missing transfer delegate")
                originalDelegate = delegate
                val proxy = CaptureTransferDelegate(delegate, inspectRange = { range ->
                    if (continuousMode && receptionEnabled.value) range.useContents {
                        val first = rangeStart.toInt()
                        val last = rangeEnd.toInt()
                        val saved = durableCursor.value
                        val inRange = saved != null &&
                            (if (first <= last) saved in first..last else saved >= first || saved <= last)
                        if (saved == null) onEvent("自動受信範囲初期化:$first")
                        else if (!inRange) {
                            durableCursor.value = null
                            onEvent("自動受信範囲再設定:$first")
                        }
                    }
                }) { data, index ->
                    if (!continuousMode) {
                    // This is the complete native collection payload, before PPCollection decoding.
                    withCaptureLock {
                    if (data.length <= 8uL * 1024uL * 1024uL &&
                        capturedBytes.toULong() + data.length <= 8uL * 1024uL * 1024uL) {
                        val copy = data.toByteArrayCopy()
                        captured[index]?.let { capturedBytes -= it.size }
                        captured[index] = copy
                        capturedBytes += copy.size
                        onRaw(copy.toNSDataCopy(), index)
                    } else {
                        onEvent("比較用圧縮データの上限に達しました（受信は継続）")
                    }
                    }
                }
                    }
                captureProxy = proxy // environment delegate ownership must not control its lifetime.
                environment.setTransferDelegate(proxy)
                runScope.launch {
                    receiver.lastRing.collectLatest { satellite ->
                        if (satellite != null) {
                            if (!ringDetected) {
                                ringDetected = true
                                onEvent("選択したリングを検出")
                            }
                            satellite.state.collect { state ->
                                if (state != null && lastFirmware != state.firmwareVersion) {
                                    lastFirmware = state.firmwareVersion
                                    onEvent("ファームウェア情報を取得")
                                }
                            }
                        }
                    }
                }
                onEvent("受信ライブラリを起動（更新情報なし・初回消去を拒否）")
                onEvent("Bluetoothの準備を待機します。")
                receiver.awaitBluetoothReady()
                receptionEnabled.first { it }
                scanInstalled = true
                onEvent("Bluetooth準備完了。スキャンを開始します。")
                receiver.startScanning().collect { event ->
                    // Keep the SDK listener alive across user toggles, but never deliver
                    // audio or progress while paused. The durable cursor cannot advance.
                    if (!receptionEnabled.value) return@collect
                    when (event) {
                        is SatelliteStatus.Transferring -> {
                            val transfer = event.transferStatus
                            val state = transfer.satellite.state.value
                            if (state != null && lastFirmware != state.firmwareVersion) {
                                lastFirmware = state.firmwareVersion
                                onEvent("ファームウェア情報を取得")
                            }
                            when (transfer) {
                                is TransferStatus.TransferComplete -> {
                                    val samples = transfer.samples
                                    onEvent("音声変換開始: Collection ${transfer.collectionIndex} / ${samples.size}サンプル")
                                    if (samples.size > 16 * 1024 * 1024) {
                                        onEvent("転送失敗: 音声が診断版の上限を超えています")
                                        return@collect
                                    }
                                    var replayStatus = "missing_raw"
                                    var replay: ShortArray? = null
                                    try {
                                        if (!continuousMode) {
                                        val start = transfer.collectionStartCount.toInt()
                                        val end = transfer.collectionIndex
                                        // Captured collections are ordered by the native callback, not sorted by index.
                                        val parts = withCaptureLock {
                                            captured.entries.filter { (index, _) ->
                                                if (start <= end) index in start..end else index >= start || index <= end
                                            }.map { it.key to it.value }
                                        }
                                        val distance = ((end - start) and 65535) + 1
                                        if (parts.size == distance) {
                                            val assembly = MultipartCollection(start)
                                            for ((index, raw) in parts) {
                                                val part = PPCollection(index, raw)
                                                val timeline = part.audioTimeline
                                                if (timeline != null) assembly.addPart(index, part.buttonPressSequence, part.unixTime, timeline)
                                            }
                                            replay = assembly.flushBuffer()
                                            replayStatus = if (replay.contentEquals(samples)) "equal" else "different"
                                        }
                                        } else { replayStatus = "disabled_continuous" }
                                    } catch (e: Exception) {
                                        replayStatus = "error_${receiverFailureCategory(e)}"
                                    }
                                    val replayData = replay?.toPCMData()
                                    val bytes = ByteArray(samples.size * 2)
                                    for (i in samples.indices) {
                                        val value = samples[i].toInt()
                                        bytes[2 * i] = value.toByte()
                                        bytes[2 * i + 1] = (value shr 8).toByte()
                                    }
                                    if (bytes.isNotEmpty()) bytes.usePinned {
                                        onAudio(NSData.create(bytes = it.addressOf(0), length = bytes.size.toULong()), replayData,
                                            transfer.sampleRate.toInt(), transfer.collectionIndex,
                                            "{\"nativePCMHash\":\"${fnv64(bytes)}\",\"replayStatus\":\"$replayStatus\",\"start\":${transfer.collectionStartCount}," +
                                                "\"releasedMs\":${transfer.buttonReleaseTimestamp?.toEpochMilliseconds() ?: "null"}," +
                                                "\"completedMs\":${transfer.transferCompleteTimestamp.toEpochMilliseconds()}," +
                                                "\"buttonSequencePresent\":${transfer.buttonSequence != null}}",
                                            transfer.isContiguous)
                                    }
                                }
                                is TransferStatus.TransferFailed -> {
                                    val error = transfer.exception
                                    val native = error as? KMPHaversineException
                                    val domain = receiverFailureDomain(native?.domain)
                                    onEvent("転送失敗: Collection ${transfer.collectionIndex} / " +
                                        "${receiverFailureCategory(error)} / " +
                                        "$domain / code ${native?.code ?: "未取得"}")
                                }
                                is TransferStatus.IrrecoverableDataDetected -> onEvent(
                                    "転送失敗: 復号不能データ / ${receiverFailureCategory(transfer.exception)}")
                                is TransferStatus.TransferStarted -> onEvent("録音転送開始: Collection ${transfer.willTransferRange.first}..${transfer.willTransferRange.last} / rollover ${transfer.rollover}")
                                else -> Unit
                            }
                        }
                        is SatelliteStatus.FirmwareUpdating -> {
                            onEvent("警告: 想定外の更新イベント。停止します。")
                            stop()
                        }
                        is SatelliteStatus.BluetoothFailure -> onEvent(receiverBluetoothFailure())
                        else -> Unit
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                onEvent("受信処理エラー: ${receiverFailureCategory(e)}")
                stop()
            }
        }
    }

    // User OFF pauses discovery and denies new transfers without constructing a second
    // native central manager on ON. Full stop remains for disposal/ring changes/errors.
    @Throws(Exception::class)
    fun pause() {
        if (scope == null || !receptionEnabled.value) return
        receptionEnabled.value = false
        manager?.wrap?.stopScanning()
        onEvent("自動受信を一時停止しました（マネージャー保持）")
    }

    @Throws(Exception::class)
    fun resume() {
        if (scope == null) { start(); return }
        if (receptionEnabled.value) return
        receptionEnabled.value = true
        onEvent("同じ受信マネージャーで再開します")
        if (scanInstalled) {
            manager?.wrap?.scanForSatellitesWithCompletionHandler { error ->
                if (receptionEnabled.value) {
                    if (error == null) onEvent("Bluetooth準備完了。スキャンを開始します。")
                    else onEvent("Bluetooth接続失敗: スキャン再開エラー")
                }
            }
        } else {
            onEvent("Bluetoothの準備を待機します。")
        }
    }

    private inline fun <T> withCaptureLock(action: () -> T): T {
        captureLock.lock()
        try { return action() } finally { captureLock.unlock() }
    }

    @Throws(Exception::class)
    fun stop() {
        val oldScope = scope
        val oldManager = manager
        if (oldScope == null && oldManager == null) return
        // Reentrant/late callbacks must not treat this session as running.
        receptionEnabled.value = false
        scanInstalled = false
        scope = null
        manager = null
        val environment = oldManager?.wrap?.environment()
        val complete = runReceiverShutdown(
            // A cancelled coroutine's cleanup is not a reliable way to stop native BLE.
            { oldManager?.wrap?.stopScanning(); Unit },
            { oldScope?.cancel(); Unit },
            // This environment belongs to this receiver. Restoring the original transfer
            // delegate retains callbacks into the old KMP manager across a restart.
            { environment?.setTransferDelegate(null); Unit },
            { environment?.setPermissionsDelegate(null); Unit },
            { environment?.setDebugDelegate(null); Unit },
            { environment?.setUpdateDelegate(null); Unit },
            { environment?.setHacksDelegate(null); Unit },
            {
                captureProxy = null
                originalDelegate = null
                withCaptureLock { captured.clear(); capturedBytes = 0 }
            }
        )
        if (!complete) onEvent("受信停止時の後片付けに失敗しました")
        onEvent("受信停止")
    }
}


private fun NSData.toByteArrayCopy(): ByteArray {
    if (length == 0uL) return ByteArray(0)
    return bytes!!.reinterpret<ByteVar>().readBytes(length.toInt())
}
private fun ByteArray.toNSDataCopy(): NSData = if (isEmpty()) NSData() else usePinned {
    NSData.create(bytes = it.addressOf(0), length = size.toULong())
}
private fun ShortArray.toPCMData(): NSData {
    val bytes = ByteArray(size * 2)
    for (i in indices) {
        bytes[2 * i] = this[i].toByte()
        bytes[2 * i + 1] = (this[i].toInt() shr 8).toByte()
    }
    return bytes.toNSDataCopy()
}
private fun fnv64(bytes: ByteArray): String {
    var hash = 14695981039346656037uL
    for (byte in bytes) hash = (hash xor byte.toUByte().toULong()) * 1099511628211uL
    return hash.toString(16).padStart(16, '0')
}

// Forward every protocol operation unchanged. No additional BLE commands are issued.
private class CaptureTransferDelegate(
    private val downstream: HaversineCollectionTransferDelegateProtocol,
    private val inspectRange: (CValue<TelestoStoredCollectionIndexes>) -> Unit = {},
    private val capture: (NSData, Int) -> Unit
) : NSObject(), HaversineCollectionTransferDelegateProtocol {
    override fun firstCollectionToTransferIn(range: CValue<TelestoStoredCollectionIndexes>, `for`: NSUUID): UShort {
        inspectRange(range)
        return downstream.firstCollectionToTransferIn(range, `for`)
    }
    override fun willTransferCollectionsIn(range: CValue<TelestoStoredCollectionIndexes>, `for`: NSUUID) =
        downstream.willTransferCollectionsIn(range, `for`)
    override fun collectionTransferDidFinishWith(data: NSData, collectionIndex: UShort, satelliteId: NSUUID) {
        try { capture(data, collectionIndex.toInt()) } finally {
            downstream.collectionTransferDidFinishWith(data, collectionIndex, satelliteId)
        }
    }
    override fun collectionTransferDidFailWith(error: HaversineSwiftError, collectionIndex: UShort, satelliteId: NSUUID) =
        downstream.collectionTransferDidFailWith(error, collectionIndex, satelliteId)
}
