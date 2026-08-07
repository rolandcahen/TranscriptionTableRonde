import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var batchQueue: BatchQueueManager
    @StateObject private var runner = PipelineRunner()
    @StateObject private var summaryRunner = SummaryRunner()
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    @State private var audioURL: URL?
    @State private var numSpeakersText: String = ""
    @State private var isTargeted = false
    @State private var sessionError: String?
    @State private var categoriesText: String = ContentView.defaultCategoriesText
    @State private var contextText: String = ""

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
        VStack(alignment: .leading, spacing: 16) {
            header
            dropZone

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
            }

            if settings.hfToken.isEmpty {
                Label("Aucun token Hugging Face configuré — ouvrez les Réglages (⌘,).", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            if runner.state == .running {
                progressView
            }

            logView

            if case .finished(let success) = runner.state {
                resultBanner(success: success)
            }

            if case .finished(true) = runner.state, let audioURL, let outputFolder = runner.outputFolder {
                summarySection(audioURL: audioURL, outputFolder: outputFolder)
            }
        }
        .padding(20)
        .onAppear {
            // Le gestionnaire de file par lots est partagé au niveau de
            // l'app (voir TranscriptionTableRondeApp.swift) : la reprise
            // automatique après plantage/fermeture doit donc être déclenchée
            // ici, à l'ouverture de la fenêtre principale — toujours
            // présente au lancement —, plutôt que de dépendre de
            // l'ouverture de la fenêtre "Traitement par lots".
            batchQueue.resumeIfNeeded(settings: settings)
        }
        .alert("Session introuvable", isPresented: Binding(
            get: { sessionError != nil },
            set: { if !$0 { sessionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sessionError ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openBatchQueueWindow()
                } label: {
                    Image(systemName: "tray.full")
                }
                .help("Traitement par lots (dossier entier)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openExistingSession()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("Ouvrir une session déjà traitée (sans refaire la transcription)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Transcription table ronde")
                .font(.title2).bold()
            Text("Transcription et diarisation 100 % locales (mlx-whisper + pyannote)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var dropZone: some View {
        let icon = audioURL == nil ? "waveform" : "checkmark.circle.fill"
        let iconColor: Color = audioURL == nil ? .secondary : .green
        let backgroundColor: Color = isTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor)
        let borderColor: Color = isTargeted ? Color.accentColor : Color.secondary.opacity(0.3)

        return VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(iconColor)
            Text(audioURL?.lastPathComponent ?? "Glissez un fichier .wav ou .mp3 ici, ou cliquez pour en choisir un")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
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
        .frame(minHeight: 220)
    }

    private func resultBanner(success: Bool) -> some View {
        HStack {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(success ? .green : .red)
            Text(success ? "Terminé. Fichiers générés dans le dossier de sortie." : "Le traitement a échoué — voir le journal ci-dessus.")
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

                Text("Analyse locale via Ollama + Mistral")
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
                    Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(success ? .green : .red)
                    Text(success ? "Résumé structuré généré." : "Échec de la génération du résumé — voir le journal ci-dessus.")
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

    private func openExistingSession() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choisissez le fichier audio d'une session déjà traitée"
        guard panel.runModal() == .OK, let selected = panel.url else { return }

        let parent = selected.deletingLastPathComponent()
        let basename = selected.deletingPathExtension().lastPathComponent
        let expectedFolderName = "sortie_\(basename)".precomposedStringWithCanonicalMapping

        guard let outputFolder = findEntry(in: parent, matching: {
            $0.hasDirectoryPath && $0.lastPathComponent.precomposedStringWithCanonicalMapping == expectedFolderName
        }) else {
            sessionError = "Aucun dossier de sortie trouvé pour ce fichier.\nAttendu : « sortie_\(basename) » à côté de l'audio."
            return
        }

        guard findFile(in: outputFolder, suffix: "_transcript.json") != nil else {
            sessionError = "Le dossier « \(outputFolder.lastPathComponent) » ne contient pas de transcript."
            return
        }

        audioURL = selected
        runner.logLines = []
        runner.outputFolder = outputFolder
        runner.state = .finished(success: true)

        if let contextFile = findFile(in: outputFolder, suffix: "_contexte.txt"),
           let text = try? String(contentsOf: contextFile, encoding: .utf8) {
            contextText = text
        }
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
        let numSpeakers = Int(numSpeakersText.trimmingCharacters(in: .whitespaces))
        let outputFolder = audioURL.deletingLastPathComponent()
            .appendingPathComponent("sortie_\(audioURL.deletingPathExtension().lastPathComponent)")
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        runner.run(audioURL: audioURL, settings: settings, numSpeakers: numSpeakers, outputFolder: outputFolder, context: contextText)
    }
}
