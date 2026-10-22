import Foundation

enum PCM16WAV {
    enum EncodingError: Error { case invalidSampleRate, invalidPCM, tooLarge }

    static func encode(pcm: Data, sampleRate: Int) throws -> Data {
        guard (1_000...192_000).contains(sampleRate) else { throw EncodingError.invalidSampleRate }
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2) else { throw EncodingError.invalidPCM }
        guard pcm.count <= 32 * 1024 * 1024 else { throw EncodingError.tooLarge }
        var result = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        result.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + pcm.count))
        result.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1)) // linear PCM
        append(UInt16(1)) // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        result.append(contentsOf: "data".utf8)
        append(UInt32(pcm.count))
        result.append(pcm)
        return result
    }
}
