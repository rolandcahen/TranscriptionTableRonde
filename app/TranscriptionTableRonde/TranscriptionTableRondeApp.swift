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
                // 900 et non 640 : le bandeau de signatures occupe 414 pt à
                // droite du titre — ENSCi 80, CRD 86, ENS Paris-Saclay 145,
                // Sepsis 61, plus trois espacements de 14 — et en dessous de
                // cette largeur il viendrait chevaucher le sous-titre.
                // maxHeight infini et alignement en haut : sans cela, un
                // contenu plus court que la hauteur minimale se centre dans
                // la fenêtre et laisse une bande vide en haut comme en bas —
                // visible dès que les trois onglets sont repliés. Le contenu
                // doit se coller au titre, et le vide tomber en dessous.
                .frame(minWidth: 900, idealWidth: 1000, maxWidth: .infinity,
                       minHeight: 560, idealHeight: 720, maxHeight: .infinity,
                       alignment: .top)
        }
        // .contentMinSize et non .contentSize : le premier traite la taille
        // du contenu comme un plancher, le second comme une consigne stricte,
        // ce qui empêchait tout agrandissement vertical de la fenêtre.
        .windowResizability(.contentMinSize)
        .commands {
            // Remplace le panneau « À propos » standard par notre fenêtre,
            // qui porte les signatures institutionnelles et la notice.
            CommandGroup(replacing: .appInfo) {
                Button("À propos de Transcription table ronde") {
                    openWindow(id: "about")
                }
            }
            // Les trois actions de la barre d'outils, également au menu.
            // Une icône sans libellé se devine ; un menu se lit, s'explore,
            // et porte son raccourci clavier à côté de son nom.
            CommandMenu("Traitement") {
                Button("Traitement par lots…") {
                    openWindow(id: "batchQueue")
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("Ouvrir une session existante…") {
                    NotificationCenter.default.post(name: .ttrOuvrirSessionExistante, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Réglages…") {
                    NotificationCenter.default.post(name: .ttrOuvrirReglages, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
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
        // .contentMinSize et non .contentSize : la fenêtre s'ouvre à sa
        // taille idéale mais reste étirable, pour lire en entier des chemins
        // qui dépassent largement la largeur d'origine.
        .windowResizability(.contentMinSize)

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
