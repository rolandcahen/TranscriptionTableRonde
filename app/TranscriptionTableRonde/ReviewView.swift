import SwiftUI
import AppKit
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

    // Indicateurs calculés par le pipeline (align.py et
    // qualite_transcription.py). Optionnels : un transcript produit avant
    // leur existence n'en porte aucun, et l'absence d'indicateur ne doit
    // surtout pas se lire comme un indicateur au plus mauvais.
    var speakerShare: Double? = nil
    var speakerAlt: String? = nil
    var overlapShare: Double? = nil
    var speechShare: Double? = nil
    var suspectReason: String? = nil

    /// Valeurs au chargement, pour savoir si la relecture a invalidé les
    /// indicateurs : une fois le locuteur ou le texte corrigé à la main,
    /// ils ne décrivent plus ce segment et doivent disparaître du fichier
    /// plutôt que d'y rester à mentir.
    var chargeSpeakerID: String = ""
    var chargeText: String = ""

    var indicateursPerimes: Bool {
        speakerID != chargeSpeakerID || text != chargeText
    }
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
    /// Position du curseur dans chaque segment, en caractères. Conservée par
    /// segment et non globalement : on revient souvent sur un bloc qu'on
    /// était en train de corriger, et y retrouver son point d'arrêt fait
    /// toute la différence sur un segment de deux cents mots.
    @State private var curseurParSegment: [UUID: Int] = [:]
    /// Dernier segment où le curseur a bougé. Sert de « ici » implicite pour
    /// les commandes clavier, qui n'ont pas d'autre moyen de savoir de quel
    /// bloc on parle.
    @State private var segmentActif: UUID?
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

    // Pile d'annulation des modifications destructives (suppression,
    // division, fusion de locuteurs, ajout). Le travail de correction est
    // long et l'interface bouge sous le curseur au fil de la lecture : un
    // clic malencontreux sur la corbeille ne doit pas être définitif,
    // d'autant que l'enregistrement écrase le transcript sur place.
    @State private var undoStack: [[EditableSegment]] = []

    // Empreinte du contenu au dernier enregistrement. Comparée à
    // l'empreinte courante, elle dit si la session est modifiée — y compris
    // après une annulation qui ramène au contenu d'origine, cas qu'un
    // simple drapeau « modifié » traiterait à tort comme un changement.
    @State private var empreinteEnregistree: Int = 0

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
        // .task(id:) et non .onAppear : quand on ouvre une autre session,
        // SwiftUI réutilise la fenêtre déjà ouverte en changeant seulement
        // `target`. .onAppear ne se redéclenchait alors pas — le titre,
        // recalculé à chaque rendu, affichait le nouveau fichier pendant
        // que les segments restaient ceux du précédent. .task(id:) relance
        // le chargement à chaque changement de cible.
        .task(id: target) {
            chargerCible()
        }
        .onDisappear {
            arreterLecteur()
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
                Text("Plusieurs locuteurs dans un même segment : au changement de locuteur, "
                     + "passez à la ligne et commencez par un tiret — comme dans un dialogue — "
                     + "ou tapez « \(Self.speakerSplitMarker) », puis ✂️ pour diviser.")
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
            Button {
                annulerDerniereModification()
            } label: {
                Label("Annuler", systemImage: "arrow.uturn.backward")
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(undoStack.isEmpty)
            .help("Annule la dernière suppression, division, fusion ou ajout de segment.")
            Button {
                exporterCSV()
            } label: {
                Label("Exporter CSV", systemImage: "tablecells")
            }
            .help("Écrit un fichier CSV à côté du transcript : locuteur, début, fin, durée, texte, plus des colonnes vides pour le codage.")
            Button {
                save()
            } label: {
                Label(modifie ? "Enregistrer" : "Enregistré",
                      systemImage: modifie ? "exclamationmark.circle.fill" : "checkmark.circle")
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(modifie ? .red : .gray)
            .help(modifie
                  ? "Des corrections ne sont pas encore écrites sur le disque."
                  : "Tout est enregistré.")
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

                Divider().frame(height: 14)

                Button {
                    lireDepuisCurseur()
                } label: {
                    // Le raccourci est écrit à côté du libellé : un
                    // .keyboardShortcut ne s'affiche nulle part sur un bouton,
                    // et un raccourci qu'on ne peut pas découvrir n'existe
                    // pas.
                    Label(isPlaying ? "Pause  ⌘⏎" : "Lire au curseur  ⌘⏎",
                          systemImage: isPlaying ? "pause.circle" : "text.cursor")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(segmentActif == nil && !isPlaying)
                .help("⌘⏎ — reprend la lecture à l'endroit du curseur dans le texte, et "
                      + "fonctionne même pendant la frappe. La barre d'espace fait la même "
                      + "bascule, mais seulement hors d'une zone de texte, où elle sert à "
                      + "taper une espace.")

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
        memoriserPourAnnulation()
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
            // La barre d'espace ne peut pas piloter la lecture pendant la
            // frappe : dans une zone de texte, elle doit taper une espace.
            // Elle n'agit donc que lorsque la liste elle-même a le focus,
            // c'est-à-dire hors édition — et ⌘⏎ prend le relais dedans.
            .focusable()
            .onKeyPress(.space) {
                basculerLectureGlobale()
                return .handled
            }
        }
    }

    private func segmentRow(_ segment: Binding<EditableSegment>, isCurrent: Bool) -> some View {
        let s = segment.wrappedValue
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    basculerLecture(s)
                } label: {
                    Image(systemName: lit(s) ? "stop.circle.fill" : "play.circle")
                }
                .buttonStyle(.plain)
                .help(lit(s) ? "Arrêter" : "Lire ce segment")

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

                Text(confianceTexte(s))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(confianceTeinte(s))
                    .help("Confiance moyenne du modèle sur ce segment. Ce n'est pas un taux d'exactitude : elle sert à repérer les passages à relire en priorité.")

                // Le doute d'attribution est actionnable, pas seulement
                // informatif : l'autre candidat est connu, autant proposer
                // de basculer dessus d'un clic plutôt que de faire rouvrir
                // le menu déroulant.
                if let doute = douteAttribution(s) {
                    Button {
                        memoriserPourAnnulation()
                        segment.speakerID.wrappedValue = doute.autre
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: voixSuperposees(s) ? "waveform.badge.exclamationmark" : "person.2.fill")
                            Text("\(Int((doute.part * 100).rounded()))% · ou \(displayName(for: doute.autre)) ?")
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help(voixSuperposees(s)
                          ? "Deux personnes parlent en même temps ici : le texte lui-même est peu fiable. Cliquer attribue le segment à \(displayName(for: doute.autre))."
                          : "La parole de ce segment est partagée entre deux locuteurs qui se succèdent : la coupure est probablement au mauvais endroit. Cliquer l'attribue à \(displayName(for: doute.autre)).")
                }

                if isFlagged(s) {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(flagReason(s))
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.orange)
                    .help("Segment signalé : \(flagReason(s)). À vérifier en priorité.")
                }
                Spacer()
                // Toujours présents, jamais grisés : si le texte porte des
                // marqueurs ou des tirets de dialogue, on coupe dessus ;
                // sinon on coupe là où est le curseur. Le seul cas sans
                // effet est un curseur collé à un bord, et l'infobulle le
                // dit plutôt que de laisser un bouton mort.
                Button {
                    diviser(s)
                } label: {
                    Image(systemName: "scissors")
                }
                .buttonStyle(.plain)
                .help(aideDivision(s))
                Button {
                    deleteSegment(s.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }

            // Cartouche à la hauteur du texte, sans défilement interne.
            //
            // Un TextEditor ne se dimensionne pas sur son contenu : à
            // hauteur fixe, un segment long devenait une fenêtre de trois
            // lignes dans laquelle il fallait faire défiler pour lire et
            // corriger. On superpose donc, dans un ZStack, un Text invisible
            // portant le même contenu, la même police et les mêmes marges :
            // c'est lui qui, par sa hauteur naturelle de texte replié,
            // impose la hauteur de la pile — le TextEditor s'y ajuste.
            ZStack(alignment: .topLeading) {
                Text(s.text.isEmpty ? " " : s.text)
                    .font(.system(.body))
                    .padding(EdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(0)
                    .accessibilityHidden(true)
                SegmentTextView(
                    texte: segment.text,
                    positionCurseur: Binding(
                        get: { curseurParSegment[s.id] ?? 0 },
                        set: { curseurParSegment[s.id] = $0 }
                    ),
                    surlignage: plageLue(de: s),
                    couleurSurlignage: NSColor.controlAccentColor.withAlphaComponent(0.30),
                    onCurseurDeplace: { position in
                        segmentActif = s.id
                        curseurParSegment[s.id] = position
                    }
                )
            }
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
        memoriserPourAnnulation()
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
        memoriserPourAnnulation()
        segments.removeAll { $0.id == id }
    }

    /// Empile l'état courant avant toute modification destructive.
    /// Profondeur bornée : il s'agit de rattraper un clic malheureux, pas
    /// de rejouer une séance entière de correction.
    private func memoriserPourAnnulation() {
        undoStack.append(segments)
        if undoStack.count > 30 { undoStack.removeFirst() }
        saveMessage = nil
    }

    private func annulerDerniereModification() {
        guard let precedent = undoStack.popLast() else { return }
        segments = precedent
        saveMessage = "Modification annulée."
    }

    /// Vrai si la lecture est en cours et que la tête de lecture se trouve
    /// dans ce segment.
    private func lit(_ segment: EditableSegment) -> Bool {
        isPlaying && currentTime >= segment.start && currentTime < segment.end
    }

    /// Bascule simple, sans déplacer la tête de lecture : c'est ce qu'on
    /// attend d'une barre d'espace, et c'est ce qui permet de s'arrêter une
    /// seconde pour corriger un mot puis de repartir au même endroit.
    private func basculerLectureGlobale() {
        guard player != nil else { return }
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            player?.play()
            isPlaying = true
        }
    }

    /// Reprend la lecture à l'endroit du curseur dans le texte.
    ///
    /// La correspondance entre une position dans le texte et un instant du
    /// son est proportionnelle à la longueur du texte : faute d'horodatage
    /// par mot — écarté parce qu'il multipliait le temps de transcription
    /// par vingt — c'est la meilleure approximation disponible. Elle suppose
    /// un débit régulier, ce qui est faux dans le détail mais suffisant pour
    /// retomber à quelques secondes près dans un bloc de deux cents mots, au
    /// lieu de le réécouter en entier.
    private func instantDuCurseur(dans segment: EditableSegment, position: Int) -> Double {
        let longueur = (segment.text as NSString).length
        guard longueur > 0 else { return segment.start }
        let part = min(max(Double(position) / Double(longueur), 0), 1)
        return segment.start + (segment.end - segment.start) * part
    }

    private func lireDepuisCurseur() {
        guard player != nil else { return }
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }
        if let id = segmentActif, let segment = segments.first(where: { $0.id == id }) {
            seek(to: instantDuCurseur(dans: segment, position: curseurParSegment[id] ?? 0))
        }
        player?.play()
        isPlaying = true
    }

    /// Mot que la tête de lecture est censée atteindre, à surligner.
    ///
    /// Même approximation que ci-dessus, prise dans l'autre sens. On surligne
    /// le mot entier plutôt que le caractère calculé : un surlignage d'un
    /// seul signe serait illisible, et donnerait surtout une fausse
    /// impression de précision.
    private func plageLue(de segment: EditableSegment) -> Range<Int>? {
        guard isPlaying, lit(segment) else { return nil }
        let texte = segment.text as NSString
        let duree = segment.end - segment.start
        guard texte.length > 0, duree > 0 else { return nil }

        let avance = min(max((currentTime - segment.start) / duree, 0), 1)
        let index = min(Int(Double(texte.length) * avance), texte.length - 1)

        let blancs = CharacterSet.whitespacesAndNewlines
        func estBlanc(_ i: Int) -> Bool {
            guard i >= 0, i < texte.length else { return true }
            guard let scalaire = UnicodeScalar(UInt32(texte.character(at: i))) else { return false }
            return blancs.contains(scalaire)
        }

        guard !estBlanc(index) else { return nil }
        var debut = index
        while debut > 0, !estBlanc(debut - 1) { debut -= 1 }
        var fin = index
        while fin < texte.length, !estBlanc(fin) { fin += 1 }
        return fin > debut ? debut..<fin : nil
    }

    /// Le bouton de chaque segment fonctionne en bascule : s'il joue déjà
    /// ce segment, il arrête ; sinon il s'y positionne et démarre.
    private func basculerLecture(_ segment: EditableSegment) {
        if lit(segment) {
            player?.pause()
            isPlaying = false
        } else {
            seek(to: segment.start)
            player?.play()
            isPlaying = true
        }
    }

    // MARK: - Division au marqueur de locuteur

    /// Marqueur tapé directement dans le texte à l'endroit d'un changement
    /// de locuteur — évite de devoir repérer l'instant exact à l'écoute.
    static let speakerSplitMarker = "|"

    /// Tirets admis comme tirets de dialogue, du clavier à la typographie
    /// soignée : trait d'union, tiret demi-cadratin, tiret cadratin.
    private static let tiretsDeDialogue: Set<Character> = ["-", "\u{2013}", "\u{2014}"]

    /// Traduit les tirets de dialogue en marqueurs de division.
    ///
    /// Dans un texte dialogué, un tiret en début de ligne annonce qu'une
    /// autre personne prend la parole. C'est la convention française, c'est
    /// ce que la main tape spontanément en corrigeant un gros bloc, et il
    /// serait absurde d'exiger en plus un « | » pour dire la même chose.
    ///
    /// Le tiret doit être suivi d'une espace : sans cette condition, une
    /// ligne commençant par « -5 % » ou par une énumération technique serait
    /// coupée en deux. La typographie française met de toute façon une
    /// espace après le tiret de dialogue.
    static func normaliserMarqueursDeDivision(_ texte: String) -> String {
        var sortie = ""
        var debutDeLigne = true
        var index = texte.startIndex
        while index < texte.endIndex {
            let caractere = texte[index]
            let suivant = texte.index(after: index)

            if caractere.isNewline {
                sortie.append(caractere)
                debutDeLigne = true
                index = suivant
                continue
            }
            if debutDeLigne, caractere == " " || caractere == "\t" {
                sortie.append(caractere)
                index = suivant
                continue
            }
            if debutDeLigne, Self.tiretsDeDialogue.contains(caractere) {
                let suit = suivant < texte.endIndex ? texte[suivant] : " "
                if suit.isWhitespace {
                    sortie.append(contentsOf: Self.speakerSplitMarker)
                    debutDeLigne = false
                    index = suivant
                    continue
                }
            }
            debutDeLigne = false
            sortie.append(caractere)
            index = suivant
        }
        return sortie
    }

    /// Morceaux qu'une division produirait, marqueurs et tirets confondus.
    static func morceauxDeDivision(_ texte: String) -> [String] {
        normaliserMarqueursDeDivision(texte)
            .components(separatedBy: Self.speakerSplitMarker)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func peutEtreDivise(_ texte: String) -> Bool {
        morceauxDeDivision(texte).count > 1
    }

    /// Découpe le texte du segment à chaque marqueur, répartit la durée
    /// entre les morceaux au prorata de leur longueur de texte (approximatif
    /// mais un bon point de départ — les horodatages restent éditables
    /// ensuite), et remplace le segment d'origine par autant de segments que
    /// de morceaux non vides. Tous héritent du même locuteur au départ : à
    /// réattribuer ensuite via le menu de chaque nouveau segment.
    /// Divise comme l'utilisateur s'y attend : sur les marqueurs s'il y en
    /// a, sinon là où il vient de poser le curseur.
    private func diviser(_ segment: EditableSegment) {
        if Self.peutEtreDivise(segment.text) {
            splitSegment(segment.id)
        } else {
            diviserAuCurseur(segment)
        }
    }

    private func aideDivision(_ segment: EditableSegment) -> String {
        if Self.peutEtreDivise(segment.text) {
            return "Diviser ce segment en \(Self.morceauxDeDivision(segment.text).count) parties, "
                + "à chaque « \(Self.speakerSplitMarker) » et à chaque tiret de dialogue en début "
                + "de ligne. Le temps est réparti au prorata de la longueur du texte de chaque "
                + "partie, et les horodatages restent modifiables ensuite."
        }
        let position = curseurParSegment[segment.id] ?? 0
        if position > 0 && position < (segment.text as NSString).length {
            return "Couper ce segment en deux à la position du curseur. Pour plusieurs coupures "
                + "d'un coup, passez à la ligne au changement de locuteur et commencez par un "
                + "tiret, ou tapez « \(Self.speakerSplitMarker) »."
        }
        return "Placez le curseur dans le texte à l'endroit du changement de locuteur, ou passez "
            + "à la ligne et commencez par un tiret, puis cliquez ici."
    }

    /// Coupe en deux à la position du curseur, en répartissant la durée au
    /// prorata de la longueur de chaque moitié — même règle que la division
    /// par marqueurs, pour que les deux gestes donnent le même résultat sur
    /// un même point de coupe.
    private func diviserAuCurseur(_ segment: EditableSegment) {
        guard let index = segments.firstIndex(where: { $0.id == segment.id }) else { return }
        let texte = segment.text as NSString
        let position = curseurParSegment[segment.id] ?? 0
        guard position > 0, position < texte.length else { return }

        let avant = texte.substring(to: position).trimmingCharacters(in: .whitespacesAndNewlines)
        let apres = texte.substring(from: position).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !avant.isEmpty, !apres.isEmpty else { return }

        memoriserPourAnnulation()
        let original = segments[index]
        let duree = original.end - original.start
        let total = avant.count + apres.count
        let coupure = total > 0
            ? original.start + duree * Double(avant.count) / Double(total)
            : original.start + duree / 2

        var premier = original
        premier.text = avant
        premier.end = coupure
        // chargeSpeakerID et chargeText restent vides : les deux moitiés
        // sont du contenu nouveau, les indicateurs hérités du segment entier
        // ne les décrivent plus et seront retirés à l'enregistrement.
        let second = EditableSegment(
            start: coupure,
            end: original.end,
            text: apres,
            speakerID: original.speakerID,
            avgLogprob: original.avgLogprob,
            noSpeechProb: original.noSpeechProb,
            raw: original.raw
        )
        segments.replaceSubrange(index...index, with: [premier, second])
        curseurParSegment[original.id] = 0
    }

    private func splitSegment(_ id: UUID) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        memoriserPourAnnulation()
        let original = segments[index]
        let parts = Self.morceauxDeDivision(original.text)
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
                    // chargeSpeakerID/chargeText laissés vides : un morceau
                    // issu d'une division est par construction du contenu
                    // nouveau, ses indicateurs hérités sont donc périmés.
                    noSpeechProb: original.noSpeechProb,
                    raw: original.raw
                )
            )
            cursor = end
        }
        segments.replaceSubrange(index...index, with: newSegments)
    }

    // MARK: - Confiance et signaux heuristiques

    /// Confiance du modèle sur ce segment, en probabilité moyenne par jeton.
    ///
    /// Whisper fournit `avg_logprob`, la moyenne des logarithmes des
    /// probabilités attribuées à chaque jeton. Son exponentielle redonne un
    /// nombre entre 0 et 1, lisible en pourcentage et comparable d'un
    /// segment à l'autre.
    ///
    /// À ne pas lire comme un taux d'exactitude : c'est la confiance que le
    /// modèle a en lui-même, pas une mesure de justesse — un contresens peut
    /// très bien être produit avec une confiance élevée. Sa valeur est
    /// comparative : elle classe les segments par ordre de suspicion.
    private func confiance(_ segment: EditableSegment) -> Double? {
        // Un `avg_logprob` exactement nul ne sort jamais du modèle : c'est
        // la valeur par défaut d'un segment ajouté à la main ou d'un JSON
        // sans ce champ. Afficher « 100 % » y serait trompeur.
        guard segment.avgLogprob != 0 else { return nil }
        return min(1, max(0, exp(segment.avgLogprob)))
    }

    private func confianceTexte(_ segment: EditableSegment) -> String {
        guard let valeur = confiance(segment) else { return "—" }
        return "\(Int((valeur * 100).rounded())) %"
    }

    private func confianceTeinte(_ segment: EditableSegment) -> Color {
        guard confiance(segment) != nil else { return .secondary }
        if segment.avgLogprob > -0.3 { return .green }
        if segment.avgLogprob > -0.8 { return .orange }
        return .red
    }

    /// Empreinte de tout ce qui est éditable. Recalculée à chaque rendu :
    /// quelques centaines de segments de texte court, c'est négligeable
    /// devant le coût d'affichage de la liste elle-même.
    private var empreinteEdition: Int {
        var hasher = Hasher()
        for segment in segments {
            hasher.combine(segment.start)
            hasher.combine(segment.end)
            hasher.combine(segment.text)
            hasher.combine(segment.speakerID)
        }
        for cle in speakerNames.keys.sorted() {
            hasher.combine(cle)
            hasher.combine(speakerNames[cle] ?? "")
        }
        return hasher.finalize()
    }

    private var modifie: Bool {
        empreinteEdition != empreinteEnregistree
    }

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

    /// Un segment est signalé soit par le pipeline, qui dispose d'éléments
    /// que l'app n'a pas — notamment le croisement avec la diarisation —
    /// soit, pour les transcripts plus anciens, par les heuristiques
    /// calculées ici.
    private func isFlagged(_ segment: EditableSegment) -> Bool {
        if segment.indicateursPerimes { return false }
        if segment.suspectReason != nil { return true }
        let duration = segment.end - segment.start
        return segment.avgLogprob <= -0.8
            || segment.noSpeechProb > 0.6
            || hasRepeatedWords(segment.text)
            || duration > 30
            || (duration < 0.3 && !segment.text.isEmpty)
    }

    /// Part de la parole du segment revenant au locuteur retenu, quand elle
    /// est franchement partagée avec un autre. Le seuil de 0,80 vient de la
    /// mesure faite sur un extrait réel : au-dessus, les segments concernés
    /// se comptent sur les doigts d'une main et se lisent très bien.
    private func douteAttribution(_ segment: EditableSegment) -> (part: Double, autre: String)? {
        guard !segment.indicateursPerimes,
              let part = segment.speakerShare, part < 0.80,
              let autre = segment.speakerAlt, !autre.isEmpty else { return nil }
        return (part, autre)
    }

    private func voixSuperposees(_ segment: EditableSegment) -> Bool {
        !segment.indicateursPerimes && (segment.overlapShare ?? 0) > 0.05
    }

    private func flagReason(_ segment: EditableSegment) -> String {
        if let raison = segment.suspectReason, !raison.isEmpty { return raison }
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

    /// Charge, ou recharge entièrement, la fenêtre pour la cible courante.
    /// Remet à zéro tout l'état de l'ancienne session avant de lire la
    /// nouvelle : sans cela, des segments, des noms de locuteurs ou une
    /// pile d'annulation du fichier précédent survivraient au changement.
    private func chargerCible() {
        arreterLecteur()
        segments = []
        speakerNames = [:]
        manualSpeakerIDs = []
        nextManualSpeakerNumber = 1
        contextNameCandidates = []
        undoStack = []
        loadError = nil
        saveMessage = nil
        audioPrepWarning = nil
        currentTime = 0
        duration = 0

        load()
        setupPlayer()
        loadContextNameCandidates()

        // Point de référence du bouton « Enregistrer » : ce qui vient
        // d'être lu sur le disque est, par définition, déjà enregistré.
        empreinteEnregistree = empreinteEdition
    }

    /// Arrête la lecture et détache l'observateur de temps. Indispensable
    /// avant de changer de cible : sans détachement, l'observateur de
    /// l'ancien lecteur continuerait d'écrire dans `currentTime`.
    private func arreterLecteur() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
    }

    // MARK: - Export CSV

    /// Écrit un CSV à côté du transcript, prêt pour le codage dans un
    /// tableur. Point-virgule et BOM UTF-8 : sans eux, Excel en français
    /// met toute la ligne dans une seule colonne et abîme les accents.
    private func exporterCSV() {
        let ordered = segments.sorted { $0.start < $1.start }
        let colonnes = ["n", "locuteur", "debut", "fin", "debut_s", "fin_s",
                        "duree_s", "mots", "texte", "code_1", "code_2", "code_3"]

        var lignes = [colonnes.joined(separator: ";")]
        for (n, segment) in ordered.enumerated() {
            let texte = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let champs = [
                String(n + 1),
                displayName(for: segment.speakerID),
                formatTimestamp(segment.start),
                formatTimestamp(segment.end),
                String(format: "%.2f", segment.start),
                String(format: "%.2f", segment.end),
                String(format: "%.2f", max(0, segment.end - segment.start)),
                String(texte.split(whereSeparator: { $0.isWhitespace }).count),
                texte,
                "", "", "",
            ]
            lignes.append(champs.map(Self.echapperCSV).joined(separator: ";"))
        }

        var basename = target.transcriptURL.deletingPathExtension().lastPathComponent
        if basename.hasSuffix("_transcript") { basename.removeLast("_transcript".count) }
        let destination = target.transcriptURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(basename).csv")

        let contenu = "\u{FEFF}" + lignes.joined(separator: "\r\n") + "\r\n"
        do {
            try contenu.write(to: destination, atomically: true, encoding: .utf8)
            saveMessage = "CSV exporté : \(destination.lastPathComponent)"
        } catch {
            saveMessage = "Erreur d'export CSV : \(error.localizedDescription)"
        }
    }

    /// Un champ contenant un point-virgule, un guillemet ou un retour à la
    /// ligne doit être encadré de guillemets, les guillemets internes étant
    /// doublés — sinon le tableur décale toutes les colonnes suivantes.
    private static func echapperCSV(_ champ: String) -> String {
        guard champ.contains(";") || champ.contains("\"") || champ.contains("\n") || champ.contains("\r") else {
            return champ
        }
        return "\"" + champ.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

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
            let texte = dict["text"] as? String ?? ""
            let locuteur = dict["speaker"] as? String ?? "INCONNU"
            return EditableSegment(
                start: dict["start"] as? Double ?? 0,
                end: dict["end"] as? Double ?? 0,
                text: texte,
                speakerID: locuteur,
                avgLogprob: dict["avg_logprob"] as? Double ?? 0,
                noSpeechProb: dict["no_speech_prob"] as? Double ?? 0,
                raw: raw,
                speakerShare: dict["speaker_share"] as? Double,
                speakerAlt: dict["speaker_alt"] as? String,
                overlapShare: dict["overlap_share"] as? Double,
                speechShare: dict["speech_share"] as? Double,
                suspectReason: dict["suspect_reason"] as? String,
                chargeSpeakerID: locuteur,
                chargeText: texte
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
            // Un segment que vous avez corrigé n'est plus décrit par les
            // indicateurs calculés avant votre correction. Les laisser ferait
            // réapparaître le signalement orange sur un segment désormais
            // juste — et, pire, le ferait ressortir dans le diagnostic comme
            // un problème non résolu.
            if segment.indicateursPerimes {
                for cle in ["speaker_share", "speaker_alt", "speaker_alt_share",
                            "overlap_share", "speech_share",
                            "suspect", "suspect_reason", "suspect_causes"] {
                    dict.removeValue(forKey: cle)
                }
            }
            updated.append(dict)
        }

        guard let data = try? JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted]) else {
            saveMessage = "Erreur : impossible de sérialiser le transcript."
            return
        }
        do {
            try data.write(to: target.transcriptURL)
            try writeFinalText(ordered)
            empreinteEnregistree = empreinteEdition
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


/// Zone de texte d'un segment, bâtie sur NSTextView.
///
/// Raison d'être : `TextEditor` n'expose ni la position du curseur ni la
/// sélection. Or sans elles, deux gestes sont tout simplement impossibles —
/// couper un segment là où l'on vient de cliquer, et reprendre la lecture au
/// même endroit. Aucun arrangement côté SwiftUI n'y change rien ; il faut
/// descendre à AppKit, qui les donne.
///
/// Le surlignage de la tête de lecture passe par un attribut de fond posé
/// sur le stockage de texte, et jamais par une modification de la chaîne :
/// le texte affiché reste exactement celui du modèle, à la virgule près.
struct SegmentTextView: NSViewRepresentable {
    @Binding var texte: String
    @Binding var positionCurseur: Int
    var surlignage: Range<Int>?
    var couleurSurlignage: NSColor
    var onCurseurDeplace: ((Int) -> Void)?

    func makeNSView(context: Context) -> NSTextView {
        let vue = NSTextView()
        vue.delegate = context.coordinator
        vue.isRichText = false
        vue.allowsUndo = true
        vue.isAutomaticQuoteSubstitutionEnabled = false
        vue.isAutomaticDashSubstitutionEnabled = false
        vue.font = .systemFont(ofSize: NSFont.systemFontSize)
        vue.textColor = .labelColor
        vue.drawsBackground = false
        vue.isVerticallyResizable = false
        vue.isHorizontallyResizable = false
        vue.textContainerInset = NSSize(width: 5, height: 7)
        vue.textContainer?.widthTracksTextView = true
        vue.textContainer?.lineFragmentPadding = 0
        vue.string = texte
        return vue
    }

    func updateNSView(_ vue: NSTextView, context: Context) {
        context.coordinator.parent = self

        if vue.string != texte {
            // Le curseur est rétabli après une réécriture venue du modèle :
            // sans cela, la moindre mise à jour le renverrait au début du
            // bloc, ce qui rend toute correction longue impraticable.
            let ancien = vue.selectedRange().location
            context.coordinator.enMiseAJour = true
            vue.string = texte
            let limite = (texte as NSString).length
            vue.setSelectedRange(NSRange(location: min(ancien, limite), length: 0))
            context.coordinator.enMiseAJour = false
        }

        guard let stockage = vue.textStorage else { return }
        let tout = NSRange(location: 0, length: stockage.length)
        stockage.removeAttribute(.backgroundColor, range: tout)
        // Le fond est retiré des attributs de frappe, faute de quoi le mot
        // surligné contaminerait tout ce qui serait tapé à sa suite.
        vue.typingAttributes.removeValue(forKey: .backgroundColor)

        guard let surlignage else { return }
        let debut = max(0, min(surlignage.lowerBound, stockage.length))
        let fin = max(debut, min(surlignage.upperBound, stockage.length))
        guard fin > debut else { return }
        stockage.addAttribute(.backgroundColor, value: couleurSurlignage,
                              range: NSRange(location: debut, length: fin - debut))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SegmentTextView
        /// Vrai pendant qu'on réécrit la vue depuis le modèle. Les
        /// notifications émises alors décrivent notre propre écriture, pas
        /// un geste de l'utilisateur : les relayer ferait croire à un
        /// déplacement de curseur et déclencherait une lecture non demandée.
        var enMiseAJour = false

        init(_ parent: SegmentTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !enMiseAJour, let vue = notification.object as? NSTextView else { return }
            parent.texte = vue.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !enMiseAJour, let vue = notification.object as? NSTextView else { return }
            let position = vue.selectedRange().location
            guard position != parent.positionCurseur else { return }
            parent.positionCurseur = position
            parent.onCurseurDeplace?(position)
        }
    }
}

