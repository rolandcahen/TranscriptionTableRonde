import Foundation
import Combine
import AVFoundation
import IOKit.pwr_mgt

enum BatchJobStatus: String, Codable {
    case pending, running, done, failed
}

struct BatchJob: Identifiable, Codable, Equatable {
    let id: UUID
    let audioURL: URL
    var status: BatchJobStatus
    let outputFolder: URL
    let context: String?
    let numSpeakers: Int?
    var errorMessage: String?
    var lastProgressLabel: String?
    // Durée de l'audio (secondes), chargée en arrière-plan après le scan —
    // absente (nil) tant que la lecture asynchrone n'a pas abouti.
    var duration: Double? = nil
    // Temps réellement pris par le traitement (secondes), enregistré à la
    // fin du job — sert de référence pour estimer la durée des suivants.
    var processingDuration: Double? = nil
}

/// Orchestre le traitement séquentiel d'un lot de fichiers audio : scan de
/// dossier, résolution du contexte par fichier, file d'attente persistée
/// (reprise après plantage/fermeture), anti-veille pendant le traitement.
///
/// Ne réimplémente rien du pipeline : réutilise un `PipelineRunner` frais
/// par job, exactement comme le flux fichier unique de `ContentView`.
final class BatchQueueManager: ObservableObject {
    @Published var jobs: [BatchJob] = []
    @Published var isActive: Bool = false
    @Published var currentRunner: PipelineRunner?
    @Published var currentJobID: UUID?
    @Published var isSummarizingAll = false

    let summaryRunner = SummaryRunner()

    private let queueFileURL: URL
    private var wasActiveOnLoad = false
    private var progressSaveTimer: Timer?
    private var sleepAssertionID: IOPMAssertionID = 0
    private var runnerCancellable: AnyCancellable?
    private var summaryCancellable: AnyCancellable?
    private var summaryQueue: [BatchJob] = []

    private struct PersistedQueue: Codable {
        var jobs: [BatchJob]
        var isActive: Bool
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranscriptionTableRonde", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        queueFileURL = appSupport.appendingPathComponent("batch_queue.json")
        load()
    }

    // MARK: - Compteurs pour l'interface

    var doneCount: Int { jobs.filter { $0.status == .done }.count }
    var runningCount: Int { jobs.filter { $0.status == .running }.count }
    var pendingCount: Int { jobs.filter { $0.status == .pending }.count }
    var failedCount: Int { jobs.filter { $0.status == .failed }.count }

    var overallFraction: Double {
        guard !jobs.isEmpty else { return 0 }
        return Double(doneCount) / Double(jobs.count)
    }

    // MARK: - Scan de dossier et résolution du contexte

    private struct FileInfo {
        var context: String?
        var numSpeakers: Int?
    }

    /// Priorité du contexte par fichier :
    /// 1. Fichier maître "Contexte" (nom sans extension, insensible à la
    ///    casse — couvre `Contexte`, `Contexte.txt`, `contexte.txt`) : si
    ///    son contenu contient des blocs séparés par une ligne vide dont la
    ///    première ligne correspond au nom exact d'un audio, ce bloc sert
    ///    de contexte spécifique à cet audio. Dans ce bloc, une ligne du
    ///    type "Locuteurs: 5" (voir `parseSpeakerCount`) est extraite comme
    ///    nombre de locuteurs pour ce fichier et retirée du texte de
    ///    contexte. Si aucun bloc du fichier maître ne correspond à un nom
    ///    d'audio (texte libre sans en-têtes reconnus), tout son contenu
    ///    sert de contexte commun à tous les audios (comportement
    ///    historique de `contexte.txt`).
    /// 2. Fichier texte de même nom que l'audio (spécifique) — concaténé
    ///    après le contexte résolu ci-dessus si les deux existent.
    /// Racine du dossier uniquement, pas de sous-dossiers dans cette version.
    func scanFolder(_ folder: URL) {
        let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aac", "aif", "aiff", "caf", "mp4"]
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let audioFiles = entries
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let masterContextURL = entries.first {
            $0.deletingPathExtension().lastPathComponent
                .precomposedStringWithCanonicalMapping.lowercased() == "contexte"
        }
        let masterContextContent = masterContextURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let perFileInfo = masterContextContent.map {
            parseMultiFileBlocks(masterFileContent: $0, audioFilenames: audioFiles.map { $0.lastPathComponent })
        } ?? [:]
        let sharedContext = perFileInfo.isEmpty ? masterContextContent : nil

        var newJobs: [BatchJob] = []
        for audioURL in audioFiles {
            guard !jobs.contains(where: { $0.audioURL == audioURL }) else { continue }

            let normalizedName = audioURL.lastPathComponent.precomposedStringWithCanonicalMapping
            let basename = audioURL.deletingPathExtension().lastPathComponent
                .precomposedStringWithCanonicalMapping
            let specificContextURL = entries.first {
                $0.pathExtension.lowercased() == "txt"
                    && $0.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping == basename
            }
            let specificContext = specificContextURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            let matchedInfo = perFileInfo[normalizedName]

            var parts: [String] = []
            if let matchedContext = matchedInfo?.context, !matchedContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(matchedContext.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if let sharedContext, !sharedContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(sharedContext.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let specificContext, !specificContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(specificContext.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            let outputFolder = audioURL.deletingLastPathComponent()
                .appendingPathComponent("sortie_\(audioURL.deletingPathExtension().lastPathComponent)")

            newJobs.append(
                BatchJob(
                    id: UUID(),
                    audioURL: audioURL,
                    status: .pending,
                    outputFolder: outputFolder,
                    context: parts.isEmpty ? nil : parts.joined(separator: "\n\n"),
                    numSpeakers: matchedInfo?.numSpeakers,
                    errorMessage: nil
                )
            )
        }
        jobs.append(contentsOf: newJobs)
        save()
        for job in newJobs { loadDuration(for: job.id, audioURL: job.audioURL) }
    }

    /// Charge la durée de l'audio en arrière-plan (lecture asynchrone
    /// AVFoundation, ne bloque pas le scan) et la mémorise dans le job dès
    /// qu'elle est connue.
    private func loadDuration(for jobID: UUID, audioURL: URL) {
        Task { [weak self] in
            let asset = AVURLAsset(url: audioURL)
            guard let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 else { return }
            await MainActor.run {
                guard let self, let index = self.jobs.firstIndex(where: { $0.id == jobID }) else { return }
                self.jobs[index].duration = seconds
                self.save()
            }
        }
    }

    /// Ratio moyen (temps de traitement / durée audio) observé sur les jobs
    /// déjà terminés avec succès dans cette file — sert à estimer le temps
    /// des fichiers encore en attente. `nil` tant qu'aucune référence n'est
    /// disponible (premier fichier du lot).
    var estimatedProcessingRatio: Double? {
        let ratios = jobs.compactMap { job -> Double? in
            guard job.status == .done, let duration = job.duration, duration > 0,
                  let processing = job.processingDuration else { return nil }
            return processing / duration
        }
        guard !ratios.isEmpty else { return nil }
        return ratios.reduce(0, +) / Double(ratios.count)
    }

    func estimatedProcessingSeconds(for job: BatchJob) -> Double? {
        guard let duration = job.duration, let ratio = estimatedProcessingRatio else { return nil }
        return duration * ratio
    }

    /// Découpe le fichier maître en blocs séparés par une ligne vide. Un bloc
    /// est retenu pour un audio seulement si sa première ligne correspond
    /// exactement (normalisée Unicode, espaces coupés, insensible à la
    /// casse) à son nom ; dans le reste du bloc, une ligne "Locuteurs: N"
    /// (voir `parseSpeakerCount`) est extraite comme nombre de locuteurs et
    /// retirée, le texte restant devient le contexte. Les blocs sans
    /// correspondance sont ignorés ici — l'appelant retombe alors sur
    /// l'ancien comportement "tout le fichier = contexte commun" si le
    /// dictionnaire retourné est vide.
    private func parseMultiFileBlocks(masterFileContent: String, audioFilenames: [String]) -> [String: FileInfo] {
        let normalizedNames = Set(audioFilenames.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        let normalizedContent = masterFileContent.precomposedStringWithCanonicalMapping
        let blocks = normalizedContent.components(separatedBy: "\n\n")

        var result: [String: FileInfo] = [:]
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let headerLine = lines.first else { continue }
            let header = headerLine.trimmingCharacters(in: .whitespaces)
            guard normalizedNames.contains(header.lowercased()) else { continue }

            var numSpeakers: Int?
            var contextLines: [String] = []
            for line in lines.dropFirst() {
                if let n = parseSpeakerCount(from: line) {
                    numSpeakers = n
                } else {
                    contextLines.append(line)
                }
            }
            let body = contextLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty || numSpeakers != nil else { continue }

            // Retrouve la casse/forme exacte du nom de fichier pour la clé,
            // afin que le lookup par `lastPathComponent` (non lowercased)
            // fonctionne côté appelant.
            if let exactName = audioFilenames.first(where: {
                $0.precomposedStringWithCanonicalMapping.lowercased() == header.lowercased()
            }) {
                result[exactName.precomposedStringWithCanonicalMapping] = FileInfo(
                    context: body.isEmpty ? nil : body,
                    numSpeakers: numSpeakers
                )
            }
        }
        return result
    }

    /// Reconnaît une ligne telle que "Locuteurs: 5", "Locuteur : 5",
    /// "Nb locuteurs : 5", "Nombre de locuteurs: 5" ou "Speakers: 5"
    /// (insensible à la casse, espace optionnel avant les deux-points).
    private func parseSpeakerCount(from line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
        let prefixes = ["nombre de locuteurs", "nombre de locuteur", "nb de locuteurs", "nb de locuteur", "nb locuteurs", "nb locuteur", "locuteurs", "locuteur", "speakers"]
        for prefix in prefixes {
            guard trimmed.hasPrefix(prefix) else { continue }
            let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix(":") else { continue }
            let digits = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            if let n = Int(digits), n > 0 {
                return n
            }
        }
        return nil
    }

    // MARK: - Traitement séquentiel

    func start(settings: AppSettings) {
        guard !isActive else { return }
        isActive = true
        preventSleep()
        save()
        processNext(settings: settings)
    }

    /// N'interrompt pas le job en cours : il va à son terme, puis la file
    /// s'arrête avant de démarrer le suivant.
    func pause() {
        isActive = false
        allowSleep()
        save()
    }

    func retry(_ jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].status = .pending
        jobs[index].errorMessage = nil
        save()
    }

    /// Retire un job non actif de la file (pending/terminé/échoué). Pour le
    /// job en cours, utiliser `clearQueue()` qui interrompt proprement le
    /// traitement avant de vider.
    func removeJob(_ jobID: UUID) {
        guard jobID != currentJobID else { return }
        jobs.removeAll { $0.id == jobID }
        save()
    }

    /// Interrompt le job en cours (le processus Python est terminé) et vide
    /// entièrement la file — utile après un scan fait avant l'ajout de
    /// contexte/nombre de locuteurs, pour repartir d'un scan propre. Les
    /// fichiers de sortie déjà écrits sur disque ne sont pas supprimés.
    func clearQueue() {
        isActive = false
        allowSleep()
        // Détacher l'abonnement avant d'annuler : la terminaison du
        // processus est asynchrone, on ne veut pas que jobFinished()
        // s'exécute sur une file déjà vidée.
        runnerCancellable = nil
        currentRunner?.cancel()
        currentRunner = nil
        currentJobID = nil
        stopProgressSaveTimer()
        jobs.removeAll()
        save()
    }

    /// À appeler depuis `.onAppear` de la vue (a besoin d'`AppSettings`,
    /// indisponible dans `init()`). Reprend automatiquement si la file
    /// était active lors de la dernière fermeture/plantage.
    func resumeIfNeeded(settings: AppSettings) {
        guard wasActiveOnLoad, !isActive else { return }
        wasActiveOnLoad = false
        start(settings: settings)
    }

    private func processNext(settings: AppSettings) {
        guard isActive else { return }
        guard let index = jobs.firstIndex(where: { $0.status == .pending }) else {
            isActive = false
            allowSleep()
            save()
            return
        }

        jobs[index].status = .running
        save()
        let job = jobs[index]
        let startedAt = Date()

        let runner = PipelineRunner()
        currentRunner = runner
        currentJobID = job.id

        runnerCancellable = runner.$state
            .dropFirst()
            .sink { [weak self] state in
                guard let self, case .finished(let success) = state else { return }
                self.jobFinished(jobID: job.id, success: success, startedAt: startedAt, settings: settings)
            }

        try? FileManager.default.createDirectory(at: job.outputFolder, withIntermediateDirectories: true)
        startProgressSaveTimer()
        runner.run(audioURL: job.audioURL, settings: settings, numSpeakers: job.numSpeakers, outputFolder: job.outputFolder, context: job.context)
    }

    private func jobFinished(jobID: UUID, success: Bool, startedAt: Date, settings: AppSettings) {
        if let index = jobs.firstIndex(where: { $0.id == jobID }) {
            jobs[index].status = success ? .done : .failed
            jobs[index].processingDuration = Date().timeIntervalSince(startedAt)
            if !success {
                jobs[index].errorMessage = currentRunner?.logLines.suffix(5).joined(separator: "\n")
            }
        }
        stopProgressSaveTimer()
        runnerCancellable = nil
        currentRunner = nil
        currentJobID = nil
        save()
        processNext(settings: settings)
    }

    // MARK: - Résumé en lot ("rapide, en confiance")

    func generateAllSummaries(settings: AppSettings) {
        guard !isSummarizingAll else { return }
        summaryQueue = jobs.filter { $0.status == .done }
        guard !summaryQueue.isEmpty else { return }
        isSummarizingAll = true
        processNextSummary(settings: settings)
    }

    private func processNextSummary(settings: AppSettings) {
        guard !summaryQueue.isEmpty else {
            isSummarizingAll = false
            summaryCancellable = nil
            return
        }
        let job = summaryQueue.removeFirst()
        guard let input = findFile(in: job.outputFolder, suffix: "_final.txt")
            ?? findFile(in: job.outputFolder, suffix: "_transcript.json") else {
            processNextSummary(settings: settings)
            return
        }

        // dropFirst() : sans ça, l'état "finished" laissé par le job
        // précédent (même summaryRunner réutilisé) redéclencherait
        // immédiatement le traitement du job suivant.
        summaryCancellable = summaryRunner.$state
            .dropFirst()
            .sink { [weak self] state in
                guard let self, case .finished = state else { return }
                self.processNextSummary(settings: settings)
            }
        summaryRunner.run(transcriptPath: input, settings: settings, context: job.context)
    }

    private func findFile(in folder: URL, suffix: String) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.first(where: { $0.lastPathComponent.hasSuffix(suffix) })
    }

    // MARK: - Anti-veille

    private func preventSleep() {
        guard sleepAssertionID == 0 else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "TranscriptionTableRonde — traitement par lots" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            sleepAssertionID = id
        }
    }

    private func allowSleep() {
        guard sleepAssertionID != 0 else { return }
        IOPMAssertionRelease(sleepAssertionID)
        sleepAssertionID = 0
    }

    // MARK: - Persistance

    private func startProgressSaveTimer() {
        progressSaveTimer?.invalidate()
        progressSaveTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, let runner = self.currentRunner,
                  let index = self.jobs.firstIndex(where: { $0.status == .running }) else { return }
            self.jobs[index].lastProgressLabel = runner.progressLabel
            self.save()
        }
    }

    private func stopProgressSaveTimer() {
        progressSaveTimer?.invalidate()
        progressSaveTimer = nil
    }

    private func save() {
        let payload = PersistedQueue(jobs: jobs, isActive: isActive)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: queueFileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: queueFileURL),
              let payload = try? JSONDecoder().decode(PersistedQueue.self, from: data) else { return }
        // Un job "en cours" au dernier enregistrement correspond à un
        // plantage/fermeture en plein traitement : son travail n'a pas pu
        // se terminer proprement, il repart de zéro.
        jobs = payload.jobs.map { job in
            var j = job
            if j.status == .running {
                j.status = .pending
                j.lastProgressLabel = nil
            }
            return j
        }
        wasActiveOnLoad = payload.isActive
    }
}
