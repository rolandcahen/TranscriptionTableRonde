import SwiftUI

@main
struct TranscriptionTableRondeApp: App {
    @StateObject private var settings = AppSettings()
    // Instance unique partagée par toutes les fenêtres : si elle était créée
    // dans BatchQueueView (@StateObject local), ouvrir une deuxième fenêtre
    // "batchQueue" (ex. double-clic accidentel sur l'icône) instanciait un
    // second BatchQueueManager qui rechargeait la même file persistée et
    // relançait son propre traitement en parallèle du premier — deux
    // processus Python concurrents sur le même fichier, et la fermeture
    // d'une des deux fenêtres rendait l'un des deux incontrôlable (plus de
    // bouton pause/interrompre). Avec une instance unique, toute fenêtre
    // "batchQueue" pilote toujours le même état : aucun traitement en double
    // possible, quel que soit le nombre de fenêtres ouvertes.
    @StateObject private var batchQueue = BatchQueueManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(batchQueue)
                .frame(minWidth: 640, minHeight: 560)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(settings)
        }

        WindowGroup(id: "review", for: ReviewTarget.self) { $target in
            if let target {
                ReviewView(target: target)
            } else {
                Text("Aucun transcript sélectionné.")
            }
        }

        WindowGroup(id: "batchQueue") {
            BatchQueueView()
                .environmentObject(settings)
                .environmentObject(batchQueue)
        }
    }
}
