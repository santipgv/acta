import Foundation
import FoundationModels

enum Summarizer {
    // MARK: - Prompt

    static var instructions: String {
        let name = AppSettings.userName.isEmpty ? "el usuario" : AppSettings.userName
        let vocab = AppSettings.vocabulary
        var text = """
        Eres el asistente de \(name) y redactas actas de reuniones de trabajo en español: concretas, fiables y fáciles de escanear.
        En la transcripción, "Yo" es \(name) y "Ellos" es todo lo que sonó por el altavoz (la otra parte y, a veces, compañeros de \(name)).
        La transcripción es automática y tiene errores: corrige palabras mal reconocidas usando el contexto.
        Reglas:
        - No inventes nada. Si dudas de un dato o de quién dijo algo, añade "(por confirmar)".
        - Una decisión solo es decisión si alguien la confirmó de forma explícita. Lo que quedó por valorar va a "Temas abiertos".
        - Prefiere pocos puntos con datos concretos (nombres, sistemas, cifras, fechas) a muchos puntos genéricos.
        - Escribe Markdown puro. Nunca HTML.
        """
        if !vocab.isEmpty {
            text += "\nTérminos correctos que se usan en estas reuniones: " + vocab.joined(separator: ", ") + "."
        }
        return text
    }

    static func format(userTitled: Bool) -> String {
        let titleLine = userTitled ? "" : "# Título concreto de máximo 8 palabras sobre el tema principal\n"
        return """
        Devuelve el acta con exactamente esta estructura:

        \(titleLine)**Participantes:** nombres que aparecen en la conversación, separados por comas
        **Próxima reunión:** fecha, hora y objetivo si se acordó (si no, omite esta línea)

        ## Resumen
        2 a 4 frases: para qué era la reunión y a qué conclusión se llegó.

        ## Decisiones
        Solo lo confirmado de forma explícita. Si no hubo, escribe "- Ninguna en firme".

        ## Próximos pasos
        - [ ] **Responsable:** tarea (fecha si se dijo). Si no está claro quién lo hace, usa "**Por confirmar:**".

        ## Temas abiertos
        Como máximo 6 viñetas con lo que quedó pendiente de valorar o resolver.

        ## Puntos clave
        Como máximo 8 viñetas con datos concretos.

        ## Comentarios internos
        Solo si hay conversación interna sin la otra parte (por ejemplo, al final de la llamada). Si no, omite esta sección.
        """
    }

    static func notes(for transcript: String, engine: SummaryEngine, userTitled: Bool) async throws -> String {
        let fmt = format(userTitled: userTitled)
        let raw: String
        switch engine {
        case .apple: raw = try await apple(transcript, format: fmt)
        case .claudeAPI: raw = try await claudeAPI(transcript, format: fmt)
        case .claudeCode: raw = try await claudeCode(transcript, format: fmt)
        }
        return cleanMarkdown(raw)
    }

    /// Si el modelo devuelve HTML o bloques de código, lo paso a Markdown limpio.
    static func cleanMarkdown(_ s: String) -> String {
        var t = s
        let rules: [(String, String)] = [
            ("^\\s*```(?:markdown|md)?\\s*\\n", ""),
            ("\\n```\\s*$", ""),
            ("(?i)</?(ul|ol)>", "\n"),
            ("(?i)<li>\\s*", "- "),
            ("(?i)</li>", "\n"),
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</?(strong|b)>", "**"),
            ("(?i)</?(em|i)>", "_"),
            ("(?i)<h1>", "\n# "),
            ("(?i)<h2>", "\n## "),
            ("(?i)<h3>", "\n### "),
            ("(?i)</h[1-6]>", "\n"),
            ("(?i)</?p>", "\n"),
            ("\n[ \t]*\n([ \t]*\n)+", "\n\n"),
        ]
        for (pattern, replacement) in rules {
            t = t.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Apple Intelligence (local)
    // El modelo local tiene una ventana de contexto pequeña (unos 4K tokens),
    // así que las reuniones largas van por bloques y luego se unen.

    private static let chunkChars = 4000

    static func apple(_ transcript: String, format: String) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { throw ActaError.appleUnavailable }

        if transcript.count <= chunkChars {
            return try await askApple(format + "\n\nTranscripción:\n\n" + transcript)
        }

        var material = try await compress(chunks(transcript, size: chunkChars), label: "fragmento de una reunión")
        var rounds = 0
        while material.count > chunkChars && rounds < 3 {
            material = try await compress(chunks(material, size: chunkChars), label: "conjunto de notas parciales")
            rounds += 1
        }
        return try await askApple(format + "\n\nNotas parciales de toda la reunión:\n\n" + material)
    }

    private static func compress(_ parts: [String], label: String) async throws -> String {
        var out: [String] = []
        for (i, part) in parts.enumerated() {
            let prompt = """
            Este es el \(label) (\(i + 1) de \(parts.count)). Extrae en viñetas muy breves y fieles: \
            quién participa, qué se explicó (sistemas, nombres, cifras), decisiones confirmadas, \
            compromisos con su responsable, temas pendientes y fechas. No interpretes ni añadas nada.

            \(part)
            """
            out.append(try await askApple(prompt))
        }
        return out.joined(separator: "\n\n")
    }

    private static func askApple(_ prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: prompt).content
    }

    static func chunks(_ text: String, size: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n\n") where !paragraph.isEmpty {
            if current.count + paragraph.count > size, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current += paragraph + "\n\n"
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: - Claude por API key

    static func claudeAPI(_ transcript: String, format: String) async throws -> String {
        guard let key = Keychain.get("anthropic"), !key.isEmpty else { throw ActaError.missingAPIKey }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": AppSettings.claudeModel,
            "max_tokens": 4096,
            "system": instructions,
            "messages": [[
                "role": "user",
                "content": format + "\n\n<transcripcion>\n" + transcript + "\n</transcripcion>",
            ]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ActaError.claude(String(data: data, encoding: .utf8) ?? "respuesta vacía")
        }

        struct Reply: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
        }
        return try JSONDecoder().decode(Reply.self, from: data).content.compactMap(\.text).joined()
    }

    // MARK: - Claude con tu suscripción (vía Claude Code instalado en el Mac)

    static func claudeCode(_ transcript: String, format: String) async throws -> String {
        let path = try claudePath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [
            "-p",
            instructions + "\n\nRedacta el acta de la reunión cuya transcripción recibes por la entrada estándar. "
                + "No uses herramientas ni leas archivos.\n\n" + format,
        ]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        // Sin ANTHROPIC_API_KEY para que use tu sesión de Claude y no facture por API.
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        async let outData = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        async let errData = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
        input.fileHandleForWriting.write(Data(transcript.utf8))
        try? input.fileHandleForWriting.close()

        let (out, err) = await (outData, errData)
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ActaError.claude(String(data: err, encoding: .utf8) ?? "Claude Code terminó con error")
        }
        return String(data: out, encoding: .utf8) ?? ""
    }

    static func claudePath() throws -> String {
        let fm = FileManager.default
        let custom = (AppSettings.claudeCLIPath as NSString).expandingTildeInPath
        if !custom.isEmpty, fm.isExecutableFile(atPath: custom) { return custom }

        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return found }

        // Último intento: preguntar a tu shell de login
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !path.isEmpty, fm.isExecutableFile(atPath: path) { return path }

        throw ActaError.claudeCodeNotFound
    }
}
