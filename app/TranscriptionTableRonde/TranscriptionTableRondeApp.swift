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
    // Même raisonnement pour la session "fichier unique" : une seule
    // instance persistée au niveau de l'app, pour que la fenêtre principale
    // retrouve toujours le même état sauvegardé, quel que soit le nombre de
    // fois où elle est ouverte/fermée.
    @StateObject private var singleSession = SingleSessionStore()

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(batchQueue)
                .environmentObject(singleSession)
                // 760 et non 640 : le bandeau de signatures occupe 277 pt à
                // droite du titre, et en dessous de cette largeur il
                // viendrait chevaucher le sous-titre.
                .frame(minWidth: 760, minHeight: 560)
        }
        .windowResizability(.contentSize)
        .commands {
            // Remplace le panneau « À propos » standard par notre fenêtre,
            // qui porte les signatures institutionnelles et la notice.
            CommandGroup(replacing: .appInfo) {
                Button("À propos de Transcription table ronde") {
                    openWindow(id: "about")
                }
            }
        }

        Window("À propos de Transcription table ronde", id: "about") {
            AboutView()
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
