import Foundation
import SherpaOnnxC

/// Kokoro 多语言 v1.1（sherpa-onnx v2 词典模式）的本地合成。
/// 加载与合成都是阻塞调用，并且同一时刻只允许一个合成，调用方应放在后台串行队列上
public final class KokoroEngine: @unchecked Sendable {
    /// 编号 0–2 是英文音色，3–57 为中文女声 zf_*，58–102 为中文男声 zm_*（取自模型元数据 speaker2id）
    public static let femaleVoices = 3...57
    public static let maleVoices = 58...102

    public let sampleRate: Int
    public let speakerCount: Int
    private let tts: OpaquePointer
    private let lock = NSLock()

    /// `directory` 内需有 model.onnx（或 model.int8.onnx）、voices.bin、tokens.txt、lexicon-us-en.txt、lexicon-zh.txt，
    /// 以及可选的 date/phone/number-zh.fst（数字、日期、电话的读法）
    public init?(directory: URL, threads: Int = 2, provider: String = "cpu") {
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func c(_ text: String) -> UnsafePointer<CChar>? {
            guard let pointer = strdup(text) else { return nil }
            owned.append(pointer)
            return UnsafePointer(pointer)
        }
        func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

        var config = SherpaOnnxOfflineTtsConfig()
        let full = path("model.onnx")
        config.model.kokoro.model = c(FileManager.default.fileExists(atPath: full) ? full : path("model.int8.onnx"))
        config.model.kokoro.voices = c(path("voices.bin"))
        config.model.kokoro.tokens = c(path("tokens.txt"))
        config.model.kokoro.lexicon = c(path("lexicon-us-en.txt") + "," + path("lexicon-zh.txt"))
        config.model.kokoro.length_scale = 1
        config.model.num_threads = Int32(threads)
        config.model.provider = c(provider)
        let rules = ["date-zh.fst", "phone-zh.fst", "number-zh.fst"]
            .map(path)
            .filter { FileManager.default.fileExists(atPath: $0) }
        if !rules.isEmpty { config.rule_fsts = c(rules.joined(separator: ",")) }
        config.max_num_sentences = 1
        config.silence_scale = 0.2

        guard let created = SherpaOnnxCreateOfflineTts(&config) else { return nil }
        tts = created
        sampleRate = Int(SherpaOnnxOfflineTtsSampleRate(created))
        speakerCount = Int(SherpaOnnxOfflineTtsNumSpeakers(created))
    }

    deinit {
        SherpaOnnxDestroyOfflineTts(tts)
    }

    /// 合成一段文字，返回 16 位单声道 WAV；文字为空或合成失败时为 nil
    public func wav(text: String, speaker: Int, speed: Float) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var generation = SherpaOnnxGenerationConfig()
        generation.sid = Int32(max(0, min(speaker, speakerCount - 1)))
        generation.speed = speed
        generation.silence_scale = 0.2
        guard let audio = trimmed.withCString({ SherpaOnnxOfflineTtsGenerateWithConfig(tts, $0, &generation, nil, nil) }) else {
            return nil
        }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
        let count = Int(audio.pointee.n)
        guard count > 0, let samples = audio.pointee.samples else { return nil }
        return Self.wave(UnsafeBufferPointer(start: samples, count: count), sampleRate: Int(audio.pointee.sample_rate))
    }

    static func wave(_ samples: UnsafeBufferPointer<Float>, sampleRate: Int) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(bytes))
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }
}
