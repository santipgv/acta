import SwiftUI
import AppKit

@main
struct ActaApp: App {
    @StateObject private var recorder = Recorder()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(recorder)
        } label: {
            switch recorder.state {
            case .recording:
                Text("● " + recorder.elapsedString)
            case .preparing, .summarizing:
                Image(systemName: "hourglass")
            default:
                Image(systemName: "waveform")
            }
        }
        .menuBarExtraStyle(.window)

        Window("Ajustes de Acta", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}

struct MenuView: View {
    @EnvironmentObject var r: Recorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Acta").font(.headline)

            switch r.state {
            case .idle, .error:
                TextField("Título de la reunión (opcional)", text: $r.title)
                    .textFieldStyle(.roundedBorder)
                Button {
                    r.toggle()
                } label: {
                    Label("Empezar a grabar", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)

            case .preparing:
                ProgressView("Preparando micrófono y transcripción…")

            case .recording:
                Text("Grabando · \(r.elapsedString)").font(.subheadline.bold())
                if !r.lastLine.isEmpty {
                    Text(r.lastLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Button {
                    r.toggle()
                } label: {
                    Label("Parar y generar notas", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)

            case .summarizing:
                ProgressView("Generando notas…")
            }

            if case .error(let msg) = r.state {
                Text(msg).font(.caption).foregroundStyle(.red)
            }

            if let f = r.lastFile {
                Button("Abrir última nota") { NSWorkspace.shared.open(f) }
            }

            Divider()
            HStack {
                Button("Ajustes…") {
                    openWindow(id: "settings")
                    NSApp.activate()
                }
                Spacer()
                Button("Salir") { NSApp.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 300)
    }
}
