import SwiftUI
import AppKit

/// Les trois signatures institutionnelles du projet.
///
/// Les hauteurs diffèrent volontairement d'un logo à l'autre : le bloc du
/// CRD est purement typographique et sur quatre niveaux de corps, là où le
/// Sepsis Center a un symbole et l'ENS Paris-Saclay une composition très
/// horizontale. À hauteur égale, le CRD deviendrait une texture grise
/// illisible. Ces valeurs sont donc des hauteurs *optiques*, calibrées à
/// l'œil, pas une normalisation géométrique.
struct SignaturesView: View {
    var hauteurCRD: CGFloat = 48
    var hauteurENS: CGFloat = 32
    var hauteurSepsis: CGFloat = 44
    var espacement: CGFloat = 14

    var body: some View {
        HStack(alignment: .center, spacing: espacement) {
            logo("LogoCRD",
                 hauteur: hauteurCRD,
                 description: "Centre de Recherche en Design — ENSCI-Les Ateliers / École normale supérieure Paris-Saclay")
            logo("LogoENSParisSaclay",
                 hauteur: hauteurENS,
                 description: "École normale supérieure Paris-Saclay — Université Paris-Saclay")
            logo("LogoSepsis",
                 hauteur: hauteurSepsis,
                 description: "Comprehensive Sepsis Center")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Signatures institutionnelles")
    }

    private func logo(_ nom: String, hauteur: CGFloat, description: String) -> some View {
        Image(nom)
            .resizable()
            .scaledToFit()
            .frame(height: hauteur)
            .accessibilityLabel(description)
            .help(description)
    }
}

/// Une ligne de la notice, avec le style déduit de sa syntaxe Markdown.
/// Un rendu Markdown complet serait disproportionné ici : la notice n'a
/// besoin que de titres, de listes et de blocs de code lisibles.
private struct LigneNotice: Identifiable {
    enum Style {
        case titre1, titre2, titre3, code, liste, normale, vide
    }

    let id: Int
    let texte: String
    let style: Style

    static func analyser(_ markdown: String) -> [LigneNotice] {
        var lignes: [LigneNotice] = []
        var dansUnBlocDeCode = false

        for (index, brute) in markdown.components(separatedBy: "\n").enumerated() {
            if brute.hasPrefix("```") {
                dansUnBlocDeCode.toggle()
                continue
            }

            let style: Style
            if dansUnBlocDeCode {
                style = .code
            } else if brute.hasPrefix("### ") {
                style = .titre3
            } else if brute.hasPrefix("## ") {
                style = .titre2
            } else if brute.hasPrefix("# ") {
                style = .titre1
            } else if brute.hasPrefix("- ") || brute.hasPrefix("* ") {
                style = .liste
            } else if brute.trimmingCharacters(in: .whitespaces).isEmpty {
                style = .vide
            } else {
                style = .normale
            }

            lignes.append(LigneNotice(id: index, texte: brute, style: style))
        }
        return lignes
    }

    /// Texte débarrassé de ses marqueurs de structure (dièses, puces).
    var contenu: String {
        switch style {
        case .titre1: return String(texte.dropFirst(2))
        case .titre2: return String(texte.dropFirst(3))
        case .titre3: return String(texte.dropFirst(4))
        case .liste: return String(texte.dropFirst(2))
        default: return texte
        }
    }
}

/// Fenêtre « À propos » : identité de l'app, signatures institutionnelles,
/// crédits, et la notice d'utilisation complète embarquée dans l'app —
/// pour qu'elle reste consultable hors ligne et sans chercher le dépôt.
struct AboutView: View {
    @State private var notice: String?

    private var version: String {
        let court = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (court, build) {
        case let (.some(c), .some(b)): return "Version \(c) (\(b))"
        case let (.some(c), .none): return "Version \(c)"
        default: return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            identite
            SignaturesView()
            Text("Conception et développement avec Claude Code : Roland Cahen")
                .font(.callout)
            Divider()
            Text("Notice d'utilisation")
                .font(.headline)
            noticeDefilante
        }
        .padding(20)
        .frame(width: 660, height: 740)
        .onAppear(perform: chargerNotice)
    }

    private var identite: some View {
        HStack(alignment: .top, spacing: 16) {
            // NSImage(named:) plutôt que NSApp.applicationIconImage : le
            // premier renvoie un optionnel franc, le second un optionnel
            // implicitement déballé dont le traitement varie selon le SDK.
            if let icone = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: icone)
                    .resizable()
                    .frame(width: 72, height: 72)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription table ronde")
                    .font(.title2).bold()
                if !version.isEmpty {
                    Text(version)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Transcription, diarisation et résumé structuré, entièrement locaux : aucun enregistrement ne quitte cette machine.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var noticeDefilante: some View {
        if let notice, !notice.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(LigneNotice.analyser(notice)) { ligne in
                        vue(pour: ligne)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .textSelection(.enabled)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("La notice n'a pas pu être chargée depuis l'application.")
                    .foregroundStyle(.secondary)
                Link("Consulter la notice en ligne",
                     destination: URL(string: "https://github.com/rolandcahen/TranscriptionTableRonde/blob/main/docs/NOTICE.md")!)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func vue(pour ligne: LigneNotice) -> some View {
        switch ligne.style {
        case .titre1:
            Text(ligne.contenu)
                .font(.title3).bold()
                .padding(.top, 10)
        case .titre2:
            Text(ligne.contenu)
                .font(.headline)
                .padding(.top, 8)
        case .titre3:
            Text(ligne.contenu)
                .font(.subheadline).bold()
                .padding(.top, 6)
        case .code:
            Text(ligne.texte)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        case .liste:
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                Text(.init(ligne.contenu))
            }
            .font(.callout)
        case .normale:
            Text(.init(ligne.texte))
                .font(.callout)
        case .vide:
            Spacer().frame(height: 6)
        }
    }

    private func chargerNotice() {
        guard notice == nil else { return }
        guard let url = Bundle.main.url(forResource: "NOTICE", withExtension: "md"),
              let texte = try? String(contentsOf: url, encoding: .utf8) else { return }
        notice = texte
    }
}
