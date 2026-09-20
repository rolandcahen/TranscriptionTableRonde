import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Affiche l'avancement d'un job en cours. Vue séparée avec son propre
/// `@ObservedObject` sur le `PipelineRunner` du job actif : nécessaire pour
/// que les mises à jour de progression (imbriquées dans BatchQueueManager)
/// se propagent correctement à SwiftUI.
private struct RunningJobProgress: View {
    @ObservedObject var runner: PipelineRunner

    var body: some View {
        if let fraction = runner.progressFraction {
            ProgressView(value: fraction) {
                Text(runner.progressLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            ProgressView {
                Text(runner.progressLabel.isEmpty ? "Démarrage…" : runner.progressLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct BatchQueueView: View {
    @EnvironmentObject private var settings: AppSettings
    // Injecté depuis TranscriptionTableRondeApp — instance unique partagée,
    // volontairement pas un @StateObject local (voir commentaire dans
    // TranscriptionTableRondeApp.swift : un @StateObject ici recréerait un
    // gestionnaire de file indépendant à chaque nouvelle fenêtre).
    @EnvironmentObject private var queue: BatchQueueManager
    @Environment(\.openWindow) private var openWindow
    @State private var showClearConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if queue.jobs.isEmpty {
                Spacer()
                Text("Choisissez un dossier ou ajoutez des fichiers audio pour commencer.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                jobList
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 480)
        .navigationTitle("Traitement par lots")
        .onAppear {
            queue.resumeIfNeeded(settings: settings)
        }
        .confirmationDialog(
            "Vider la file d'attente ?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Vider la file", role: .destructive) { queue.clearQueue() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le job en cours sera interrompu et tous les jobs de la liste seront retirés. Les fichiers déjà transcrits restent sur le disque et ne sont pas supprimés.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Traitement par lots")
                    .font(.title3).bold()
                Spacer()
                Button("Choisir un dossier…") {
                    chooseFolder()
                }
                Button("Ajouter des fichiers…") {
                    addFiles()
                }
                Button(queue.isActive ? "Mettre en pause" : "Démarrer") {
                    if queue.isActive {
                        queue.pause()
                    } else {
                        queue.start(settings: settings)
                    }
                }
                .disabled(queue.jobs.isEmpty)
                Button(queue.isSummarizingAll ? "Résumés en cours…" : "Générer tous les résumés") {
                    queue.generateAllSummaries(settings: settings)
                }
                .disabled(queue.doneCount == 0 || queue.isSummarizingAll)
                Button("Vider la file", role: .destructive) {
                    showClearConfirm = true
                }
                .disabled(queue.jobs.isEmpty)
            }

            if !queue.jobs.isEmpty {
                ProgressView(value: queue.overallFraction) {
                    Text(summaryLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .progressViewStyle(.linear)
            }

            Label(
                "N'empêche pas la mise en veille au rabat de l'écran fermé (sans écran externe) — laissez l'écran ouvert ou branché pour un traitement de nuit fiable.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption2)
            .foregroundStyle(.orange)
        }
    }

    private var summaryLine: String {
        var parts = ["\(queue.doneCount) terminé(s)", "\(queue.runningCount) en cours", "\(queue.pendingCount) en attente"]
        if queue.failedCount > 0 {
            parts.append("\(queue.failedCount) échoué(s)")
        }
        return parts.joined(separator: " · ")
    }

    private var jobList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(queue.jobs) { job in
                    jobRow(job)
                }
            }
        }
    }

    private func jobRow(_ job: BatchJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                statusIcon(job.status)
                Text(job.audioURL.lastPathComponent)
                    .lineLimit(1)
                Spacer()
                if job.status == .failed {
                    Button("Réessayer") { queue.retry(job.id) }
                }
                if job.status == .done {
                    Button("Vérifier / corriger") { openReview(job) }
                    Button("Résumé") { generateSummary(job) }
                    Button("Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([job.outputFolder])
                    }
                }
                if job.status != .running {
                    Button {
                        queue.removeJob(job.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            if job.context != nil || job.numSpeakers != nil || job.duration != nil {
                Text(resolvedInfoLine(job))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if job.status == .running, job.id == queue.currentJobID, let runner = queue.currentRunner {
                RunningJobProgress(runner: runner)
            } else if job.status == .running, let label = job.lastProgressLabel {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if job.status == .failed, let error = job.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func resolvedInfoLine(_ job: BatchJob) -> String {
        var parts: [String] = []
        if let duration = job.duration {
            parts.append("durée \(formatDuration(duration))")
        }
        if job.context != nil {
            parts.append("contexte fourni")
        }
        if let n = job.numSpeakers {
            parts.append("\(n) locuteurs")
        }
        switch job.status {
        case .done:
            if let processing = job.processingDuration {
                parts.append("traité en \(formatDuration(processing))")
            }
        case .pending:
            if let estimate = queue.estimatedProcessingSeconds(for: job) {
                parts.append("≈ \(formatDuration(estimate)) estimées")
            }
        case .running, .failed:
            break
        }
        return parts.joined(separator: " · ")
    }

    /// Formatage court en français : "47 min" en dessous d'une heure,
    /// "1 h 12" au-delà — l'estimation n'a pas besoin d'une précision à la
    /// seconde près.
    private func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        if totalMinutes < 60 {
            return "\(max(totalMinutes, 1)) min"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes)"
    }

    private func statusIcon(_ status: BatchJobStatus) -> some View {
        let (name, color): (String, Color) = {
            switch status {
            case .pending: return ("circle.dashed", .secondary)
            case .running: return ("play.circle.fill", .blue)
            case .done: return ("checkmark.circle.fill", .green)
            case .failed: return ("xmark.circle.fill", .red)
            }
        }()
        return Image(systemName: name).foregroundStyle(color)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choisissez le dossier contenant les enregistrements à traiter"
        if !settings.recordingsFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: settings.recordingsFolder, isDirectory: true)
        }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        queue.scanFolder(folder, settings: settings)
    }

    /// Ajoute des fichiers audio choisis un par un (ou plusieurs à la fois),
    /// sans avoir à resélectionner tout un dossier — complément de
    /// "Choisir un dossier…" pour compléter une file déjà en cours.
    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        panel.message = "Choisissez un ou plusieurs fichiers audio à ajouter à la file"
        if !settings.recordingsFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: settings.recordingsFolder, isDirectory: true)
        }
        guard panel.runModal() == .OK else { return }
        queue.addFiles(panel.urls, settings: settings)
    }

    private func openReview(_ job: BatchJob) {
        guard let transcriptPath = findFile(in: job.outputFolder, suffix: "_transcript.json") else { return }
        openWindow(id: "review", value: ReviewTarget(transcriptURL: transcriptPath, audioURL: job.audioURL))
    }

    private func generateSummary(_ job: BatchJob) {
        guard let input = findFile(in: job.outputFolder, suffix: "_final.txt")
            ?? findFile(in: job.outputFolder, suffix: "_transcript.json") else { return }
        queue.summaryRunner.run(transcriptPath: input, settings: settings, context: job.context)
    }

    private func findFile(in folder: URL, suffix: String) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.first(where: { $0.lastPathComponent.hasSuffix(suffix) })
    }
}
