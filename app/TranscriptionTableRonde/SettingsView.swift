import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Pipeline Python") {
                pathRow(label: "Dossier du pipeline", path: $settings.pipelineFolder, chooseDirectory: true)
                pathRow(label: "Interpréteur Python (venv)", path: $settings.pythonPath, chooseDirectory: false)
            }

            Section("Hugging Face") {
                SecureField("Token (hf_…)", text: $settings.hfToken)
                Text("Nécessaire pour la diarisation pyannote. Stocké dans le trousseau macOS, jamais en clair dans les préférences de l'app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func pathRow(label: String, path: Binding<String>, chooseDirectory: Bool) -> some View {
        HStack {
            TextField(label, text: path)
            Button("Choisir…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = chooseDirectory
                panel.canChooseFiles = !chooseDirectory
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    path.wrappedValue = url.path
                }
            }
        }
    }
}
