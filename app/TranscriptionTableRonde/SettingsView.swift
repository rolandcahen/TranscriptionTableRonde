import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Dossiers de travail") {
                pathRow(label: "Dossier des enregistrements",
                        path: $settings.recordingsFolder,
                        chooseDirectory: true,
                        verification: Self.verifierDossierFacultatif)
                pathRow(label: "Dossier de sauvegarde (transcriptions)",
                        path: $settings.outputRootFolder,
                        chooseDirectory: true,
                        verification: Self.verifierDossierFacultatif)
                Text("Si le dossier de sauvegarde est vide, chaque transcription est enregistrée à côté de son fichier audio (comportement historique).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pipeline Python (installation)") {
                pathRow(label: "Dossier du pipeline",
                        path: $settings.pipelineFolder,
                        chooseDirectory: true,
                        verification: Self.verifierDossierPipeline)
                pathRow(label: "Interpréteur Python (venv)",
                        path: $settings.pythonPath,
                        chooseDirectory: false,
                        verification: Self.verifierInterpreteur)
                Text("Ces deux chemins désignent l'installation du logiciel, à ne pas confondre avec les dossiers de travail ci-dessus : le dossier du pipeline contient transcribe_diarize.py et summarize.py, jamais un dossier « sortie_… ».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hugging Face") {
                SecureField("Token (hf_…)", text: $settings.hfToken)
                Text("Nécessaire pour la diarisation pyannote. Stocké dans le trousseau macOS, jamais en clair dans les préférences de l'app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        // Largeur figée à 460 auparavant : un chemin réel — un dossier de
        // projet imbriqué dépasse vite la centaine de caractères — n'y était
        // visible que par son début, et c'est précisément cette illisibilité
        // qui permet de coller un dossier de sortie dans le champ du
        // pipeline sans s'en apercevoir. La fenêtre s'étire désormais.
        .frame(minWidth: 560, idealWidth: 820, maxWidth: .infinity,
               minHeight: 430, idealHeight: 540, maxHeight: .infinity)
    }

    // MARK: - Vérification des chemins

    /// Ce que l'application trouve réellement à l'emplacement indiqué.
    /// Affiché sous chaque champ, pour qu'une erreur de chemin se voie au
    /// moment où elle est commise, et non une heure plus tard au milieu
    /// d'un traitement sous la forme d'une erreur Python brute.
    private struct Verification {
        let valide: Bool
        let message: String
    }

    private static func verifierDossierPipeline(_ chemin: String) -> Verification? {
        let nettoye = chemin.trimmingCharacters(in: .whitespaces)
        guard !nettoye.isEmpty else {
            return Verification(valide: false, message: "Chemin vide : indiquez le dossier contenant les scripts Python.")
        }
        let dossier = URL(fileURLWithPath: nettoye, isDirectory: true)
        let requis = ["transcribe_diarize.py", "summarize.py"]
        let manquants = requis.filter {
            !FileManager.default.fileExists(atPath: dossier.appendingPathComponent($0).path)
        }
        guard manquants.isEmpty else {
            return Verification(valide: false,
                                message: "Introuvable dans ce dossier : " + manquants.joined(separator: ", "))
        }
        return Verification(valide: true, message: "Scripts du pipeline trouvés.")
    }

    private static func verifierInterpreteur(_ chemin: String) -> Verification? {
        let nettoye = chemin.trimmingCharacters(in: .whitespaces)
        guard !nettoye.isEmpty else {
            return Verification(valide: false, message: "Chemin vide : indiquez l'interpréteur Python de l'environnement virtuel.")
        }
        var estDossier: ObjCBool = false
        guard FileManager.default.fileExists(atPath: nettoye, isDirectory: &estDossier) else {
            return Verification(valide: false, message: "Aucun fichier à cet emplacement.")
        }
        guard !estDossier.boolValue else {
            return Verification(valide: false, message: "C'est un dossier : il faut désigner le fichier python3 lui-même (bin/python3 dans le venv).")
        }
        guard FileManager.default.isExecutableFile(atPath: nettoye) else {
            return Verification(valide: false, message: "Ce fichier n'est pas exécutable.")
        }
        return Verification(valide: true, message: "Interpréteur trouvé.")
    }

    /// Un dossier de travail laissé vide est légitime : pas de verdict dans
    /// ce cas, plutôt qu'un avertissement qui crierait au loup.
    private static func verifierDossierFacultatif(_ chemin: String) -> Verification? {
        let nettoye = chemin.trimmingCharacters(in: .whitespaces)
        guard !nettoye.isEmpty else { return nil }
        var estDossier: ObjCBool = false
        guard FileManager.default.fileExists(atPath: nettoye, isDirectory: &estDossier),
              estDossier.boolValue else {
            return Verification(valide: false, message: "Ce dossier n'existe pas.")
        }
        return Verification(valide: true, message: "Dossier trouvé.")
    }

    // MARK: - Ligne de chemin

    private func pathRow(label: String,
                         path: Binding<String>,
                         chooseDirectory: Bool,
                         verification: (String) -> Verification?) -> some View {
        let etat = verification(path.wrappedValue)
        return VStack(alignment: .leading, spacing: 4) {
            // Le libellé est placé au-dessus plutôt qu'en texte de
            // substitution : le champ dispose ainsi de toute la largeur de
            // la fenêtre pour afficher le chemin.
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("", text: path)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .help(path.wrappedValue.isEmpty ? label : path.wrappedValue)
                Button("Choisir…") {
                    choisir(label: label, path: path, chooseDirectory: chooseDirectory)
                }
            }
            if let etat {
                Label(etat.message,
                      systemImage: etat.valide ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(etat.valide ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func choisir(label: String, path: Binding<String>, chooseDirectory: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = chooseDirectory
        panel.canChooseFiles = !chooseDirectory
        panel.allowsMultipleSelection = false
        panel.message = label
        // Rouvrir là où pointe déjà le réglage évite de renaviguer depuis la
        // racine du disque à chaque correction.
        let actuel = path.wrappedValue.trimmingCharacters(in: .whitespaces)
        if !actuel.isEmpty {
            let url = URL(fileURLWithPath: actuel)
            panel.directoryURL = chooseDirectory ? url : url.deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            path.wrappedValue = url.path
        }
    }
}
