import SwiftUI
import AVFoundation
import NaturalLanguage

/// Identifie une fenêtre de vérification : le transcript JSON à corriger et
/// le fichier audio original correspondant (pour la lecture).
struct ReviewTarget: Codable, Hashable {
    let transcriptURL: URL
    let audioURL: URL
}

/// Vue-modèle éditable d'un segment. `raw` conserve les champs du JSON
/// d'origine (id, seek, tokens, temperature, compression_ratio, ...) non
/// gérés par l'éditeur, pour ne rien perdre à la réécriture. Vide pour un
/// segment ajouté manuellement.
private struct EditableSegment: Identifiable {
    let id = UUID()
    var start: Double
    var end: Double
    var text: String
    var speakerID: String
    var avgLogprob: Double
    var noSpeechProb: Double
    var raw: [String: Any]
}

private struct SpeakerSummary: Identifiable {
    var id: String { speakerID }
    let speakerID: String
    let count: Int
    let totalDuration: Double
    let preview: String
}

struct ReviewView: View {
    let target: ReviewTarget

    @State private var segments: [EditableSegment] = []
    @State private var speakerNames: [String: String] = [:]
    @State private var loadError: String?
    @State private var saveMessage: String?
    // Locuteurs créés manuellement (ex. personne oubliée par la diarisation
    // automatique) : pas encore affectés à un segment, donc absents de
    // `segments` — suivis à part pour rester sélectionnables dans les menus
    // tant qu'aucun segment ne leur est attribué.
    @State private var manualSpeakerIDs: [String] = []
    @State private var nextManualSpeakerNumber = 1
    @State private var speakersExpanded = true
    // Noms de personnes détectés dans le fichier de contexte du fichier
    // (`<basename>_contexte.txt`), proposés en un clic pour renommer les
    // locuteurs plutôt que de les retaper.
    @State private var contextNameCandidates: [String] = []

    // Lecteur audio partagé (un seul, piloté par la barre de défilement et
    // les boutons play/pause/stop, plutôt qu'un lecteur par segment).
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var timeObserver: Any?
    @State private var isPreparingAudio = false
    @State private var audioPrepWarning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            playerBar

            if let loadError {
                Text(loadError)
                    .foregroundStyle(.red)
                    .padding()
            } else {
                DisclosureGroup(isExpanded: $speakersExpanded) {
                    speakerHeader
                } label: {
                    Text("Locuteurs (\(speakerSummaries.count))")
                        .font(.subheadline).bold()
                }
                segmentList
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 560)
        .navigationTitle("Vérification — \(target.audioURL.lastPathComponent)")
        .onAppear {
            load()
            setupPlayer()
            loadContextNameCandidates()
        }
        .onDisappear {
            if let timeObserver { player?.removeTimeObserver(timeObserver) }
            player?.pause()
        }
    }

    // MARK: - En-tête

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Vérification — \(target.audioURL.lastPathComponent)")
                    .font(.title3).bold()
                Text("\(segments.count) segment(s) · \(flaggedCount) signalé(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Plusieurs locuteurs dans un même segment : tapez « \(Self.speakerSplitMarker) » dans le texte au changement de locuteur, puis ✂️ pour diviser.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                addManualSpeaker()
            } label: {
                Label("Ajouter un locuteur", systemImage: "person.badge.plus")
            }
            Button {
                addSegment()
            } label: {
                Label("Ajouter un segment", systemImage: "plus")
            }
            Button("Enregistrer") {
                save()
            }
            .keyboardShortcut("s", modifiers: .command)
        }
        .overlay(alignment: .bottom) {
            if let saveMessage {
                Text(saveMessage)
                    .font(.caption)
                    .foregroundStyle(.green)
                    .offset(y: 20)
            }
        }
    }

    // MARK: - Lecteur audio (standard : barre de défilement + play/pause/stop)

    private var playerBar: some View {
        VStack(spacing: 4) {
            if isPreparingAudio {
                Label("Préparation de l'audio pour un alignement précis avec le texte…", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let audioPrepWarning {
                Label(audioPrepWarning, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Slider(
                value: Binding(get: { currentTime }, set: { currentTime = $0 }),
                in: 0...max(duration, 0.01),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing { seek(to: currentTime) }
                }
            )
            .disabled(isPreparingAudio)
            HStack(spacing: 12) {
                Button {
                    player?.play()
                    isPlaying = true
                } label: {
                    Image(systemName: "play.fill")
                }
                Button {
                    player?.pause()
                    isPlaying = false
                } label: {
                    Image(systemName: "pause.fill")
                }
                Button {
                    player?.pause()
                    isPlaying = false
                    seek(to: 0)
                } label: {
                    Image(systemName: "stop.fill")
                }
                Text("\(formatTimestamp(currentTime)) / \(formatTimestamp(duration))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .disabled(isPreparingAudio)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Correspondance locuteurs

    private var speakerHeader: some View {
        // Défilement interne avec hauteur plafonnée : au-delà de 4-5
        // locuteurs, la liste ne doit jamais empiéter sur celle des
        // segments — replier via le triangle du DisclosureGroup libère
        // encore plus de place si besoin.
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                speakerRows
            }
        }
        .frame(maxHeight: 180)
        .padding(.bottom, 4)
    }

    private var speakerRows: some View {
        ForEach(speakerSummaries) { summary in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(summary.speakerID).font(.caption).foregroundStyle(.secondary)
                            Text("→")
                            TextField("Nom", text: binding(forSpeaker: summary.speakerID))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                            if !contextNameCandidates.isEmpty {
                                Menu {
                                    ForEach(contextNameCandidates, id: \.self) { name in
                                        Button(name) {
                                            speakerNames[summary.speakerID] = name
                                        }
                                    }
                                } label: {
                                    Image(systemName: "person.fill.questionmark")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("Noms détectés dans le contexte de ce fichier — cliquer pour attribuer sans retaper.")
                            }
                        }
                        Text(summary.count == 0
                             ? "Aucun segment — pas encore utilisé"
                             : "\(summary.count) intervention(s) · \(formatTimestamp(summary.totalDuration)) de parole")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if !summary.preview.isEmpty {
                            Text("« \(summary.preview)… »")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Menu {
                        ForEach(mergeTargets(excluding: summary.speakerID), id: \.self) { target in
                            Button(displayName(for: target)) {
                                mergeSpeaker(summary.speakerID, into: target)
                            }
                        }
                    } label: {
                        Label("Fusionner / supprimer", systemImage: "person.crop.circle.badge.minus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Réattribue tous les segments de ce locuteur à un autre, puis le retire de la liste.")
                }
        }
    }

    /// Cibles possibles pour fusionner/supprimer un locuteur : tous les
    /// autres locuteurs déjà connus, plus "INCONNU" toujours proposé même
    /// si aucun segment ne l'utilise encore (pour marquer "sans locuteur
    /// identifié" plutôt que fusionner avec une vraie personne).
    private func mergeTargets(excluding speakerID: String) -> [String] {
        var targets = allSpeakerIDs.filter { $0 != speakerID }
        if !targets.contains("INCONNU") { targets.append("INCONNU") }
        return targets.sorted()
    }

    /// Réattribue tous les segments de `speakerID` vers `target`, puis
    /// retire `speakerID` de la liste (des locuteurs manuels s'il en
    /// faisait partie ; sinon il disparaît naturellement puisque plus aucun
    /// segment ne le référence).
    private func mergeSpeaker(_ speakerID: String, into target: String) {
        for index in segments.indices where segments[index].speakerID == speakerID {
            segments[index].speakerID = target
        }
        manualSpeakerIDs.removeAll { $0 == speakerID }
        speakerNames.removeValue(forKey: speakerID)
    }

    private func addManualSpeaker() {
        var candidate: String
        repeat {
            candidate = "SPEAKER_MANUEL_\(nextManualSpeakerNumber)"
            nextManualSpeakerNumber += 1
        } while allSpeakerIDs.contains(candidate)
        manualSpeakerIDs.append(candidate)
    }

    private var speakerSummaries: [SpeakerSummary] {
        let grouped = Dictionary(grouping: segments, by: \.speakerID)
        var summaries = grouped.map { speakerID, segs -> SpeakerSummary in
            let sorted = segs.sorted { $0.start < $1.start }
            let preview = sorted.first?.text.prefix(90).trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let total = segs.reduce(0.0) { $0 + ($1.end - $1.start) }
            return SpeakerSummary(speakerID: speakerID, count: segs.count, totalDuration: total, preview: String(preview))
        }
        for manualID in manualSpeakerIDs where !grouped.keys.contains(manualID) {
            summaries.append(SpeakerSummary(speakerID: manualID, count: 0, totalDuration: 0, preview: ""))
        }
        return summaries.sorted { $0.speakerID < $1.speakerID }
    }

    private var allSpeakerIDs: [String] {
        Array(Set(segments.map(\.speakerID)).union(manualSpeakerIDs)).sorted()
    }

    private func binding(forSpeaker id: String) -> Binding<String> {
        Binding(get: { speakerNames[id] ?? "" }, set: { speakerNames[id] = $0 })
    }

    private func displayName(for speakerID: String) -> String {
        let name = speakerNames[speakerID]?.trimmingCharacters(in: .whitespaces)
        return (name?.isEmpty == false) ? name! : speakerID
    }

    // MARK: - Liste des segments

    private var currentSegmentID: UUID? {
        segments.first(where: { currentTime >= $0.start && currentTime < $0.end })?.id
    }

    private var segmentList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach($segments) { $segment in
                        segmentRow($segment, isCurrent: segment.id == currentSegmentID)
                            .id(segment.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: currentSegmentID) { _, newValue in
                guard isPlaying, let newValue else { return }
                withAnimation { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
    }

    private func segmentRow(_ segment: Binding<EditableSegment>, isCurrent: Bool) -> some View {
        let s = segment.wrappedValue
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    seek(to: s.start)
                    player?.play()
                    isPlaying = true
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.plain)

                TextField("début", text: timestampBinding(segment.start))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 64)
                Text("-").foregroundStyle(.secondary)
                TextField("fin", text: timestampBinding(segment.end))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 64)

                Picker("", selection: segment.speakerID) {
                    ForEach(allSpeakerIDs, id: \.self) { id in
                        Text(displayName(for: id)).tag(id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)

                if isFlagged(s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(flagReason(s))
                }
                Spacer()
                if s.text.contains(Self.speakerSplitMarker) {
                    Button {
                        splitSegment(s.id)
                    } label: {
                        Image(systemName: "scissors")
                    }
                    .buttonStyle(.plain)
                    .help("Diviser ce segment à chaque « \(Self.speakerSplitMarker) » — répartition du temps proportionnelle à la longueur du texte de chaque partie.")
                }
                Button {
                    deleteSegment(s.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }

            TextEditor(text: segment.text)
                .font(.system(.body))
                .frame(minHeight: 40)
                .padding(4)
                .background(confidenceColor(s.avgLogprob))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(8)
        .background(isCurrent ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func timestampBinding(_ value: Binding<Double>) -> Binding<String> {
        Binding(
            get: { formatTimestamp(value.wrappedValue) },
            set: { newText in
                if let parsed = parseTimestamp(newText) {
                    value.wrappedValue = parsed
                }
            }
        )
    }

    private func parseTimestamp(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    // MARK: - Ajout / suppression de segments

    private func addSegment() {
        let speaker = allSpeakerIDs.first ?? "SPEAKER_00"
        let newSegment = EditableSegment(
            start: currentTime,
            end: currentTime + 2,
            text: "",
            speakerID: speaker,
            avgLogprob: 0,
            noSpeechProb: 0,
            raw: [:]
        )
        segments.append(newSegment)
    }

    private func deleteSegment(_ id: UUID) {
        segments.removeAll { $0.id == id }
    }

    // MARK: - Division au marqueur de locuteur

    /// Marqueur tapé directement dans le texte à l'endroit d'un changement
    /// de locuteur — évite de devoir repérer l'instant exact à l'écoute.
    static let speakerSplitMarker = "|"

    /// Découpe le texte du segment à chaque marqueur, répartit la durée
    /// entre les morceaux au prorata de leur longueur de texte (approximatif
    /// mais un bon point de départ — les horodatages restent éditables
    /// ensuite), et remplace le segment d'origine par autant de segments que
    /// de morceaux non vides. Tous héritent du même locuteur au départ : à
    /// réattribuer ensuite via le menu de chaque nouveau segment.
    private func splitSegment(_ id: UUID) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        let original = segments[index]
        let parts = original.text
            .components(separatedBy: Self.speakerSplitMarker)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count > 1 else { return }

        let totalChars = parts.reduce(0) { $0 + $1.count }
        guard totalChars > 0 else { return }

        let duration = original.end - original.start
        var cursor = original.start
        var newSegments: [EditableSegment] = []
        for (i, part) in parts.enumerated() {
            let isLast = i == parts.count - 1
            let share = duration * Double(part.count) / Double(totalChars)
            let end = isLast ? original.end : cursor + share
            newSegments.append(
                EditableSegment(
                    start: cursor,
                    end: end,
                    text: part,
                    speakerID: original.speakerID,
                    avgLogprob: original.avgLogprob,
                    noSpeechProb: original.noSpeechProb,
                    raw: original.raw
                )
            )
            cursor = end
        }
        segments.replaceSubrange(index...index, with: newSegments)
    }

    // MARK: - Confiance et signaux heuristiques

    private func confidenceColor(_ avgLogprob: Double) -> Color {
        if avgLogprob > -0.3 { return Color.green.opacity(0.12) }
        if avgLogprob > -0.8 { return Color.orange.opacity(0.12) }
        return Color.red.opacity(0.14)
    }

    private func hasRepeatedWords(_ text: String) -> Bool {
        let words = text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard words.count > 1 else { return false }
        for i in 1..<words.count where words[i] == words[i - 1] {
            return true
        }
        return false
    }

    private func isFlagged(_ segment: EditableSegment) -> Bool {
        let duration = segment.end - segment.start
        return segment.avgLogprob <= -0.8
            || segment.noSpeechProb > 0.6
            || hasRepeatedWords(segment.text)
            || duration > 30
            || (duration < 0.3 && !segment.text.isEmpty)
    }

    private func flagReason(_ segment: EditableSegment) -> String {
        var reasons: [String] = []
        let duration = segment.end - segment.start
        if segment.avgLogprob <= -0.8 { reasons.append("confiance faible") }
        if segment.noSpeechProb > 0.6 { reasons.append("silence probable") }
        if hasRepeatedWords(segment.text) { reasons.append("mot répété") }
        if duration > 30 { reasons.append("segment très long") }
        if duration < 0.3 { reasons.append("segment très court") }
        return reasons.joined(separator: ", ")
    }

    private var flaggedCount: Int {
        segments.filter(isFlagged).count
    }

    // MARK: - Lecteur : configuration

    /// Chemin de cache pour l'audio réaligné, à côté du transcript.
    private var alignedAudioURL: URL {
        var basename = target.transcriptURL.deletingPathExtension().lastPathComponent
        if basename.hasSuffix("_transcript") { basename.removeLast("_transcript".count) }
        return target.transcriptURL.deletingLastPathComponent()
            .appendingPathComponent("\(basename)_review_audio.wav")
    }

    /// Les horodatages des segments sont calculés par le pipeline sur une
    /// version normalisée de l'audio (WAV mono 16 kHz, via ffmpeg) — pas sur
    /// le fichier original. Pour un MP3 en VBR, le décodeur d'AVFoundation
    /// (utilisé ici pour la lecture) et ffmpeg n'estiment pas toujours la
    /// position exacte de la même façon : sur un long enregistrement, l'écart
    /// s'accumule et devient audible (texte et son décalés). On régénère
    /// donc la même conversion pour la lecture — mise en cache dans le
    /// dossier de sortie, calculée une seule fois — plutôt que de jouer le
    /// fichier original directement.
    private func setupPlayer() {
        if FileManager.default.fileExists(atPath: alignedAudioURL.path) {
            configurePlayer(url: alignedAudioURL)
            return
        }

        isPreparingAudio = true
        let source = target.audioURL
        let destination = alignedAudioURL
        DispatchQueue.global(qos: .userInitiated).async {
            let success = Self.runFFmpegNormalize(source: source, destination: destination)
            DispatchQueue.main.async {
                isPreparingAudio = false
                if success {
                    configurePlayer(url: destination)
                } else {
                    audioPrepWarning = "Impossible de réaligner l'audio (ffmpeg introuvable ou en échec) — lecture du fichier original, un décalage est possible sur les longs enregistrements."
                    configurePlayer(url: source)
                }
            }
        }
    }

    private func configurePlayer(url: URL) {
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        player = p

        if let asset = item.asset as? AVURLAsset {
            Task {
                if let loaded = try? await asset.load(.duration) {
                    await MainActor.run { duration = loaded.seconds }
                }
            }
        }

        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            if !isScrubbing {
                currentTime = time.seconds
            }
        }

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            isPlaying = false
        }
    }

    /// Même conversion que `normalize_audio()` côté pipeline Python
    /// (`transcribe_diarize.py`) : WAV mono 16 kHz. Lancé sur un thread en
    /// arrière-plan (bloquant le temps de la conversion, généralement
    /// quelques secondes même pour un enregistrement long).
    private static func runFFmpegNormalize(source: URL, destination: URL) -> Bool {
        let process = Process()
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        environment["PATH"] = extraPaths + ":" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        process.environment = environment
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-y", "-i", source.path, "-ar", "16000", "-ac", "1", destination.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func seek(to seconds: Double) {
        currentTime = seconds
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Chargement / enregistrement

    private func load() {
        guard let data = try? Data(contentsOf: target.transcriptURL),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            loadError = "Impossible de lire le transcript : \(target.transcriptURL.lastPathComponent)"
            return
        }
        segments = array.map { dict in
            var raw = dict
            raw.removeValue(forKey: "start")
            raw.removeValue(forKey: "end")
            raw.removeValue(forKey: "text")
            raw.removeValue(forKey: "speaker")
            return EditableSegment(
                start: dict["start"] as? Double ?? 0,
                end: dict["end"] as? Double ?? 0,
                text: dict["text"] as? String ?? "",
                speakerID: dict["speaker"] as? String ?? "INCONNU",
                avgLogprob: dict["avg_logprob"] as? Double ?? 0,
                noSpeechProb: dict["no_speech_prob"] as? Double ?? 0,
                raw: raw
            )
        }
    }

    /// Cherche `<basename>_contexte.txt` à côté du transcript et en extrait
    /// les noms de personnes (reconnaissance d'entités nommées, 100% locale
    /// via NaturalLanguage — aucun réseau, aucune dépendance ajoutée) pour
    /// les proposer en un clic dans le renommage des locuteurs.
    private func loadContextNameCandidates() {
        let folder = target.transcriptURL.deletingLastPathComponent()
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let contextURL = entries.first(where: { $0.lastPathComponent.hasSuffix("_contexte.txt") }),
              let text = try? String(contentsOf: contextURL, encoding: .utf8) else { return }
        contextNameCandidates = Self.extractPersonNames(from: text)
    }

    private static func extractPersonNames(from text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var names: Set<String> = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            if tag == .personalName {
                names.insert(String(text[range]))
            }
            return true
        }
        return names.sorted()
    }

    private func save() {
        let ordered = segments.sorted { $0.start < $1.start }

        var updated: [[String: Any]] = []
        for segment in ordered {
            var dict = segment.raw
            dict["start"] = segment.start
            dict["end"] = segment.end
            dict["text"] = segment.text
            dict["speaker"] = displayName(for: segment.speakerID)
            updated.append(dict)
        }

        guard let data = try? JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted]) else {
            saveMessage = "Erreur : impossible de sérialiser le transcript."
            return
        }
        do {
            try data.write(to: target.transcriptURL)
            try writeFinalText(ordered)
            saveMessage = "Enregistré."
        } catch {
            saveMessage = "Erreur d'enregistrement : \(error.localizedDescription)"
        }
    }

    private func writeFinalText(_ ordered: [EditableSegment]) throws {
        var basename = target.transcriptURL.deletingPathExtension().lastPathComponent
        if basename.hasSuffix("_transcript") {
            basename.removeLast("_transcript".count)
        }
        let finalURL = target.transcriptURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(basename)_final.txt")

        var lines: [String] = []
        for segment in ordered {
            lines.append("[\(formatTimestamp(segment.start)) - \(formatTimestamp(segment.end))] \(displayName(for: segment.speakerID))")
            lines.append(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }
        try lines.joined(separator: "\n").write(to: finalURL, atomically: true, encoding: .utf8)
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
