import Foundation
import AVFoundation
import CoreMedia
import Speech

struct Segment: Sendable {
    let speaker: String
    let start: Double
    let end: Double
    let text: String
}

typealias SegmentHandler = @Sendable (Segment) -> Void

/// Transcripción en streaming con SpeechAnalyzer (macOS 26). Todo en el Mac, sin archivos de audio.
final class LiveTranscriber {
    let speaker: String
    private let onSegment: SegmentHandler
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: BufferConverter?
    private var resultsTask: Task<Void, Never>?

    init(speaker: String, onSegment: @escaping SegmentHandler) {
        self.speaker = speaker
        self.onSegment = onSegment
    }

    /// Comprueba el idioma y descarga el modelo del sistema si falta (solo la primera vez).
    static func prepare(locale: Locale) async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let wanted = locale.identifier(.bcp47)
        let match = supported.first { $0.identifier(.bcp47) == wanted }
            ?? supported.first { $0.language.languageCode == locale.language.languageCode }
        guard let match else { throw ActaError.localeNotSupported(wanted) }

        let probe = makeTranscriber(locale: match)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }
        return match
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale,
                          transcriptionOptions: [],
                          reportingOptions: [],
                          attributeOptions: [.audioTimeRange])
    }

    func start(locale: Locale) async throws {
        let transcriber = Self.makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ActaError.noAudioFormat
        }
        converter = BufferConverter(to: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        self.analyzer = analyzer

        let speaker = self.speaker
        let handler = self.onSegment
        resultsTask = Task.detached {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let rawStart = result.range.start.seconds
                    let rawEnd = result.range.end.seconds
                    let start = rawStart.isFinite ? rawStart : 0
                    let end = rawEnd.isFinite ? max(rawEnd, start) : start
                    handler(Segment(speaker: speaker, start: start, end: end, text: text))
                }
            } catch {
                // El flujo termina con error si se cancela; no hay nada que hacer.
            }
        }

        try await analyzer.start(inputSequence: stream)
    }

    /// Llamado desde el hilo de audio. Convierte al formato del modelo y lo encola.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let out = converter?.convert(buffer) else { return }
        continuation?.yield(AnalyzerInput(buffer: out))
    }

    func finish() async {
        continuation?.finish()
        continuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        analyzer = nil
        resultsTask = nil
    }
}

/// Convierte buffers de cualquier formato (48 kHz estéreo, etc.) al que pide el modelo.
/// Siempre devuelve una copia, así que vale para buffers "no copy" del tap.
final class BufferConverter {
    let outFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to format: AVAudioFormat) { outFormat = format }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
            converter?.primeMethod = .none
            converter?.downmix = true
        }
        guard let converter else { return nil }

        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}
