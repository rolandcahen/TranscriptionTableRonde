import Foundation
import Combine

enum SingleSessionStatus: String, Codable {
    /// Aucune session en cours (rien lancé, ou dernier essai en échec — dans
    /// ce cas les champs sont quand même conservés pour ne pas faire
    /// ressaisir le contexte/nombre de locuteurs).
    case notStarted
    /// Un traitement était en cours au moment de la fermeture/du plantage :
    /// il n'a pas pu se terminer proprement et doit être relancé.
    case running
    /// Le dernier traitement pour ce fichier s'est terminé avec succès.
    case finished
}

/// Snapshot de l'état de la fenêtre "fichier unique" (`ContentView`) :
/// fichier en cours, dossier de sortie, contexte, nombre de locuteurs et
/// catégories de résumé. Sans ceci, tout est ré-saisi à chaque relance de
/// l'app puisque `ContentView` ne garde son état qu'en `@State` volatile.
///
/// Suit le même patron de persistance JSON que `BatchQueueManager`
/// (fichier dans Application Support), dans un fichier séparé de
/// `batch_queue.json` : les deux fenêtres ont des cycles de vie
/// indépendants et ne doivent pas se marcher dessus.
struct SingleSessionState: Codable, Equatable {
    var audioURL: URL?
    var outputFolder: URL?
    var numSpeakersText: String
    var contextText: String
    var categoriesText: String
    var status: SingleSessionStatus
}

final class SingleSessionStore: ObservableObject {
    @Published private(set) var lastState: SingleSessionState?

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranscriptionTableRonde", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        fileURL = appSupport.appendingPathComponent("single_session.json")
        load()
    }

    /// Remplace l'état sauvegardé. Appelé à chaque changement significatif
    /// (fichier choisi, contexte/nombre de locuteurs modifiés, démarrage ou
    /// fin d'un traitement) — pas besoin de bouton "Sauvegarder" explicite,
    /// dans l'esprit des autres réglages de l'app.
    func save(_ state: SingleSessionState) {
        lastState = state
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(SingleSessionState.self, from: data) else { return }
        lastState = state
    }
}
