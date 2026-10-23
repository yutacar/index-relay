package dev.example.index_relay_probe

import android.content.Context
import coredevices.haversine.*
import kotlinx.coroutines.CoroutineScope

/** Shared factory for the real Android adapter; the capability query itself does not scan. */
object HaversineProbe {
    fun capabilities(): Map<String, Any> = mapOf(
        "platform" to "android", "haversineVersion" to "2541a33",
        "managerClass" to KMPHaversineSatelliteManager::class.java.name,
        "bleVerified" to false, "engine" to "whisper.cpp 1.9.5 / CPU / ja"
    )
    // Firmware URLs, pre-transfer erasure and diagnostic uploads are disabled by the caller.
    fun createManager(context: Context, ringID: String, debug: KMPHaversineDebugDelegate,
        hacks: KMPHaversineHacksDelegate, storage: CollectionIndexStorage, scope: CoroutineScope
    ) = KMPHaversineSatelliteManager(
        pairedSatelliteIdProvider = { ringID }, debugDelegate = debug, hacksDelegate = hacks,
        collectionIndexStorage = storage, context = context.applicationContext,
        hwVersion = Pair(11, 0), scope = scope, updateJsonProvider = { null },
        useScanReceiver = false, scanByPairedAddress = false
    )
}
