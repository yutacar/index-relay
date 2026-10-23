import Foundation

/// Public synthetic boundary values: no captured recording is used.
/// Compile alongside PCM16WAV.swift and AudioSignal.swift to regenerate the Android oracle.
@main
struct FlutterAudioGolden {
    static func main() throws {
        let samples = (0..<640).map { Int16(truncatingIfNeeded: -32760 + ($0 * 377) % 65536) }
        var pcm = Data()
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            pcm.append(UInt8(truncatingIfNeeded: bits))
            pcm.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        let wav = try PCM16WAV.encode(pcm: pcm, sampleRate: 16000)
        let prepared = try AudioSignal.prepare(wav: wav, mode: .adaptive)
        let output: [String: Any] = ["inputPCM": samples.map(Int.init),
            "expectedWAV": prepared.wav.base64EncodedString(), "source": "iOS AudioSignal.adaptive / 0.9.7"]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
    }
}
