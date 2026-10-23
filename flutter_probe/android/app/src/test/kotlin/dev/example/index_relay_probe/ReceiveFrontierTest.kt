package dev.example.index_relay_probe
import org.junit.Assert.*
import org.junit.Test

class ReceiveFrontierTest {
    @Test fun rolloverAndMissingCollection() {
        var position = ReceiveFrontier().observed(65534, 1).saved(65534, 65534)
        assertEquals(65535, position.next)
        position = position.saved(0, 1)
        assertEquals(65535, position.next)
        assertEquals(setOf(0,1), position.pending)
        position = position.saved(65535, 65535)
        assertEquals(2, position.next); assertEquals(1, position.committed)
        assertTrue(position.pending.isEmpty())
        assertEquals(position, position.saved(65534, 1))
        assertEquals(position, ReceiveFrontier.decode(position.encode()))
    }
    @Test fun rangeSkipAndReset() {
        val done = ReceiveFrontier(0,65535)
        assertEquals(65536, done.firstToTransfer(65530,65535))
        assertEquals(done, done.observed(65530,65535))
        assertEquals(100, done.observed(100,200).next)
        assertEquals(0, done.firstToTransfer(65530,2))
    }
    @Test fun invalidDataCannotAdvance() {
        val original = ReceiveFrontier(12,11)
        for (pair in listOf(-1 to 3, 2 to 65536, 1 to 9000)) {
            try { original.saved(pair.first,pair.second); fail("Invalid range accepted") } catch (_: IllegalArgumentException) {}
            assertEquals(12, original.next)
        }
        try { ReceiveFrontier.decode("1|0|70000"); fail("Corruption accepted") } catch (_: IllegalArgumentException) {}
    }
    @Test fun resampleKeepsDurationAndOriginal() {
        val samples = ShortArray(19994) { ((it % 100) * 100 - 5000).toShort() }
        val source = AudioPreparation.encode(samples,9997); val untouched = source.copyOf()
        val output = AudioPreparation.decode(AudioPreparation.prepare(source))
        assertEquals(16000, output.rate); assertEquals(32000, output.samples.size)
        assertArrayEquals(untouched,source)
    }
    @Test fun longerAudioAndBounds() {
        val samples = ShortArray(16000 * 61)
        assertEquals(samples.size, AudioPreparation.parse(AudioPreparation.encode(samples)).size)
        try { AudioPreparation.encode(ShortArray(16000 * 301)); fail("Oversize accepted") } catch (_: IllegalArgumentException) {}
    }
}
