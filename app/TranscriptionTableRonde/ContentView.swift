import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var batchQueue: BatchQueueManager
    // Session persistée de cette fenêtre (fichier, contexte, nombre de
    // locuteurs...) — voir SingleSessionStore.swift. Sans ça, tout est
    // ré-saisi à chaque relance de l'app puisque les @State ci-dessous sont
    // volatiles.
    @EnvironmentObject private var sessionStore: SingleSessionStore
    @StateObject private var runner = PipelineRunner()
    @StateObject private var summaryRunner = SummaryRunner()
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    @State private var audioURL: URL?
    @State private var numSpeakersText: String = ""
    @State private var isTargeted = false
    @State private var sessionError: String?
    // Journal replié au départ : il sert au diagnostic, pas à la conduite
    // ordinaire d'une session, et il mangeait la moitié de la fenêtre.
    @State private var journalOuvert = false
    @State private var categoriesText: String = ContentView.defaultCategoriesText
    @State private var contextText: String = ""
    // Message affiché quand une session a été interrompue (app quittée ou
    // plantée en plein traitement) et retrouvée au lancement — invite juste
    // à relancer, plutôt que de prétendre à tort que le traitement est
    // terminé.
    @State private var resumeBanner: String?
    // Vrai tant qu'une session interrompue retrouvée au lancement n'a pas
    // été traitée (relancée ou remplacée) : sans ce drapeau, la simple
    // restauration des champs réenregistrerait la session en "notStarted"
    // et le message disparaîtrait dès le lancement suivant, même sans que
    // la transcription ait été relancée.
    @State private var interruptedRun = false

    static let defaultCategoriesText = """
    État de la recherche
    Questions posées
    Réponses apportées
    Difficultés mises en avant
    Propositions de développement
    Implications techniques
    Implications financières
    Autres éléments pertinents
    """

    var body: some View {
        // Toute la page défile.
        //
        // Elle ne le faisait pas avant parce que la fenêtre était contrainte
        // à la taille exacte de son contenu : il tenait donc toujours, au
        // prix d'une fenêtre non redimensionnable. En rendant celle-ci
        // étirable, j'ai supprimé cette garantie sans la remplacer — et dès
        // que les trois onglets étaient dépliés, le bas de la page, journal
        // compris, devenait tout simplement inatteignable.
        ScrollView(.vertical) {
            contenu
        }
        .scrollIndicators(.visible)
        .onReceive(NotificationCenter.default.publisher(for: .ttrOuvrirSessionExistante)) { _ in
            openExistingSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ttrOuvrirReglages)) { _ in
            openSettings()
        }
    }

    private var contenu: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            dropZone

            if let audioURL {
                LecteurAudio(url: audioURL)
            }

            DisclosureGroup("Contexte (optionnel)") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sujet, participants, organismes, termes techniques — améliore la reconnaissance des noms propres et sert de base au résumé.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $contextText)
                        .font(.callout)
                        .frame(height: 70)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .padding(.top, 4)
            }
            .font(.caption)

            HStack {
                Picker("Modèle", selection: $settings.defaultModel) {
                    ForEach(AppSettings.models, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .frame(width: 220)

                TextField("Nb de locuteurs (optionnel)", text: $numSpeakersText)
                    .frame(width: 220)
                    .textFieldStyle(.roundedBorder)

                Spacer()

                Button(runner.state == .running ? "En cours…" : "Transcrire") {
                    startRun()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(audioURL == nil || runner.state == .running || settings.hfToken.isEmpty)

                if runner.state == .running {
                    Button("Interrompre") {
                        runner.cancel()
                    }
                    .tint(.red)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Arrête le traitement en cours sans quitter l'application (⌘.). "
                          + "La transcription déjà calculée est conservée : une relance sur le même "
                          + "fichier reprendra à la diarisation plutôt que de tout refaire.")
                }
            }

            if settings.hfToken.isEmpty {
                Label("Aucun token Hugging Face configuré — ouvrez les Réglages (⌘,).", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            if let resumeBanner {
                Label(resumeBanner, systemImage: "arrow.clockwise.circle")
                    .foregroundStyle(.blue)
                    .font(.callout)
            }

            if runner.state == .running {
                progressView
            }

            journalSection

            if case .finished(let success) = runner.state {
                resultBanner(success: success)
            }

            if case .finished(true) = runner.state, let audioURL, let outputFolder = runner.outputFolder {
                summarySection(audioURL: audioURL, outputFolder: outputFolder)
            }

        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // Le gestionnaire de file par lots est partagé au niveau de
            // l'app (voir TranscriptionTableRondeApp.swift) : la reprise
            // automatique après plantage/fermeture doit donc être déclenchée
            // ici, à l'ouverture de la fenêtre principale — toujours
            // présente au lancement —, plutôt que de dépendre de
            // l'ouverture de la fenêtre "Traitement par lots".
            batchQueue.resumeIfNeeded(settings: settings)
            restoreSingleSession()
        }
        .onChange(of: audioURL) { _, _ in persistSession(status: currentStatus()) }
        .onChange(of: numSpeakersText) { _, _ in persistSession(status: currentStatus()) }
        .onChange(of: contextText) { _, _ in persistSession(status: currentStatus()) }
        .onChange(of: categoriesText) { _, _ in persistSession(status: currentStatus()) }
        .onChange(of: runner.state) { _, _ in persistSession(status: currentStatus()) }
        .alert("Session introuvable", isPresented: Binding(
            get: { sessionError != nil },
            set: { if !$0 { sessionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sessionError ?? "")
        }
        .toolbar {
            // Deux mécanismes, parce que le premier a échoué deux fois.
            //
            // `.help` sur un bouton de barre d'outils n'a produit aucune
            // infobulle, ni sur une Image nue ni sur un Label masqué. Plutôt
            // que de continuer à deviner, l'infobulle est maintenant posée
            // directement sur une vue AppKit — là, c'est le système qui
            // l'affiche, et son comportement est connu.
            //
            // Et le titre devient visible à côté de l'icône. Une infobulle
            // qui ne s'affiche pas n'est pas une fonctionnalité ; un libellé
            // qu'on lit sans survoler ne peut pas, lui, ne pas marcher.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openBatchQueueWindow()
                } label: {
                    Label("Lots", systemImage: "tray.full")
                }
                .infobulle("Traitement par lots (⇧⌘L) : transcrire tout un dossier "
                           + "d'enregistrements à la suite.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openExistingSession()
                } label: {
                    Label("Ouvrir", systemImage: "clock.arrow.circlepath")
                }
                .infobulle("Ouvrir une session déjà traitée (⌘O) : son dossier « sortie_… », "
                           + "un fichier qu'il contient, ou l'enregistrement d'origine.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openSettings()
                } label: {
                    Label("Réglages", systemImage: "gearshape")
                }
                .infobulle("Réglages (⌘,) : dossiers de travail, emplacement du pipeline "
                           + "Python, interpréteur et token Hugging Face.")
            }
        }
    }

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let fraction = runner.progressFraction {
                ProgressView(value: fraction) {
                    Text(runner.progressLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView {
                    Text(runner.progressLabel.isEmpty ? "Démarrage…" : runner.progressLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .progressViewStyle(.linear)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription table ronde")
                    .font(.title2).bold()
                Text("Transcription et diarisation 100 % locales (mlx-whisper + pyannote)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            // Signatures institutionnelles, justifiées à droite (voir
            // AboutView.swift). C'est ce bandeau qui impose la largeur
            // minimale de la fenêtre, relevée en conséquence dans
            // TranscriptionTableRondeApp.swift.
            SignaturesView()
        }
    }

    private var dropZone: some View {
        let icon = audioURL == nil ? "waveform" : "checkmark.circle.fill"
        let iconColor: Color = audioURL == nil ? .secondary : .green
        let backgroundColor: Color = isTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor)
        let borderColor: Color = isTargeted ? Color.accentColor : Color.secondary.opacity(0.3)

        // Disposition horizontale et marges resserrées : la zone de dépôt
        // occupait près d'un quart de la fenêtre pour une information qui
        // tient sur une ligne, au détriment du journal et des réglages de
        // traitement, qui servent à chaque session.
        return HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(iconColor)
            Text(audioURL?.lastPathComponent ?? "Glissez un fichier .wav ou .mp3 ici, ou cliquez pour en choisir un")
                .font(.callout)
                .lineLimit(2)
                .foregroundStyle(audioURL == nil ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 1.5, dash: [6]))
        )
        .onTapGesture { chooseFile() }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    /// Journal replié par défaut, avec la dernière ligne en guise de
    /// résumé dans l'en-tête : refermé, il ne doit pas pour autant laisser
    /// croire que rien ne se passe. C'est ce qui le distingue d'un simple
    /// masquage.
    private var journalSection: some View {
        DisclosureGroup(isExpanded: $journalOuvert) {
            logView
        } label: {
            HStack(spacing: 8) {
                Text("Journal")
                if !journalOuvert, let derniere = runner.logLines.last {
                    Text(derniere)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .font(.caption)
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Spacer()
                Button("Copier le journal") {
                    copyLogToPasteboard()
                }
                .disabled(runner.logLines.isEmpty)
                .font(.caption)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(runner.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
                }
                .onChange(of: runner.logLines.count) { _, count in
                    guard count > 0 else { return }
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        // Hauteur définie, et non plus extensible : dans une page qui défile,
        // une hauteur infinie n'a pas de borne où s'arrêter. Le journal garde
        // son propre défilement interne et sa descente automatique sur la
        // dernière ligne — c'est elle qui montre que le traitement avance,
        // puis qu'il s'achève.
        .frame(height: 260)
        .padding(.top, 4)
    }

    private func resultBanner(success: Bool) -> some View {
        let interrompu = !success && runner.interrompu
        return HStack {
            Image(systemName: success ? "checkmark.circle.fill"
                  : (interrompu ? "stop.circle.fill" : "xmark.circle.fill"))
                .foregroundStyle(success ? .green : (interrompu ? .orange : .red))
            Text(success
                 ? "Terminé. Fichiers générés dans le dossier de sortie."
                 : (interrompu
                    ? "Traitement interrompu. Relancez pour reprendre : ce qui était déjà transcrit est conservé."
                    : "Le traitement a échoué — voir le journal ci-dessus."))
            Spacer()
            if success, let folder = runner.outputFolder {
                Button("Révéler dans le Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
        }
        .font(.callout)
    }

    private func summarySection(audioURL: URL, outputFolder: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            HStack {
                Button("Vérifier / corriger") {
                    openReviewWindow(audioURL: audioURL, outputFolder: outputFolder)
                }

                Button(summaryRunner.state == .running ? "Résumé en cours…" : "Générer le résumé structuré") {
                    generateSummary(audioURL: audioURL, outputFolder: outputFolder)
                }
                .disabled(summaryRunner.state == .running)

                if summaryRunner.state == .running {
                    Button("Interrompre") {
                        summaryRunner.cancel()
                    }
                    .tint(.red)
                    .help("Arrête la génération du résumé sans quitter l'application. "
                          + "Le transcript, lui, n'est pas touché.")
                }

                Text("Analyse locale via Ollama")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            DisclosureGroup("Catégories du résumé") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Une catégorie par ligne — adapte-les au type de réunion.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $categoriesText)
                        .font(.callout)
                        .frame(height: 100)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .padding(.top, 4)
            }
            .font(.caption)

            if summaryRunner.state != .idle {
                summaryLogView
            }

            if case .finished(let success) = summaryRunner.state {
                HStack {
                    Image(systemName: success ? "checkmark.circle.fill"
                          : (summaryRunner.interrompu ? "stop.circle.fill" : "xmark.circle.fill"))
                        .foregroundStyle(success ? .green : (summaryRunner.interrompu ? .orange : .red))
                    Text(success
                         ? "Résumé structuré généré."
                         : (summaryRunner.interrompu
                            ? "Génération du résumé interrompue."
                            : "Échec de la génération du résumé — voir le journal ci-dessus."))
                    Spacer()
                    if success, let md = summaryRunner.resumeMarkdownPath {
                        Button("Ouvrir le résumé") {
                            NSWorkspace.shared.open(md)
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    private var summaryLogView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(summaryRunner.logLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .textSelection(.enabled)
        }
        .frame(height: 100)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Recherche par motif plutôt que reconstruction exacte du chemin : le
    /// Finder (et d'autres apps) peuvent réencoder les caractères accentués
    /// différemment lors d'un déplacement de fichier (forme composée « é »
    /// vs décomposée « e + accent »), ce qui casse toute comparaison de
    /// chemin construit par interpolation de chaîne.
    private func findEntry(in folder: URL, matching predicate: (URL) -> Bool) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.first(where: predicate)
    }

    private func findFile(in folder: URL, suffix: String) -> URL? {
        findEntry(in: folder) { $0.lastPathComponent.hasSuffix(suffix) }
    }

    /// Restaure l'état de la fenêtre à partir de la dernière session
    /// enregistrée (voir `SingleSessionStore`) : fichier, contexte, nombre
    /// de locuteurs et catégories de résumé, sans que l'utilisateur ait à
    /// tout ressaisir après un redémarrage de l'app.
    ///
    /// - Si la session était terminée avec succès, retrouve directement le
    ///   dossier de sortie (comme `openExistingSession()`, mais
    ///   automatiquement, sans resélection manuelle du fichier).
    /// - Si elle était en cours (app quittée ou plantée en plein
    ///   traitement), affiche un message plutôt que de prétendre à tort que
    ///   le traitement est terminé : l'utilisateur relance lui-même avec
    ///   "Transcrire".
    private func restoreSingleSession() {
        guard let state = sessionStore.lastState else { return }
        audioURL = state.audioURL
        numSpeakersText = state.numSpeakersText
        contextText = state.contextText
        if !state.categoriesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            categoriesText = state.categoriesText
        }

        switch state.status {
        case .finished:
            if let outputFolder = state.outputFolder,
               findFile(in: outputFolder, suffix: "_transcript.json") != nil {
                runner.outputFolder = outputFolder
                runner.state = .finished(success: true)
            }
        case .running:
            interruptedRun = true
            resumeBanner = "Une transcription a été interrompue pour « \(state.audioURL?.lastPathComponent ?? "ce fichier") ». Relancez-la avec Transcrire."
        case .notStarted:
            break
        }
    }

    /// Statut courant à enregistrer, déduit de l'état du `runner` : un
    /// échec redevient "notStarted" (les champs restent conservés, mais on
    /// ne veut pas afficher au prochain lancement un message "session
    /// interrompue" pour un traitement qui a simplement échoué proprement).
    /// Une session interrompue non encore relancée (`interruptedRun`) reste
    /// marquée "running" tant que l'utilisateur n'a rien fait, pour que le
    /// message réapparaisse au lancement suivant.
    private func currentStatus() -> SingleSessionStatus {
        switch runner.state {
        case .running: return .running
        case .finished(let success): return success ? .finished : .notStarted
        default: return interruptedRun ? .running : .notStarted
        }
    }

    private func persistSession(status: SingleSessionStatus) {
        sessionStore.save(SingleSessionState(
            audioURL: audioURL,
            outputFolder: runner.outputFolder,
            numSpeakersText: numSpeakersText,
            contextText: contextText,
            categoriesText: categoriesText,
            status: status
        ))
    }

    /// Ouvre une session déjà transcrite et diarisée.
    ///
    /// Trois gestes sont acceptés, parce qu'aucun n'est plus naturel que
    /// les autres du point de vue de l'utilisateur : le dossier de sortie
    /// « sortie_… », n'importe quel fichier qu'il contient — y compris
    /// l'audio de relecture, confusion inévitable puisque c'est le seul
    /// fichier audio visible dans ce dossier —, ou l'enregistrement
    /// d'origine. Auparavant seul le dernier fonctionnait, et le sélecteur
    /// grisait tout le reste sans expliquer pourquoi.
    private func openExistingSession() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.message = "Choisissez un dossier « sortie_… », un fichier qu'il contient, ou l'enregistrement d'origine"
        panel.prompt = "Ouvrir la session"
        if !settings.recordingsFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: settings.recordingsFolder, isDirectory: true)
        }
        guard panel.runModal() == .OK, let selected = panel.url else { return }

        guard let dossierDeSortie = resoudreDossierDeSortie(depuis: selected) else {
            sessionError = "Aucune session trouvée à partir de « \(selected.lastPathComponent) ».\n\n"
                + "Choisissez le dossier « sortie_… » d'un enregistrement déjà transcrit, "
                + "un fichier qu'il contient, ou l'enregistrement audio d'origine."
            return
        }

        guard findFile(in: dossierDeSortie, suffix: "_transcript.json") != nil else {
            sessionError = "Le dossier « \(dossierDeSortie.lastPathComponent) » ne contient pas de transcript."
            return
        }

        chargerSession(dossierDeSortie: dossierDeSortie)
    }

    /// Retrouve le dossier de sortie à partir de ce que l'utilisateur a
    /// désigné, quel que soit son geste.
    private func resoudreDossierDeSortie(depuis selection: URL) -> URL? {
        // Un dossier contenant déjà un transcript : c'est lui.
        if selection.hasDirectoryPath, findFile(in: selection, suffix: "_transcript.json") != nil {
            return selection
        }
        // Un fichier pris dans un dossier de sortie : c'est son parent.
        if !selection.hasDirectoryPath {
            let parent = selection.deletingLastPathComponent()
            if findFile(in: parent, suffix: "_transcript.json") != nil {
                return parent
            }
        }
        // Un enregistrement d'origine : on cherche son dossier « sortie_… »,
        // dans le dossier de sauvegarde configuré puis à côté de l'audio.
        let basename = selection.deletingPathExtension().lastPathComponent
        let attendu = "sortie_\(basename)".precomposedStringWithCanonicalMapping
        let parentsCandidats = [
            settings.outputFolder(for: selection).deletingLastPathComponent(),
            selection.deletingLastPathComponent()
        ]
        return parentsCandidats.compactMap { parent in
            findEntry(in: parent, matching: {
                $0.hasDirectoryPath && $0.lastPathComponent.precomposedStringWithCanonicalMapping == attendu
            })
        }.first
    }

    /// Installe une session complète dans l'interface : l'audio, le
    /// contexte et l'état du traitement remplacent intégralement ceux de la
    /// session précédente, plutôt que de s'y superposer.
    private func chargerSession(dossierDeSortie: URL) {
        let basename = nomDeBase(dossierDeSortie: dossierDeSortie)

        let audio = audioDeLaSession(dossierDeSortie: dossierDeSortie, basename: basename)
        audioURL = audio
        runner.outputFolder = dossierDeSortie
        runner.state = .finished(success: true)
        resumerSession(dossierDeSortie: dossierDeSortie, audio: audio)

        if audio == nil {
            sessionError = "La session « \(dossierDeSortie.lastPathComponent) » est ouverte, "
                + "mais aucun fichier audio n'a été trouvé, ni dans ce dossier, ni à côté, "
                + "ni dans le dossier d'enregistrements. La vérification a besoin de l'audio : "
                + "replacez l'enregistrement dans le dossier de sortie, ou indiquez son "
                + "emplacement dans les Réglages."
        }

        if let contextFile = findFile(in: dossierDeSortie, suffix: "_contexte.txt"),
           let text = try? String(contentsOf: contextFile, encoding: .utf8) {
            contextText = text
        } else {
            contextText = ""
        }
        // Les catégories suivent le même chemin que le contexte. Absentes,
        // on remet la grille par défaut plutôt que de laisser celles de la
        // session précédente, qui n'ont rien à voir avec celle-ci.
        if let categoriesFile = findFile(in: dossierDeSortie, suffix: "_categories.txt"),
           let text = try? String(contentsOf: categoriesFile, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            categoriesText = text
        } else {
            categoriesText = ContentView.defaultCategoriesText
        }
        numSpeakersText = ""

        resumeBanner = nil
        interruptedRun = false
        persistSession(status: .finished)
    }

    /// Nom de base de la session, déduit du transcript plutôt que du nom du
    /// dossier : c'est le transcript qui fait foi pour retrouver les autres
    /// fichiers, même si le dossier a été renommé.
    private func nomDeBase(dossierDeSortie: URL) -> String {
        if let transcript = findFile(in: dossierDeSortie, suffix: "_transcript.json") {
            var nom = transcript.deletingPathExtension().lastPathComponent
            if nom.hasSuffix("_transcript") { nom.removeLast("_transcript".count) }
            return nom
        }
        var nom = dossierDeSortie.lastPathComponent
        if nom.hasPrefix("sortie_") { nom.removeFirst("sortie_".count) }
        return nom
    }

    /// Audio de la session : l'enregistrement d'origine s'il est encore là,
    /// sinon l'audio de relecture conservé dans le dossier de sortie. Ce
    /// dernier suffit à la vérification — c'est d'ailleurs celui que la
    /// fenêtre de correction lit en priorité —, ce qui permet d'ouvrir une
    /// session reçue d'un collègue sans l'enregistrement d'origine.
    /// Audio de la session, cherché dans cet ordre : le dossier de sortie
    /// lui-même, le dossier qui le contient, le dossier d'enregistrements
    /// configuré, puis, à défaut, l'audio de relecture.
    ///
    /// Le dossier de sortie vient en premier parce que c'est le cas le plus
    /// fréquent en pratique : on transcrit un enregistrement déjà rangé
    /// dans son propre dossier, et le WAV se retrouve à côté du transcript.
    /// C'était précisément le seul endroit où cette recherche n'allait pas
    /// voir, si bien que la session s'ouvrait sans son audio — et donc sans
    /// le bouton « Vérifier / corriger », qui en dépend.
    private func audioDeLaSession(dossierDeSortie: URL, basename: String) -> URL? {
        let extensionsAudio: Set<String> = ["wav", "mp3", "m4a", "aac", "aif", "aiff", "caf", "mp4"]
        let normalise = basename.precomposedStringWithCanonicalMapping

        let estAudio: (URL) -> Bool = { url in
            !url.hasDirectoryPath && extensionsAudio.contains(url.pathExtension.lowercased())
        }
        let estAudioDeRelecture: (URL) -> Bool = {
            $0.lastPathComponent.hasSuffix("_review_audio.wav")
        }
        let porteLeNom: (URL) -> Bool = { url in
            url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping == normalise
        }
        let correspond: (URL) -> Bool = { estAudio($0) && porteLeNom($0) }

        var dossiers = [dossierDeSortie, dossierDeSortie.deletingLastPathComponent()]
        if !settings.recordingsFolder.isEmpty {
            dossiers.append(URL(fileURLWithPath: settings.recordingsFolder, isDirectory: true))
        }
        for dossier in dossiers {
            if let audio = findEntry(in: dossier, matching: correspond) { return audio }
        }

        // Enregistrement renommé depuis la transcription : on prend le seul
        // autre audio du dossier, l'audio de relecture mis à part.
        if let audio = findEntry(in: dossierDeSortie, matching: { estAudio($0) && !estAudioDeRelecture($0) }) {
            return audio
        }
        return findFile(in: dossierDeSortie, suffix: "_review_audio.wav")
    }

    /// Récapitule dans le journal ce qui vient d'être chargé. Sans cela, le
    /// grand cadre central reste vide après l'ouverture d'une session et
    /// rien n'indique ce que l'application a réellement trouvé.
    private func resumerSession(dossierDeSortie: URL, audio: URL?) {
        var lignes = ["Session ouverte : \(dossierDeSortie.lastPathComponent)"]

        if let transcript = findFile(in: dossierDeSortie, suffix: "_transcript.json"),
           let data = try? Data(contentsOf: transcript),
           let segments = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let locuteurs = Set(segments.compactMap { $0["speaker"] as? String })
            lignes.append("\(segments.count) segment(s), \(locuteurs.count) locuteur(s)")
        }

        lignes.append("Audio : \(audio?.lastPathComponent ?? "introuvable")")

        let connus: [(String, String)] = [
            ("_transcript.json", "transcript"),
            ("_transcript.txt", "transcript lisible"),
            ("_final.txt", "version corrigée"),
            ("_speakers.json", "fiche locuteurs"),
            ("_whisper_raw.json", "cache de transcription"),
            ("_contexte.txt", "contexte"),
            ("_categories.txt", "catégories du résumé"),
            ("_review_audio.wav", "audio de relecture"),
        ]
        let presents = connus.filter { findFile(in: dossierDeSortie, suffix: $0.0) != nil }
        if !presents.isEmpty {
            lignes.append("Fichiers : " + presents.map { $0.1 }.joined(separator: ", "))
        }

        if audio == nil {
            lignes.append("Aucun audio trouvé : la vérification et la relecture sont indisponibles.")
        } else {
            lignes.append("« Vérifier / corriger » reprend les corrections là où elles en sont.")
        }

        runner.logLines = lignes
    }

    /// Ramène la fenêtre "Traitement par lots" au premier plan si elle est
    /// déjà ouverte, plutôt que d'en ouvrir une deuxième (un clic répété ou
    /// accidentel sur l'icône ne doit jamais dupliquer la fenêtre — même si
    /// le gestionnaire de file est désormais partagé, deux fenêtres
    /// identiques n'ont aucune utilité et prêtent à confusion).
    private func openBatchQueueWindow() {
        if let existing = NSApp.windows.first(where: { $0.title == "Traitement par lots" }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openWindow(id: "batchQueue")
        }
    }

    private func openReviewWindow(audioURL: URL, outputFolder: URL) {
        guard let transcriptPath = findFile(in: outputFolder, suffix: "_transcript.json") else {
            sessionError = "Transcript introuvable dans « \(outputFolder.lastPathComponent) »."
            return
        }
        openWindow(id: "review", value: ReviewTarget(transcriptURL: transcriptPath, audioURL: audioURL))
    }

    private func generateSummary(audioURL: URL, outputFolder: URL) {
        guard let input = findFile(in: outputFolder, suffix: "_final.txt")
            ?? findFile(in: outputFolder, suffix: "_transcript.json") else {
            sessionError = "Transcript introuvable dans « \(outputFolder.lastPathComponent) »."
            return
        }
        // Réécrit avant chaque résumé : les catégories sont souvent ajustées
        // après la transcription, et le dossier doit refléter celles qui ont
        // réellement produit le résumé qu'il contient.
        ecrireFichiersDeSession(dans: outputFolder, pour: audioURL)
        summaryRunner.run(transcriptPath: input, settings: settings, categoriesArgument: categoriesArgument(from: categoriesText), context: contextText)
    }

    /// Construit l'argument --categories de summarize.py ("slug:Titre;...")
    /// à partir des titres tapés par l'utilisateur (un par ligne).
    private func categoriesArgument(from text: String) -> String {
        text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "\(slugify($0)):\($0)" }
            .joined(separator: ";")
    }

    private func slugify(_ text: String) -> String {
        let folded = text.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        var slug = String(folded.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        while slug.contains("__") { slug = slug.replacingOccurrences(of: "__", with: "_") }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private func copyLogToPasteboard() {
        let text = runner.logLines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if !settings.recordingsFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: settings.recordingsFolder, isDirectory: true)
        }
        if panel.runModal() == .OK {
            audioURL = panel.url
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async {
                audioURL = url
            }
        }
        return true
    }

    private func startRun() {
        guard let audioURL else { return }
        resumeBanner = nil
        interruptedRun = false
        let numSpeakers = Int(numSpeakersText.trimmingCharacters(in: .whitespaces))
        let outputFolder = settings.outputFolder(for: audioURL)
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        ecrireFichiersDeSession(dans: outputFolder, pour: audioURL)
        runner.run(audioURL: audioURL, settings: settings, numSpeakers: numSpeakers, outputFolder: outputFolder, context: contextText)
    }

    /// Écrit le contexte et les catégories à côté des résultats, en texte brut.
    ///
    /// Ces deux réglages appartiennent à la session, pas à l'application : ils
    /// décrivent CETTE réunion — ses participants, ses sigles, les rubriques
    /// qu'on veut en tirer. Les garder dans les préférences de l'app faisait
    /// qu'ouvrir une autre session montrait le contexte de la précédente, et
    /// qu'un dossier de résultats transmis à quelqu'un d'autre arrivait sans
    /// ce qui permet de le relire. En fichiers texte, ils voyagent avec le
    /// dossier et s'éditent sans l'application.
    private func ecrireFichiersDeSession(dans dossier: URL, pour audioURL: URL) {
        let basename = audioURL.deletingPathExtension().lastPathComponent
        let aEcrire: [(String, String)] = [
            ("_contexte.txt", contextText),
            ("_categories.txt", categoriesText),
        ]
        for (suffixe, contenu) in aEcrire {
            let url = dossier.appendingPathComponent("\(basename)\(suffixe)")
            let propre = contenu.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !propre.isEmpty else { continue }
            try? (propre + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}


/// Actions de la fenêtre principale déclenchables depuis le menu.
///
/// Passer par une notification plutôt que par un état partagé : ces actions
/// vivent dans ContentView (elles manipulent son état de session), alors que
/// les menus sont déclarés au niveau de l'application. Une notification est
/// le chemin le plus court entre les deux, sans faire remonter de l'état qui
/// n'a aucune raison de quitter la vue.
extension Notification.Name {
    static let ttrOuvrirSessionExistante = Notification.Name("ttrOuvrirSessionExistante")
    static let ttrOuvrirReglages = Notification.Name("ttrOuvrirReglages")
}


/// Lecteur de vérification du fichier chargé.
///
/// Son objet n'est pas l'écoute de travail — celle-là se fait dans la
/// fenêtre de vérification, où le texte accompagne le son — mais le
/// contrôle qu'on a bien chargé ce qu'on croit, avant d'engager une heure
/// de calcul.
///
/// D'où la ligne de caractéristiques à côté des commandes : c'est elle qui
/// attrape les erreurs que l'oreille ne relève pas tout de suite. Un
/// enregistrement tronqué se voit à sa durée, un fichier de secours en
/// 8 kHz téléphonique se voit à sa fréquence d'échantillonnage — et ce
/// dernier dégraderait la transcription sans qu'on comprenne pourquoi, des
/// heures plus tard, en relisant un texte médiocre.
struct LecteurAudio: View {
    let url: URL

    @State private var lecteur: AVPlayer?
    @State private var observateur: Any?
    @State private var enLecture = false
    @State private var instant: Double = 0
    @State private var duree: Double = 0
    @State private var caracteristiques: String?
    @State private var avertissement: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Button {
                    basculer()
                } label: {
                    Image(systemName: enLecture ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .disabled(lecteur == nil)
                .help(enLecture ? "Pause" : "Écouter le fichier chargé, pour vérifier que c'est le bon")

                Slider(value: Binding(get: { instant }, set: { deplacer(vers: $0) }),
                       in: 0...max(duree, 0.01))
                    .disabled(lecteur == nil || duree <= 0)

                Text("\(horodatage(instant)) / \(horodatage(duree))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                if let caracteristiques {
                    Text(caracteristiques)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let avertissement {
                    Label(avertissement, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
        }
        // .task(id:) et non .onAppear : la vue est réutilisée quand on
        // change de fichier sans fermer la fenêtre, et un .onAppear ne
        // serait alors jamais rappelé — on écouterait le fichier précédent.
        .task(id: url) { await preparer() }
        .onDisappear { liberer() }
    }

    private func preparer() async {
        liberer()
        let asset = AVURLAsset(url: url)

        var secondes: Double = 0
        if let chargee = try? await asset.load(.duration) {
            let valeur = chargee.seconds
            secondes = (valeur.isFinite && valeur > 0) ? valeur : 0
        }

        var frequence: Double?
        var canaux: UInt32?
        if let pistes = try? await asset.loadTracks(withMediaType: .audio),
           let piste = pistes.first,
           let descriptions = try? await piste.load(.formatDescriptions),
           let description = descriptions.first,
           let base = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            frequence = base.mSampleRate
            canaux = base.mChannelsPerFrame
        }

        let joueur = AVPlayer(url: url)
        let observation = joueur.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { temps in
            instant = temps.seconds.isFinite ? temps.seconds : 0
        }

        await MainActor.run {
            duree = secondes
            lecteur = joueur
            observateur = observation
            instant = 0
            enLecture = false
            caracteristiques = Self.descriptionDuFichier(
                url: url, duree: secondes, frequence: frequence, canaux: canaux)
            avertissement = Self.avertissement(frequence: frequence, duree: secondes)
        }
    }

    /// Ligne « WAV · 48 kHz · stéréo · 1 h 47 », amputée de ce qu'on n'a pas
    /// pu lire plutôt que remplie de « inconnu », qui n'apprendrait rien.
    private static func descriptionDuFichier(url: URL, duree: Double,
                                             frequence: Double?, canaux: UInt32?) -> String {
        var morceaux = [url.pathExtension.uppercased()]
        if let frequence, frequence > 0 {
            morceaux.append(String(format: "%.1f kHz", frequence / 1000)
                .replacingOccurrences(of: ".0 kHz", with: " kHz"))
        }
        if let canaux {
            switch canaux {
            case 1: morceaux.append("mono")
            case 2: morceaux.append("stéréo")
            default: morceaux.append("\(canaux) canaux")
            }
        }
        if duree > 0 {
            morceaux.append(dureeLisible(duree))
        }
        return morceaux.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func avertissement(frequence: Double?, duree: Double) -> String? {
        if duree <= 0 {
            return "Durée illisible : le fichier est peut-être tronqué ou incomplet."
        }
        // 16 kHz est ce que réclame le pipeline ; en dessous, la bande
        // passante manquante ne se rattrape pas et la transcription s'en
        // ressentira sur tout le fichier.
        if let frequence, frequence > 0, frequence < 16000 {
            return "Échantillonné sous 16 kHz : la transcription sera nettement moins fiable."
        }
        return nil
    }

    private static func dureeLisible(_ secondes: Double) -> String {
        let total = Int(secondes.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h) h \(String(format: "%02d", m))" }
        if m > 0 { return "\(m) min \(String(format: "%02d", s)) s" }
        return "\(s) s"
    }

    private func horodatage(_ secondes: Double) -> String {
        guard secondes.isFinite, secondes >= 0 else { return "00:00" }
        let total = Int(secondes)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private func basculer() {
        guard let lecteur else { return }
        if enLecture {
            lecteur.pause()
        } else {
            lecteur.play()
        }
        enLecture.toggle()
    }

    private func deplacer(vers secondes: Double) {
        instant = secondes
        lecteur?.seek(to: CMTime(seconds: secondes, preferredTimescale: 600),
                      toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// L'observateur doit être retiré avant de lâcher le lecteur : sans
    /// cela il continue d'écrire dans `instant`, et deux fichiers chargés
    /// l'un après l'autre se disputent la barre de progression.
    private func liberer() {
        if let observateur { lecteur?.removeTimeObserver(observateur) }
        observateur = nil
        lecteur?.pause()
        lecteur = nil
        enLecture = false
        instant = 0
    }
}


/// Infobulle posée par AppKit plutôt que par SwiftUI.
///
/// `.help()` est le moyen normal, et il fonctionne bien dans le corps d'une
/// fenêtre. Dans une barre d'outils, sur cette version de macOS, il n'a rien
/// produit — ni sur une Image, ni sur un Label. On redescend donc d'un
/// étage : une vue AppKit transparente est posée derrière le bouton, et c'est
/// elle qui porte le `toolTip`. L'affichage devient l'affaire du système, qui
/// sait le faire depuis toujours.
///
/// La vue est placée en arrière-plan et non en superposition, pour qu'elle
/// n'intercepte jamais le clic : le bouton reste devant, elle ne fait
/// qu'occuper la même surface.
private struct Infobulle: NSViewRepresentable {
    let texte: String

    func makeNSView(context: Context) -> NSView {
        let vue = NSView()
        vue.toolTip = texte
        return vue
    }

    func updateNSView(_ vue: NSView, context: Context) {
        vue.toolTip = texte
    }
}

extension View {
    /// Associe une infobulle à cette vue, par AppKit, et conserve `.help`
    /// pour l'accessibilité et pour le jour où SwiftUI s'en chargera.
    func infobulle(_ texte: String) -> some View {
        background(Infobulle(texte: texte))
            .help(texte)
    }
}

