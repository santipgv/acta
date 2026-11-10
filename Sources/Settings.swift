import Foundation
import SwiftUI
import AppKit
import Security

enum SummaryEngine: String, CaseIterable, Identifiable {
    case apple, claudeAPI, claudeCode
    var id: String { rawValue }

    var label: String {
        switch self {
        case .apple: "Apple Intelligence (local, privado)"
        case .claudeAPI: "Claude con API key"
        case .claudeCode: "Claude con mi suscripción (Claude Code)"
        }
    }

    var shortLabel: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .claudeAPI, .claudeCode: "Claude"
        }
    }
}

/// Lectura de ajustes fuera de las vistas. Los valores por defecto coinciden con SettingsView.
enum AppSettings {
    private static var d: UserDefaults { .standard }

    static var engine: SummaryEngine { SummaryEngine(rawValue: d.string(forKey: "engine") ?? "") ?? .apple }
    static var localeID: String { d.string(forKey: "localeID") ?? "es-ES" }
    static var captureSystem: Bool { d.object(forKey: "captureSystem") as? Bool ?? true }
    static var echoFilter: Bool { d.object(forKey: "echoFilter") as? Bool ?? true }
    static var includeTranscript: Bool { d.object(forKey: "includeTranscript") as? Bool ?? true }
    static var openWhenDone: Bool { d.object(forKey: "openWhenDone") as? Bool ?? true }
    static var claudeModel: String { d.string(forKey: "claudeModel") ?? "claude-sonnet-5-5" }
    static var claudeCLIPath: String { d.string(forKey: "claudeCLIPath") ?? "" }
    static var outputFolder: URL {
        let raw = d.string(forKey: "outputFolder") ?? "~/Documents/Reuniones"
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }
}

/// La API key va al Llavero, nunca a un archivo.
enum Keychain {
    private static let service = "com.santi.acta"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

struct SettingsView: View {
    @AppStorage("engine") private var engine = SummaryEngine.apple.rawValue
    @AppStorage("localeID") private var localeID = "es-ES"
    @AppStorage("captureSystem") private var captureSystem = true
    @AppStorage("echoFilter") private var echoFilter = true
    @AppStorage("includeTranscript") private var includeTranscript = true
    @AppStorage("openWhenDone") private var openWhenDone = true
    @AppStorage("outputFolder") private var outputFolder = "~/Documents/Reuniones"
    @AppStorage("claudeModel") private var claudeModel = "claude-sonnet-5-5"
    @AppStorage("claudeCLIPath") private var claudeCLIPath = ""
    @State private var apiKey = Keychain.get("anthropic") ?? ""

    var body: some View {
        Form {
            Section("Grabación") {
                Picker("Idioma de la reunión", selection: $localeID) {
                    Text("Español (España)").tag("es-ES")
                    Text("Español (México)").tag("es-MX")
                    Text("English (US)").tag("en-US")
                    Text("English (UK)").tag("en-GB")
                    Text("Português (Brasil)").tag("pt-BR")
                }
                Toggle("Capturar el audio de la otra parte (Zoom, Meet, Teams…)", isOn: $captureSystem)
                Toggle("Filtrar el eco del altavoz (para usar sin auriculares)", isOn: $echoFilter)
                    .disabled(!captureSystem)
                Text("Si tu micro recoge a la otra parte, Acta lo detecta comparándolo con el audio de la llamada y no lo apunta como tuyo.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Notas") {
                Picker("Motor", selection: $engine) {
                    ForEach(SummaryEngine.allCases) { Text($0.label).tag($0.rawValue) }
                }

                switch SummaryEngine(rawValue: engine) ?? .apple {
                case .apple:
                    Text("Todo ocurre en tu Mac. Necesita Apple Intelligence activado en Ajustes del Sistema.")
                        .font(.caption).foregroundStyle(.secondary)
                case .claudeAPI:
                    SecureField("API key de Anthropic", text: $apiKey)
                        .onChange(of: apiKey) { _, value in Keychain.set(value, for: "anthropic") }
                    TextField("Modelo", text: $claudeModel)
                    Text("Se cobra por uso en console.anthropic.com, aparte de tu plan de Claude. La transcripción sale del Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                case .claudeCode:
                    TextField("Ruta de claude (vacío = buscar sola)", text: $claudeCLIPath)
                    Text("Usa tu sesión de Claude Code (instálalo y haz login una vez en Terminal). Anthropic puede descontar este uso de un cupo mensual propio de tu plan. La transcripción sale del Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Toggle("Incluir la transcripción completa en el .md", isOn: $includeTranscript)
                Toggle("Abrir la nota al terminar", isOn: $openWhenDone)
            }

            Section("Archivos") {
                HStack {
                    TextField("Carpeta de notas", text: $outputFolder)
                    Button("Elegir…", action: pickFolder)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Usar esta carpeta"
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url.path
        }
    }
}

enum ActaError: LocalizedError {
    case micDenied
    case localeNotSupported(String)
    case noAudioFormat
    case coreAudio(String, OSStatus)
    case appleUnavailable
    case missingAPIKey
    case claude(String)
    case claudeCodeNotFound

    var errorDescription: String? {
        switch self {
        case .micDenied:
            "Sin permiso de micrófono. Actívalo en Ajustes del Sistema > Privacidad y seguridad > Micrófono."
        case .localeNotSupported(let id):
            "El idioma \(id) no está disponible para transcripción en este Mac."
        case .noAudioFormat:
            "No he podido preparar el formato de audio para transcribir."
        case .coreAudio(let step, let status):
            "Error de audio al \(step) (código \(status)). Revisa el permiso de \"Grabación de audio del sistema\"."
        case .appleUnavailable:
            "Apple Intelligence no está disponible. Actívalo en Ajustes del Sistema o cambia a Claude en Ajustes."
        case .missingAPIKey:
            "Falta la API key de Anthropic en Ajustes."
        case .claude(let msg):
            "Claude devolvió un error: \(msg.prefix(300))"
        case .claudeCodeNotFound:
            "No encuentro Claude Code. Instálalo o indica su ruta en Ajustes."
        }
    }
}
