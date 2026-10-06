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

    /// Dossier par défaut où s'ouvrent les sélecteurs de fichiers/dossiers
    /// audio (fenêtre "fichier unique" et "Traitement par lots"). Vide par
    /// défaut : macOS retombe alors sur le dernier dossier utilisé.
    @Published var recordingsFolder: String {
        didSet { UserDefaults.standard.set(recordingsFolder, forKey: "recordingsFolder") }
    }
    /// Dossier racine où sauvegarder les transcriptions/diarisations. Vide
    /// par défaut : comportement historique conservé, chaque sortie reste
    /// dans un sous-dossier "sortie_<nom>" à côté de son fichier audio (voir
    /// `outputFolder(for:)`).
    @Published var outputRootFolder: String {
        didSet { UserDefaults.standard.set(outputRootFolder, forKey: "outputRootFolder") }
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
        self.recordingsFolder = defaults.string(forKey: "recordingsFolder") ?? ""
        self.outputRootFolder = defaults.string(forKey: "outputRootFolder") ?? ""
    }

    /// Chemin complet vers transcribe_diarize.py, déduit de pipelineFolder.
    var scriptPath: String {
        (pipelineFolder as NSString).appendingPathComponent("transcribe_diarize.py")
    }

    /// Dossier de sortie pour un fichier audio donné : si `outputRootFolder`
    /// est renseigné, la sortie est rangée sous ce dossier
    /// (`outputRootFolder/sortie_<nom>`) plutôt qu'à côté de l'audio ; sinon
    /// le comportement historique est conservé (sous-dossier "sortie_<nom>"
    /// à côté du fichier), pour rester compatible avec les sessions déjà
    /// traitées avant ce réglage.
    func outputFolder(for audioURL: URL) -> URL {
        let folderName = "sortie_\(audioURL.deletingPathExtension().lastPathComponent)"
        let trimmedRoot = outputRootFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoot.isEmpty else {
            return audioURL.deletingLastPathComponent().appendingPathComponent(folderName)
        }
        return URL(fileURLWithPath: trimmedRoot, isDirectory: true).appendingPathComponent(folderName)
    }

    /// Vérifie, avant de lancer un sous-processus, que l'installation
    /// désignée par les Réglages existe bien. Retourne nil si tout est en
    /// place, sinon un message destiné à l'utilisateur, qui nomme le champ
    /// des Réglages à corriger.
    ///
    /// Sans ce contrôle, un mauvais chemin ne se manifeste que par l'erreur
    /// brute de Python ("can't open file '…/summarize.py': [Errno 2] No such
    /// file or directory"), qui dit bien ce qui manque mais pas où le
    /// corriger — et qui laisse surtout croire à un problème du fichier
    /// audio ou du dossier de sortie.
    func erreurDInstallation(pourScript script: String) -> String? {
        let fm = FileManager.default
        let interpreteur = pythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        var estDossier: ObjCBool = false

        guard !interpreteur.isEmpty,
              fm.fileExists(atPath: interpreteur, isDirectory: &estDossier),
              !estDossier.boolValue else {
            return "Interpréteur Python introuvable : \(interpreteur.isEmpty ? "(champ vide)" : interpreteur) — "
                + "corrigez le champ « Interpréteur Python (venv) » dans les Réglages (⌘,)."
        }
        guard fm.isExecutableFile(atPath: interpreteur) else {
            return "L'interpréteur Python indiqué n'est pas exécutable : \(interpreteur) — "
                + "corrigez le champ « Interpréteur Python (venv) » dans les Réglages (⌘,)."
        }

        let dossier = pipelineFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let cheminScript = (dossier as NSString).appendingPathComponent(script)
        guard !dossier.isEmpty, fm.fileExists(atPath: cheminScript) else {
            return "\(script) est introuvable dans le dossier du pipeline : \(dossier.isEmpty ? "(champ vide)" : dossier) — "
                + "ce champ doit désigner le dossier d'installation qui contient les scripts Python, "
                + "et non un dossier de sortie « sortie_… ». Corrigez le champ « Dossier du pipeline » dans les Réglages (⌘,)."
        }
        return nil
    }
}
