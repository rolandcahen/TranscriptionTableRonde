import Foundation
import Combine

/// Lance summarize.py (résumé structuré via Ollama, en local) en
/// sous-processus, sur le même principe que PipelineRunner. summarize.py
/// ne produit pas de barre de progression tqdm : pas de parsing de
/// progression ici, juste le journal et le résultat final.
final class SummaryRunner: ObservableObject {
    @Published var state: RunState = .idle
    @Published var logLines: [String] = []
    @Published var resumeMarkdownPath: URL?

    private var process: Process?

    func run(transcriptPath: URL, settings: AppSettings, categoriesArgument: String? = nil, context: String? = nil) {
        guard state != .running else { return }

        logLines.removeAll()
        resumeMarkdownPath = nil
        state = .running

        let process = Process()
        process.executableURL = URL(fileURLWithPath: settings.pythonPath)

        // Cf. PipelineRunner : une app lancée depuis le Finder/Dock n'hérite
        // pas du PATH du shell (donc pas de /opt/homebrew/bin), et Python
        // met sa sortie en mémoire tampon quand elle n'est pas connectée à
        // un terminal (cf. PipelineRunner pour le détail).
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        environment["PATH"] = extraPaths + ":" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        let scriptPath = (settings.pipelineFolder as NSString).appendingPathComponent("summarize.py")
        var args = [scriptPath, "--input", transcriptPath.path]
        if let categoriesArgument, !categoriesArgument.isEmpty {
            args += ["--categories", categoriesArgument]
        }
        if let context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["--context", context]
        }
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        appendLine("$ python3 summarize.py --input \(transcriptPath.lastPathComponent) ...")

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
            if lineString.hasPrefix("RESUME_MD:") {
                resumeMarkdownPath = URL(fileURLWithPath: String(lineString.dropFirst("RESUME_MD:".count)))
            }
        }
    }
}
