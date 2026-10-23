@file:OptIn(kotlin.time.ExperimentalTime::class)
package dev.example.index_relay_probe

import android.content.Context
import coredevices.haversine.*
import com.wtlp.haversinesatellitelibrary.*
import com.wtlp.haversinesatellitelibrary.operations.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

/** Android SDK boundary. Never erases, programs a ring, uploads diagnostics, or supplies firmware URLs. */
class AndroidRingReceiver(private val context: Context, private val config: ReceiverConfig,
    private val engine: RelayEngine, private val status: (String) -> Unit,
    private val transferring: (Boolean) -> Unit, private val saved: suspend (ReceivedAudio) -> Unit) {
    suspend fun run() = coroutineScope {
        val cursor = MutableStateFlow(config.frontier.committed)
        val manager = HaversineProbe.createManager(context, config.address.replace(":", ""),
            object : KMPHaversineDebugDelegate {
                override fun handleHaversineDebugInfo(info: KMPHaversineDebugInfo) {}
                override fun shouldReadRxRSSI(satellite: KMPHaversineSatellite) = false
                override fun handleRxRSSI(rssi: Float, satellite: KMPHaversineSatellite) {}
            }, object : KMPHaversineHacksDelegate {
                override fun shouldWipeCollectionsBeforeTransfer(satellite: KMPHaversineSatellite) = false
                override fun wipedCollectionsBeforeTransfer(satellite: KMPHaversineSatellite) { this@coroutineScope.cancel("Unexpected erase") }
            }, object : CollectionIndexStorage {
                override val lastSuccessfulCollectionIndex: StateFlow<Int?> = cursor
                override fun setLastSuccessfulCollectionIndex(index: Int?) { /* SDK hints are not durable acknowledgements. */ }
            }, this)
        val previous = requireNotNull(manager.environment.transferDelegate)
        manager.environment.transferDelegate = object : HaversineCollectionTransferCallback {
            override fun firstCollectionToTransferInRange(range: TelestoStoredCollectionIndexes, satellite: HaversineSatellite): Int {
                val frontier = engine.receiver.get()?.takeIf { it.session == config.session }?.frontier ?: config.frontier
                engine.observeRange(config.session, range.rangeStart, range.rangeEnd)
                return frontier.firstToTransfer(range.rangeStart, range.rangeEnd)
            }
            override fun willTransferCollectionsInRange(range: TelestoStoredCollectionIndexes, satellite: HaversineSatellite) = previous.willTransferCollectionsInRange(range, satellite)
            override fun collectionTransferDidFinish(data: ByteArray, index: Int, satellite: HaversineSatellite) = previous.collectionTransferDidFinish(data, index, satellite)
            override fun collectionTransferDidFail(error: HaversineException, index: Int, satellite: HaversineSatellite) = previous.collectionTransferDidFail(error, index, satellite)
        }
        try {
            status("Bluetoothの準備を待機しています。")
            manager.awaitBluetoothReady()
            status("リングの録音を待機しています。")
            manager.startScanning().collect { event ->
                when (event) {
                    is SatelliteStatus.Transferring -> when (val transfer = event.transferStatus) {
                        is TransferStatus.TransferStarted -> { transferring(true); engine.event("TRANSFER_STARTED") }
                        is TransferStatus.TransferComplete -> {
                            try {
                                saved(ReceivedAudio(config.session, transfer.samples, transfer.sampleRate.toInt(),
                                    transfer.collectionStartCount.toInt(), transfer.collectionIndex,
                                    transfer.buttonReleaseTimestamp?.toEpochMilliseconds() ?: transfer.transferCompleteTimestamp.toEpochMilliseconds(), transfer.isContiguous))
                                cursor.value = engine.receiver.get()?.frontier?.committed
                                status("録音を保存しました。次の録音を待機しています。")
                            } finally { transferring(false) }
                        }
                        is TransferStatus.TransferFailed -> { transferring(false); engine.event("TRANSFER_FAILED"); status("転送を完了できませんでした。再接続時に再取得します。") }
                        is TransferStatus.IrrecoverableDataDetected -> { transferring(false); engine.event("INVALID_COLLECTION"); status("受信データを確認できません。リングと接続を確認してください。") }
                        else -> Unit
                    }
                    is SatelliteStatus.FirmwareUpdating -> error("Firmware updates disabled")
                    is SatelliteStatus.BluetoothFailure -> { engine.event("BLUETOOTH_FAILURE"); status("Bluetooth接続を待機しています。") }
                    else -> Unit
                }
            }
        } finally { manager.environment.transferDelegate = previous; transferring(false) }
    }
}
