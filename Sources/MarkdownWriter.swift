import Foundation

/// Escribe la transcripción en el .md a medida que llega (si la app se cierra, no pierdes nada)
/// y al final lo reescribe con las notas arriba y la transcripción ordenada abajo.
final class MarkdownWriter: @unchecked Sendable {
    let url: URL
    private let title: String
    private let date: Date
    private var segments: [Segment] = []
    private var handle: FileHandle?
    private let queue = DispatchQueue(label: "acta.writer")

    init(folder: URL, title: String, date: Date) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = clean.isEmpty ? "Reunión" : clean
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HHmm"
        let safe = t.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        url = folder.appendingPathComponent("\(df.string(from: date)) \(safe).md")
        self.title = t
        self.date = date

        let header = "# \(t)\n\n> Grabando… las notas aparecerán aquí al terminar.\n\n## Transcripción\n\n"
        try header.write(to: url, atomically: true, encoding: .utf8)
        handle = try FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    func append(_ s: Segment) {
        queue.async {
            self.segments.append(s)
            self.handle?.write(Data(Self.line(s).utf8))
        }
    }

    var isEmpty: Bool { queue.sync { segments.isEmpty } }

    func transcript() -> String {
        let all = queue.sync { segments }
        let cleaned = AppSettings.echoFilter ? EchoFilter.clean(all) : all
        return cleaned.sorted { $0.start < $1.start }.map(Self.line).joined()
    }

    func finalize(notes: String?, duration: TimeInterval, engineLabel: String, includeTranscript: Bool) throws {
        queue.sync {
            try? handle?.close()
            handle = nil
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "es_ES")
        df.dateStyle = .medium
        df.timeStyle = .short
        let mins = max(1, Int((duration / 60).rounded()))

        var md = "# \(title)\n\n"
        md += "**Fecha:** \(df.string(from: date)) · **Duración:** \(mins) min · **Notas:** \(engineLabel)\n\n"
        if let notes, !notes.isEmpty {
            md += notes.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        } else {
            md += "> No pude generar el resumen. Tienes la transcripción completa abajo.\n\n"
        }
        if includeTranscript {
            md += "---\n\n## Transcripción\n\n" + transcript()
        }
        try md.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Si no se transcribió nada, borra el .md vacío para no dejar basura.
    func discardIfEmpty() {
        queue.sync {
            try? handle?.close()
            handle = nil
            if segments.isEmpty { try? FileManager.default.removeItem(at: url) }
        }
    }

    static func line(_ s: Segment) -> String {
        "**[\(timestamp(s.start))] \(s.speaker):** \(s.text)\n\n"
    }

    static func timestamp(_ t: Double) -> String {
        let i = Int(t)
        return String(format: "%02d:%02d:%02d", i / 3600, (i % 3600) / 60, i % 60)
    }
}
