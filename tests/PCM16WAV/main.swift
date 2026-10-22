import Foundation

var checks = 0
@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    precondition(condition(), label)
}
let pcm = Data([0x00, 0x80, 0xff, 0xff, 0x00, 0x00, 0xff, 0x7f])
let wav = try PCM16WAV.encode(pcm: pcm, sampleRate: 16000)
func word(_ offset: Int, _ size: Int) -> UInt32 {
    (0..<size).reduce(0) { $0 | UInt32(wav[offset + $1]) << (8 * $1) }
}
expect(wav.count == 52, "44 byte header plus PCM")
expect(String(data: wav[0..<4], encoding: .ascii) == "RIFF", "RIFF marker")
expect(String(data: wav[8..<16], encoding: .ascii) == "WAVEfmt ", "WAVE and fmt")
expect(word(4, 4) == 44, "RIFF length")
expect(word(20, 2) == 1 && word(22, 2) == 1, "Linear mono PCM")
expect(word(24, 4) == 16000 && word(28, 4) == 32000, "Sample and byte rates")
expect(word(32, 2) == 2 && word(34, 2) == 16, "Alignment and depth")
expect(word(40, 4) == 8 && Data(wav[44...]) == pcm, "PCM preserved exactly")
for (data, rate) in [(Data(), 16000), (Data([0]), 16000), (pcm, 0), (pcm, 192001)] {
    do {
        _ = try PCM16WAV.encode(pcm: data, sampleRate: rate)
        fatalError("Invalid PCM accepted")
    } catch { checks += 1 }
}
print("PCM16WAV: \(checks) checks passed")
