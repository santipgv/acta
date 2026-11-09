import Foundation
import FoundationModels

enum Summarizer {
    static let instructions = """
    Eres un asistente que redacta actas de reuniones de trabajo en español, claras y fáciles de escanear.
    En la transcripción, "Yo" es el usuario y "Ellos" es la otra parte de la llamada.
    No inventes nada que no aparezca en la transcripción. Si algo no está claro, dilo.
    """

    static let format = """
    Devuelve SOLO Markdown con estas secciones (omite una sección si no hay contenido):
    ## Resumen
    3 a 5 frases.
    ## Puntos clave
    Viñetas breves.
    ## Decisiones
    Viñetas.
    ## Próximos pasos
    Lista de tareas con el formato "- [ ] Responsable: tarea (fecha si se mencionó)".
    ## Preguntas abiertas
    Viñetas.
    """

    static func notes(for transcript: String, engine: SummaryEngine) async throws -> String {
        switch engine {
        case .apple: return try await apple(transcript)
        case .claudeAPI: return try await claudeAPI(transcript)
        case .claudeCode: return try await claudeCode(transcript)
        }
    }

    // MARK: - Apple Intelligence (local)
    // El modelo local tiene una ventana de contexto pequeña (unos 4K tokens),
    // así que las reuniones largas van por bloques y luego se unen.

    private static let chunkChars = 5000

    static func apple(_ transcript: String) async throws -> String {
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
            Este es el \(label) (\(i + 1) de \(parts.count)). Extrae en viñetas muy breves: \
            temas tratados, decisiones, tareas con responsable y preguntas abiertas.

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

    static func claudeAPI(_ transcript: String) async throws -> String {
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

    static func claudeCode(_ transcript: String) async throws -> String {
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
