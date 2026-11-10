import Foundation

/// Quita el eco del altavoz cuando no usas auriculares.
/// Lo que dice la otra parte entra dos veces: limpio por el audio del sistema ("Ellos")
/// y con retraso por tu micro ("Yo"). Para cada frase de "Yo" busco grupos de 4 palabras
/// seguidas que "Ellos" dijo en los 30 segundos de alrededor y los quito.
/// Si casi toda la frase es eco, desaparece; si mezcla eco con algo tuyo, me quedo con lo tuyo.
enum EchoFilter {
    static let window: Double = 30      // segundos de holgura entre ambos relojes y el retraso del eco
    static let n = 4                    // palabras seguidas que tienen que coincidir
    static let dropRatio = 0.8          // si el 80 % de la frase es eco, se descarta entera
    static let minKeep = 4              // si tras limpiar quedan menos palabras, se descarta

    static func clean(_ segments: [Segment]) -> [Segment] {
        let theirs = segments.filter { $0.speaker == "Ellos" }
        guard !theirs.isEmpty else { return segments }

        return segments.compactMap { seg in
            guard seg.speaker == "Yo" else { return seg }

            let nearby = theirs.filter { $0.start <= seg.end + window && $0.end >= seg.start - window }
            guard !nearby.isEmpty else { return seg }

            var grams = Set<String>()
            for s in nearby {
                let w = words(s.text)
                guard w.count >= n else { continue }
                for i in 0...(w.count - n) { grams.insert(w[i..<(i + n)].joined(separator: " ")) }
            }
            guard !grams.isEmpty else { return seg }

            let tokens = seg.text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let normalized = tokens.map(norm)
            let wordIdx = normalized.indices.filter { !normalized[$0].isEmpty }
            guard wordIdx.count >= n else { return seg }

            var echo = Array(repeating: false, count: tokens.count)
            for k in 0...(wordIdx.count - n) {
                let window = wordIdx[k..<(k + n)]
                let gram = window.map { normalized[$0] }.joined(separator: " ")
                if grams.contains(gram) { for j in window { echo[j] = true } }
            }

            let echoed = wordIdx.filter { echo[$0] }.count
            if echoed == 0 { return seg }
            if Double(echoed) / Double(wordIdx.count) >= dropRatio { return nil }

            // Signos sueltos pegados a un trozo de eco también se van.
            for i in tokens.indices where normalized[i].isEmpty {
                if (i > 0 && echo[i - 1]) || (i + 1 < tokens.count && echo[i + 1]) { echo[i] = true }
            }
            let kept = tokens.indices.filter { !echo[$0] }.map { tokens[$0] }
            guard kept.filter({ !norm($0).isEmpty }).count >= minKeep else { return nil }

            return Segment(speaker: seg.speaker, start: seg.start, end: seg.end,
                           text: kept.joined(separator: " "))
        }
    }

    static func words(_ text: String) -> [String] {
        text.split(separator: " ").map { norm(String($0)) }.filter { !$0.isEmpty }
    }

    /// "¿Gestión," → "gestion"; "B-55" → "b55"
    static func norm(_ token: String) -> String {
        let folded = token.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
