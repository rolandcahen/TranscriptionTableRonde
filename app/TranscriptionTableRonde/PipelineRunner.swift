import Foundation
import Combine

enum RunState: Equatable {
    case idle
    case running
    case finished(success: Bool)
}

/// Lance transcribe_diarize.py dans un sous-processus (le même script que
/// celui utilisé en ligne de commande) et publie sa sortie au fur et à
/// mesure, pour affichage en direct dans l'interface.
final class PipelineRunner: ObservableObject {
    @Published var state: RunState = .idle
    @Published var logLines: [String] = []
    @Published var outputFolder: URL?
    /// Avancement de l'étape en cours (0...1), ou nil quand aucune
    /// progression chiffrée n'est disponible (barre indéterminée).
    @Published var progressFraction: Double?
    @Published var progressLabel: String = ""

    private var process: Process?
    private var currentStage: Int = 0

    func run(audioURL: URL, settings: AppSettings, numSpeakers: Int?, outputFolder: URL, context: String? = nil) {
        guard state != .running else { return }

        logLines.removeAll()
        self.outputFolder = outputFolder
        currentStage = 0
        progressFraction = nil
        progressLabel = ""
        state = .running

        let process = Process()
        process.executableURL = URL(fileURLWithPath: settings.pythonPath)

        // Une app lancée depuis le Finder/Dock n'hérite pas du PATH du shell
        // (donc pas de /opt/homebrew/bin) : on l'ajoute explicitement pour
        // que le sous-processus (et ffmpeg, appelé par mlx-whisper) le trouve.
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        environment["PATH"] = extraPaths + ":" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")

        // torchcodec (utilisé par pyannote pour décoder l'audio) charge les
        // bibliothèques FFmpeg via @rpath, qui ne se résout pas tout seul
        // avec un FFmpeg installé par Homebrew : sans ce chemin explicite,
        // la diarisation échoue avec "Could not load libtorchcodec" /
        // "no LC_RPATH's found", même si FFmpeg est bien installé.
        let dyldPaths = "/opt/homebrew/lib:/opt/homebrew/opt/ffmpeg/lib:/usr/local/lib:/usr/local/opt/ffmpeg/lib"
        environment["DYLD_FALLBACK_LIBRARY_PATH"] = dyldPaths + ":" + (environment["DYLD_FALLBACK_LIBRARY_PATH"] ?? "")
        // Python met sa sortie standard en mémoire tampon quand elle n'est
        // pas connectée à un terminal (cas d'un Pipe) : sans ça, les
        // messages d'étape ("[2/3] Diarisation...") peuvent rester coincés
        // en mémoire de longues minutes pendant la diarisation, qui n'écrit
        // rien d'autre entre-temps — la barre de progression semble alors
        // figée. PYTHONUNBUFFERED force l'écriture immédiate.
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        var args = [
            settings.scriptPath,
            "--audio", audioURL.path,
            "--output", outputFolder.path,
            "--model", settings.defaultModel,
            "--hf-token", settings.hfToken,
        ]
        if let numSpeakers, numSpeakers > 0 {
            args += ["--num-speakers", String(numSpeakers)]
        }
        if let context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["--context", context]
        }
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        appendLine("$ python3 transcribe_diarize.py --audio \(audioURL.lastPathComponent) ...")

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.forwardOutput(handle)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.forwardOutput(handle)
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                self?.state = .finished(success: proc.terminationStatus == 0)
            }
        }

        self.process = process

        do {
            try process.run()
        } catch {
            appendLine("Erreur au lancement : \(error.localizedDescription)")
            appendLine("Vérifiez le chemin de l'interpréteur Python dans les Réglages.")
            state = .finished(success: false)
        }
    }

    func cancel() {
        process?.terminate()
    }

    private func forwardOutput(_ handle: FileHandle) {
        let data = handle.availableData
        guard !data.isEmpty else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.appendLine(text)
        }
    }

    private func appendLine(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines where !line.isEmpty {
            let lineString = String(line)
            logLines.append(lineString)
            updateProgress(for: lineString)
        }
    }

    /// Déduit une progression des messages d'étape ("[1/3] ..."), des
    /// barres tqdm de mlx-whisper ("46%|...frames/s]") et des lignes de
    /// progression de la diarisation émises par le script
    /// ("      Diarisation 42% — empreintes vocales", voir la classe
    /// DiarizationProgress dans transcribe_diarize.py). Seule l'étape 3,
    /// très courte, reste indéterminée.
    private func updateProgress(for line: String) {
        if line.hasPrefix("[1/3]") {
            currentStage = 1
            progressFraction = 0
            progressLabel = "Étape 1/3 — Transcription"
            return
        }
        if line.hasPrefix("[2/3]") {
            currentStage = 2
            progressFraction = 0
            progressLabel = "Étape 2/3 — Diarisation (identification des locuteurs)"
            return
        }
        if line.hasPrefix("[3/3]") {
            currentStage = 3
            progressFraction = nil
            progressLabel = "Étape 3/3 — Fusion et écriture des fichiers"
            return
        }
        if line.hasPrefix("Terminé.") {
            progressFraction = 1
            return
        }

        if currentStage == 2, let (percent, phase) = diarizationProgress(in: line) {
            progressFraction = Double(percent) / 100
            progressLabel = "Étape 2/3 — Diarisation · \(phase)"
            return
        }

        guard currentStage == 1, line.contains("frames/s"), let percent = tqdmPercent(in: line) else { return }
        progressFraction = Double(percent) / 100
    }

    private func tqdmPercent(in line: String) -> Int? {
        guard let range = line.range(of: "%|") else { return nil }
        return Int(line[..<range.lowerBound].trimmingCharacters(in: .whitespaces))
    }

    /// Relit une ligne "Diarisation 42% — empreintes vocales" et en extrait
    /// le pourcentage global de l'étape 2 et le nom de la phase en cours.
    /// Retourne nil pour les lignes sans pourcentage (annonce d'une phase
    /// qui n'expose pas d'avancement chiffré), qui laissent la barre où
    /// elle en est plutôt que de la faire reculer.
    private func diarizationProgress(in line: String) -> (Int, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("Diarisation ") else { return nil }
        let rest = trimmed.dropFirst("Diarisation ".count)
        guard let percentEnd = rest.firstIndex(of: "%"),
              let percent = Int(rest[..<percentEnd].trimmingCharacters(in: .whitespaces)) else { return nil }
        let phase = rest[rest.index(after: percentEnd)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " —-"))
        return (percent, phase.isEmpty ? "en cours" : phase)
    }
}
