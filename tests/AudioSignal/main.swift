import Foundation

var checks = 0
@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    precondition(condition(), label)
}
func pcm(_ values: [Int16]) -> Data {
    var data = Data()
    for v in values {
        let bits = UInt16(bitPattern: v)
        data.append(UInt8(truncatingIfNeeded: bits))
        data.append(UInt8(truncatingIfNeeded: bits >> 8))
    }
    return data
}
func samples(_ wav: Data) -> [Int16] {
    let data = [UInt8](wav.dropFirst(44))
    return stride(from: 0, to: data.count, by: 2).map {
        Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8)
    }
}
let biased = try PCM16WAV.encode(pcm: pcm([1000, 3000, 1000, 3000]), sampleRate: 16000)
let fixed = try AudioSignal.prepare(wav: biased)
expect(fixed.analysis.dc == 2000, "Signed DC mean")
expect(fixed.analysis.acRMS == 1000, "AC RMS excludes DC")
expect(samples(fixed.wav) == [-1000, 1000, -1000, 1000], "Remove bias and preserve variation")
expect(biased != fixed.wav, "Generate derived WAV")
expect(samples(biased) == [1000, 3000, 1000, 3000], "Original data unchanged")
let zero = try AudioSignal.prepare(wav: PCM16WAV.encode(pcm: pcm(Array(repeating: 0, count: 100)), sampleRate: 16000))
expect(zero.analysis.acRMS == 0 && zero.analysis.zeroFraction == 1, "Silence measured")
expect(samples(zero.wav).allSatisfy { $0 == 0 }, "No invented audio or gain")
let dcOnly = try AudioSignal.prepare(wav: PCM16WAV.encode(pcm: pcm(Array(repeating: -1234, count: 100)), sampleRate: 16000))
expect(dcOnly.analysis.dc == -1234 && dcOnly.analysis.acRMS == 0, "Negative constant offset")
expect(samples(dcOnly.wav).allSatisfy { $0 == 0 }, "Remove constant negative offset")
let extremes = try AudioSignal.prepare(wav: PCM16WAV.encode(pcm: pcm([.min, .max]), sampleRate: 16000))
expect(extremes.analysis.peak == 32768 && extremes.analysis.clippingFraction == 1, "Signed endpoints and clipping")
expect(samples(extremes.wav).count == 2, "Clamping does not overflow")
let rate = 9997
let tone = (0..<rate).map { Int16((sin(2 * Double.pi * 440 * Double($0) / Double(rate)) * 10000 + 2000).rounded()) }
let original = try PCM16WAV.encode(pcm: pcm(tone), sampleRate: rate)
let toneFixed = try AudioSignal.prepare(wav: original)
let output = samples(toneFixed.wav)
expect(output.count == 16000, "9997 Hz to 16 kHz preserves one second")
expect(Int(toneFixed.wav[24]) | Int(toneFixed.wav[25]) << 8 == 16000, "Output rate header")
expect(abs(toneFixed.analysis.dc - 2000) < 1, "Tone DC measured")
let crossings = zip(output, output.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
expect(abs(crossings - 440) <= 1, "Resampling preserves pitch")
let outputMean = output.map(Double.init).reduce(0, +) / Double(output.count)
expect(abs(outputMean) < 2, "Resampled output centered")
let single = try AudioSignal.prepare(wav: PCM16WAV.encode(pcm: pcm([1234]), sampleRate: 9997))
expect(samples(single.wav).allSatisfy { $0 == 0 }, "Single-frame boundary")
let down = try AudioSignal.prepare(wav: PCM16WAV.encode(pcm: pcm(Array(repeating: 0, count: 32000)), sampleRate: 32000))
expect(samples(down.wav).count == 16000, "Downsample length")
var malformed = biased
malformed[40] = 0
var stereo = biased
stereo[22] = 2
for invalid in [Data(), Data(biased.prefix(43)), malformed, stereo] {
    do { _ = try AudioSignal.prepare(wav: invalid); fatalError("Malformed WAV accepted") }
    catch { checks += 1 }
}
let wrappedInput = try PCM16WAV.encode(pcm: pcm([-32536, 32000, 32000, 32000]), sampleRate: 16000)
let wrappedOutput = try AudioSignal.prepare(wav: wrappedInput)
let wrappedValues = samples(wrappedOutput.wav)
expect(wrappedValues == [17134, 16134, 16134, 16134], "Bias subtraction uses modular 16-bit conversion before resampling")
expect(wrappedOutput.analysis.wrappedSamples == 1, "Boundary correction count")
expect(abs(Int(wrappedValues[0]) - Int(wrappedValues[1])) == 1000, "No artificial full-scale jump at signed boundary")
expect(samples(wrappedInput) == [-32536, 32000, 32000, 32000], "Boundary correction preserves original")
func rms(_ values: ArraySlice<Int16>) -> Double {
    sqrt(values.map { Double($0) * Double($0) }.reduce(0, +) / Double(values.count))
}
func sineWave(hz: Double, amplitude: Double) throws -> Data {
    let values = (0..<16000).map { i in
        Int16((sin(2 * Double.pi * hz * Double(i) / 16000) * amplitude).rounded())
    }
    return try PCM16WAV.encode(pcm: pcm(values), sampleRate: 16000)
}
let rawMode = try AudioSignal.prepare(wav: original, mode: .original)
expect(rawMode.wav == original, "Original mode preserves all WAV bytes and original sample rate")
let silentEnhanced = try AudioSignal.prepare(wav: zero.wav, mode: .enhanced)
expect(samples(silentEnhanced.wav).allSatisfy { $0 == 0 }, "Enhanced mode does not create sound from silence")
let constantEnhanced = try AudioSignal.prepare(wav: PCM16WAV.encode(pcm: pcm(Array(repeating: 12345, count: 1600)), sampleRate: 16000), mode: .enhanced)
expect(samples(constantEnhanced.wav).allSatisfy { $0 == 0 }, "No filter startup click for constant input")
// Use a strong sub-bass tone so quantization noise does not dominate after 18dB gain.
let lowInput = try sineWave(hz: 20, amplitude: 10000)
let highInput = try sineWave(hz: 500, amplitude: 100)
let lowBase = samples(try AudioSignal.prepare(wav: lowInput).wav)
let highBase = samples(try AudioSignal.prepare(wav: highInput).wav)
let lowEnhanced = samples(try AudioSignal.prepare(wav: lowInput, mode: .enhanced).wav)
let highEnhancedData = try AudioSignal.prepare(wav: highInput, mode: .enhanced).wav
let highEnhanced = samples(highEnhancedData)
expect(rms(lowEnhanced[4000...]) < rms(lowBase[4000...]) * 0.02, "20 Hz strongly attenuated despite gain")
let speechGain = rms(highEnhanced[4000...]) / rms(highBase[4000...])
expect(speechGain > 7.8 && speechGain < 8.1, "500 Hz passes with expected 8x gain")
expect(highEnhanced.count == highBase.count, "Enhancement preserves duration")
let loud = try AudioSignal.prepare(wav: sineWave(hz: 500, amplitude: 20000), mode: .enhanced)
let loudValues = samples(loud.wav)
expect(loudValues.map { abs(Int($0)) }.max()! <= 29491, "Smooth limiter caps output at 90% full scale")
expect(!loudValues.contains(.min) && !loudValues.contains(.max), "No hard digital clipping")
let highAgain = try AudioSignal.prepare(wav: highInput, mode: .enhanced)
expect(highAgain.wav == highEnhancedData, "Filter state resets between recordings")
let enhancedTone = try AudioSignal.prepare(wav: original, mode: .enhanced)
expect(samples(enhancedTone.wav).count == 16000, "9997 Hz source remains one second in enhanced mode")
expect(enhancedTone.analysis.frames == rate, "Diagnostic counts refer to original source")
expect(samples(original) == tone, "Enhancement leaves input samples unchanged")
let silentAdaptive = try AudioSignal.prepare(wav: zero.wav, mode: .adaptive)
expect(samples(silentAdaptive.wav).allSatisfy { $0 == 0 }, "Adaptive silence stays silent")
expect(silentAdaptive.appliedGain == 1, "Silence gain is one")
let dcAdaptive = try AudioSignal.prepare(wav: PCM16WAV.encode(pcm: pcm(Array(repeating: 20000, count: 1600)), sampleRate: 16000), mode: .adaptive)
expect(samples(dcAdaptive.wav).allSatisfy { $0 == 0 }, "Adaptive removes constant DC without inventing sound")
let quietAdaptive = try AudioSignal.prepare(wav: sineWave(hz: 500, amplitude: 50), mode: .adaptive)
expect(quietAdaptive.appliedGain == 1, "Below noise floor is not boosted")
let weakAdaptive = try AudioSignal.prepare(wav: sineWave(hz: 500, amplitude: 150), mode: .adaptive)
expect(weakAdaptive.appliedGain == 17, "Weak audible signal gain is capped at 17")
let speechAdaptive = try AudioSignal.prepare(wav: sineWave(hz: 500, amplitude: 1000), mode: .adaptive)
let speechAdaptiveValues = samples(speechAdaptive.wav)
expect(speechAdaptive.appliedGain! > 9 && speechAdaptive.appliedGain! < 11, "Gain determined from signal level")
expect(rms(speechAdaptiveValues[4000...]) > 6800 && rms(speechAdaptiveValues[4000...]) < 7200, "500 Hz reaches target RMS approximately")
let loudAdaptive = try AudioSignal.prepare(wav: sineWave(hz: 500, amplitude: 20000), mode: .adaptive)
expect(loudAdaptive.appliedGain == 1, "Already loud signal is not attenuated")
let lowAdaptive = try AudioSignal.prepare(wav: sineWave(hz: 5, amplitude: 10000), mode: .adaptive)
expect(rms(samples(lowAdaptive.wav)[8000...]) < 100, "30 Hz high-pass suppresses 5 Hz after startup")
let speechAgain = try AudioSignal.prepare(wav: sineWave(hz: 500, amplitude: 1000), mode: .adaptive)
expect(speechAgain.wav == speechAdaptive.wav, "Adaptive filter resets between recordings")
let convertedAdaptive = try AudioSignal.prepare(wav: original, mode: .adaptive)
expect(samples(convertedAdaptive.wav).count == 16000, "Adaptive rate conversion preserves one-second duration")
expect(samples(original) == tone, "Adaptive preserves raw input bytes")
expect(convertedAdaptive.analysis.frames == rate, "Adaptive diagnostics describe source")
let partialAdaptive = try AudioSignal.prepare(wav: PCM16WAV.encode(pcm: pcm(Array(repeating: 0, count: 321)), sampleRate: 16000), mode: .adaptive)
expect(samples(partialAdaptive.wav).count == 321 && partialAdaptive.appliedGain == 1, "Partial final analysis frame handled")
if CommandLine.arguments.count == 3 {
    let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let expected = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let actual = try AudioSignal.prepare(wav: input, mode: .adaptive)
    expect(actual.wav == expected, "Every byte matches user-confirmed comparison WAV")
    expect(abs(actual.appliedGain! - 6.785971948117099) < 0.0000001, "Gain matches confirmed comparison")
}
print("AudioSignal: \(checks) checks passed")
