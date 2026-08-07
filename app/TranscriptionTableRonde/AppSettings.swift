import Foundation
import Combine

/// Réglages persistés de l'app : chemins vers le pipeline Python et
/// préférences par défaut (voir Réglages > TranscriptionTableRonde).
///
/// Le token Hugging Face n'est PAS stocké ici : il vit dans le trousseau
/// macOS (Keychain) via KeychainHelper, comme n'importe quel identifiant
/// sensible, jamais en clair dans les préférences de l'app.
final class AppSettings: ObservableObject {
    @Published var pipelineFolder: String {
        didSet { UserDefaults.standard.set(pipelineFolder, forKey: "pipelineFolder") }
    }
    @Published var pythonPath: String {
        didSet { UserDefaults.standard.set(pythonPath, forKey: "pythonPath") }
    }
    @Published var defaultModel: String {
        didSet { UserDefaults.standard.set(defaultModel, forKey: "defaultModel") }
    }
    @Published var hfToken: String = "" {
        didSet { KeychainHelper.save(token: hfToken) }
    }

    static let models = ["large-v3-turbo", "large-v3", "medium"]

    init() {
        let defaults = UserDefaults.standard
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        self.pipelineFolder = defaults.string(forKey: "pipelineFolder")
            ?? "\(home)/transcription_pipeline"
        self.pythonPath = defaults.string(forKey: "pythonPath")
            ?? "\(home)/transcription_pipeline/venv/bin/python3"
        self.defaultModel = defaults.string(forKey: "defaultModel") ?? "large-v3-turbo"
        self.hfToken = KeychainHelper.load() ?? ""
    }

    /// Chemin complet vers transcribe_diarize.py, déduit de pipelineFolder.
    var scriptPath: String {
        (pipelineFolder as NSString).appendingPathComponent("transcribe_diarize.py")
    }
}
