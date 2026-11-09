import Foundation

/// Quita el eco del altavoz sin auriculares.
/// Si tu micro recoge lo que dice la otra parte, esa frase aparece dos veces: como "Ellos"
/// (audio del sistema, limpio) y como "Yo" (micro). Comparo cada frase de "Yo" con lo que
/// dijo "Ellos" en esos mismos segundos; si casi todas sus palabras coinciden, es eco y la descarto.
/// Si hablas por encima de ellos, tu frase mezcla palabras propias y no llega al umbral: se queda.
enum EchoFilter {
    static let margin: Double = 3        // segundos de holgura entre los dos relojes
    static let threshold: Double = 0.6   // % de palabras de "Yo" que ya dijo "Ellos"
    static let minWords = 3              // frases muy cortas ("sí", "vale") nunca se descartan

    static func clean(_ segments: [Segment]) -> [Segment] {
        let theirs = segments.filter { $0.speaker == "Ellos" }
        guard !theirs.isEmpty else { return segments }

        return segments.filter { seg in
            guard seg.speaker == "Yo" else { return true }
            let mine = words(seg.text)
            guard mine.count >= minWords else { return true }

            let nearby = theirs.filter {
                $0.start <= seg.end + margin && $0.end >= seg.start - margin
            }
            guard !nearby.isEmpty else { return true }

            let heard = Set(nearby.flatMap { words($0.text) })
            let overlap = Double(mine.filter { heard.contains($0) }.count) / Double(mine.count)
            return overlap < threshold
        }
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
