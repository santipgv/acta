import Foundation
import AVFoundation
import AppKit

@MainActor
final class Recorder: ObservableObject {
    enum State: Equatable {
        case idle, preparing, recording, summarizing
        case error(String)
    }

    @Published var state: State = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var lastFile: URL?
    @Published var lastLine = ""
    @Published var title = ""

    private var engine: AVAudioEngine?
    private var tap: SystemAudioTap?
    private var mic: LiveTranscriber?
    private var sys: LiveTranscriber?
    private var writer: MarkdownWriter?
    private var startDate = Date()
    private var timer: Timer?

    var elapsedString: String {
        let s = Int(elapsed)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    func toggle() {
        switch state {
        case .recording: Task { await stop() }
        case .idle, .error: Task { await start() }
        default: break
        }
    }

    // MARK: - Start

    func start() async {
        state = .preparing
        lastLine = ""
        do {
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw ActaError.micDenied }

            let locale = try await LiveTranscriber.prepare(locale: Locale(identifier: AppSettings.localeID))
            startDate = Date()
            let writer = try MarkdownWriter(folder: AppSettings.outputFolder, title: title, date: startDate)
            self.writer = writer

            let onSegment: SegmentHandler = { [weak self] seg in
                writer.append(seg)
                Task { @MainActor in self?.lastLine = "\(seg.speaker): \(seg.text)" }
            }

            // 1. Transcriptores listos antes de abrir el audio, así los tiempos cuadran.
            let mic = LiveTranscriber(speaker: "Yo", onSegment: onSegment)
            try await mic.start(locale: locale)
            self.mic = mic

            var sys: LiveTranscriber?
            if AppSettings.captureSystem {
                let s = LiveTranscriber(speaker: "Ellos", onSegment: onSegment)
                try await s.start(locale: locale)
                sys = s
                self.sys = s
            }

            // 2. Micrófono
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let fmt = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { @Sendable buffer, _ in
                mic.append(buffer)
            }
            try engine.start()
            self.engine = engine

            // 3. Audio del sistema (la otra parte de la llamada)
            if let sys {
                let tap = SystemAudioTap()
                try tap.start { @Sendable buffer in sys.append(buffer) }
                self.tap = tap
            }

            elapsed = 0
            state = .recording
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.elapsed = Date().timeIntervalSince(self.startDate)
                }
            }
        } catch {
            await teardownAudio()
            if let w = writer { w.discardIfEmpty() }
            writer = nil
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Stop

    func stop() async {
        state = .summarizing
        timer?.invalidate()
        timer = nil
        await teardownAudio()

        guard let writer else { state = .idle; return }
        self.writer = nil

        if writer.isEmpty {
            writer.discardIfEmpty()
            title = ""
            state = .error("No he detectado voz, así que no he creado ninguna nota.")
            return
        }

        let duration = Date().timeIntervalSince(startDate)
        let engine = AppSettings.engine
        var notes: String?
        var failure: String?
        do {
            notes = try await Summarizer.notes(for: writer.transcript(), engine: engine)
        } catch {
            failure = error.localizedDescription
        }

        do {
            try writer.finalize(notes: notes,
                                duration: duration,
                                engineLabel: engine.shortLabel,
                                includeTranscript: AppSettings.includeTranscript || notes == nil)
            lastFile = writer.url
            if AppSettings.openWhenDone { NSWorkspace.shared.open(writer.url) }
        } catch {
            failure = "No pude guardar el .md: \(error.localizedDescription)"
        }

        title = ""
        if let failure {
            state = .error("Nota guardada sin resumen. \(failure)")
        } else {
            state = .idle
        }
    }

    private func teardownAudio() async {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        tap?.stop()
        tap = nil
        await mic?.finish()
        await sys?.finish()
        mic = nil
        sys = nil
    }
}
