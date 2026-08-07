#!/usr/bin/env python3
"""
Résumé structuré d'un transcript (table ronde / atelier) via un LLM local
(Ollama + Mistral, aucune donnée envoyée en ligne).

Entrée : soit un fichier *_final.txt (transcript renommé, produit par
rename_speakers.py ou l'éditeur de vérification de l'app), soit un fichier
*_transcript.json (labels SPEAKER_00, produit directement par
transcribe_diarize.py).

Le transcript est découpé en tranches (le contexte d'un modèle 7B local est
limité). Deux passes distinctes, volontairement séparées :

    1. Résumé ("map") : chaque tranche est synthétisée en prose, avec ses
       propres mots — pas d'extraction de citations. Demander à un petit
       modèle local d'extraire ET de trier en catégories en une seule passe
       le pousse à recopier des bouts de phrases au hasard plutôt qu'à
       vraiment résumer (constaté empiriquement).
    2. Structuration ("reduce") : les résumés de chaque tranche, déjà propres
       et courts, sont ensuite réorganisés dans les catégories cibles en une
       seule passe — bien plus fiable que structurer directement le
       transcript brut.

Catégories personnalisables via --categories (sinon les 8 par défaut
ci-dessous) : "slug1:Titre 1;slug2:Titre 2;...".

Sorties, dans le même dossier que l'entrée :
    <basename>_resume.json  — structuré, réutilisable par un outil externe
    <basename>_resume.md    — mise en forme lisible (une section par catégorie)

Utilisation :
    python summarize.py --input sortie/reunion_final.txt
    python summarize.py --input sortie/reunion_transcript.json --model mistral
    python summarize.py --input sortie/reunion_final.txt \\
        --categories "contexte:Contexte;decisions:Décisions;actions:Actions à mener"
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_CATEGORIES = {
    "etat_de_la_recherche": "État de la recherche",
    "questions": "Questions posées",
    "reponses": "Réponses apportées",
    "difficultes": "Difficultés mises en avant",
    "propositions_developpement": "Propositions de développement",
    "implications_techniques": "Implications techniques",
    "implications_financieres": "Implications financières",
    "autres_elements": "Autres éléments pertinents",
}

TIMESTAMP_HEADER_RE = re.compile(r"^\[(\d{2}:\d{2}:\d{2}) - (\d{2}:\d{2}:\d{2})\] (.+)$")


def parse_categories(arg: str | None) -> dict[str, str]:
    if not arg:
        return DEFAULT_CATEGORIES
    result: dict[str, str] = {}
    for part in arg.split(";"):
        part = part.strip()
        if not part or ":" not in part:
            continue
        slug, title = part.split(":", 1)
        slug, title = slug.strip(), title.strip()
        if slug and title:
            result[slug] = title
    return result or DEFAULT_CATEGORIES


def load_blocks(input_path: Path) -> list[dict]:
    """Charge le transcript en une liste uniforme de blocs
    {"start": str|None, "end": str|None, "speaker": str, "text": str}."""
    if input_path.suffix == ".json":
        segments = json.loads(input_path.read_text(encoding="utf-8"))
        return [
            {
                "start": fmt_ts(seg["start"]),
                "end": fmt_ts(seg["end"]),
                "speaker": seg.get("speaker", "INCONNU"),
                "text": seg["text"].strip(),
            }
            for seg in segments
        ]

    blocks = []
    for raw_block in input_path.read_text(encoding="utf-8").strip().split("\n\n"):
        lines = raw_block.strip().split("\n", 1)
        if len(lines) != 2:
            continue
        header, text = lines
        match = TIMESTAMP_HEADER_RE.match(header.strip())
        if not match:
            continue
        start, end, speaker = match.groups()
        blocks.append({"start": start, "end": end, "speaker": speaker, "text": text.strip()})
    return blocks


def fmt_ts(seconds: float) -> str:
    seconds = max(0.0, seconds)
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


def block_to_line(block: dict) -> str:
    return f"[{block['start']}] {block['speaker']} : {block['text']}"


def chunk_blocks(blocks: list[dict], chunk_words: int) -> list[list[dict]]:
    """Regroupe les blocs consécutifs en tranches d'environ chunk_words mots,
    sans jamais couper un bloc en deux."""
    chunks: list[list[dict]] = []
    current: list[dict] = []
    current_words = 0
    for block in blocks:
        block_words = len(block["text"].split())
        if current and current_words + block_words > chunk_words:
            chunks.append(current)
            current = []
            current_words = 0
        current.append(block)
        current_words += block_words
    if current:
        chunks.append(current)
    return chunks


def call_ollama(prompt: str, model: str, ollama_url: str, json_mode: bool) -> str:
    payload = json.dumps(
        {
            "model": model,
            "prompt": prompt,
            **({"format": "json"} if json_mode else {}),
            "stream": False,
            "options": {"num_ctx": 8192, "temperature": 0.3 if not json_mode else 0.2},
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        f"{ollama_url}/api/generate",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=600) as response:
            body = json.loads(response.read().decode("utf-8"))
    except urllib.error.URLError as exc:
        sys.exit(
            f"Erreur : impossible de contacter Ollama sur {ollama_url} ({exc}).\n"
            "Vérifiez qu'Ollama est lancé (ouvrez l'app Ollama, ou lancez "
            "'ollama serve' dans un terminal) et que le modèle est bien "
            f"téléchargé ('ollama pull {model}')."
        )
    return body.get("response", "")


_ABSENCE_MARKERS = (
    "n'est pas mentionn", "pas mentionn", "non mentionn", "n'a pas été mentionn",
    "ne sont pas mentionn", "pas explicitement", "aucun élément", "n'est pas abord",
    "pas concernée", "n'a pas été abord",
)


def _is_absence_filler(text: str) -> bool:
    """Filet de sécurité : malgré la consigne, un modèle 7B explique parfois
    l'absence au lieu de laisser une liste vide. On filtre ces phrases."""
    low = text.lower()
    return any(marker in low for marker in _ABSENCE_MARKERS)


def parse_json_result(raw: str, categories: dict[str, str]) -> dict | None:
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(parsed, dict):
        return None
    result = {slug: [] for slug in categories}
    for slug in categories:
        value = parsed.get(slug, [])
        if isinstance(value, list):
            result[slug] = [
                str(item).strip() for item in value
                if str(item).strip() and not _is_absence_filler(str(item))
            ]
    return result


def _context_block(context: str | None) -> str:
    if not context:
        return ""
    return (
        f"Contexte de cette réunion (sujet, participants, organismes, termes "
        f"techniques) — utilise-le pour bien interpréter les noms propres et "
        f"termes spécifiques, y compris s'ils semblent mal transcrits dans "
        f"l'extrait :\n{context}\n\n"
    )


def build_map_prompt(chunk_text: str, context: str | None) -> str:
    return f"""{_context_block(context)}Voici un extrait de la transcription d'une réunion ou d'une table ronde (chaque ligne commence par un horodatage et le nom du locuteur) :

---
{chunk_text}
---

Résume fidèlement ce qui a été dit dans cet extrait, en synthétisant avec tes propres mots — ne recopie pas de phrases entières telles quelles, et ne mentionne pas les horodatages. Sois concis mais informatif : entre 6 et 12 phrases, en paragraphes, en français correct. Reste fidèle au contenu : ne rapporte que ce qui est réellement dit, sans inventer de faits."""


def build_reduce_prompt(chunk_summaries: list[str], categories: dict[str, str], context: str | None) -> str:
    joined = "\n\n".join(f"[Partie {i + 1}]\n{s}" for i, s in enumerate(chunk_summaries))
    categories_desc = "\n".join(f"- {slug} : {title}" for slug, title in categories.items())
    keys_list = ", ".join(f'"{slug}"' for slug in categories)
    return f"""{_context_block(context)}Voici le résumé, en plusieurs parties successives, d'un enregistrement de réunion ou de table ronde :

---
{joined}
---

Réorganise ce contenu dans les catégories suivantes, en synthétisant avec tes propres mots (pas de recopie mot à mot) : pour chaque catégorie concernée, écris 1 à 3 phrases complètes et bien formées en français. Si une catégorie n'est pas concernée par le contenu, laisse sa liste vide — n'écris jamais de phrase expliquant qu'elle est absente ou non mentionnée.

Catégories :
{categories_desc}

Réponds UNIQUEMENT avec un objet JSON valide ayant exactement ces clés : {keys_list}. Chaque valeur est une liste de phrases synthétiques en français (liste vide si non concernée)."""


def summarize(blocks: list[dict], model: str, ollama_url: str, chunk_words: int, categories: dict[str, str], context: str | None) -> dict:
    chunks = chunk_blocks(blocks, chunk_words)
    print(f"[1/2] Résumé de {len(chunks)} tranche(s) avec {model}...")

    chunk_summaries = []
    for i, chunk in enumerate(chunks, start=1):
        print(f"      tranche {i}/{len(chunks)}...")
        chunk_text = "\n".join(block_to_line(b) for b in chunk)
        prompt = build_map_prompt(chunk_text, context)
        summary_text = call_ollama(prompt, model, ollama_url, json_mode=False)
        chunk_summaries.append(summary_text.strip())

    print("[2/2] Structuration par catégories...")
    prompt = build_reduce_prompt(chunk_summaries, categories, context)
    raw = call_ollama(prompt, model, ollama_url, json_mode=True)
    result = parse_json_result(raw, categories)
    if result is None:
        print("      avertissement : réponse JSON invalide, nouvelle tentative...")
        raw = call_ollama(
            prompt + "\n\nRappel : réponds uniquement avec le JSON, sans aucun texte autour.",
            model, ollama_url, json_mode=True,
        )
        result = parse_json_result(raw, categories) or {slug: [] for slug in categories}
    return result


def write_markdown(basename: str, result: dict, categories: dict[str, str], md_path: Path):
    lines = [f"# Résumé structuré — {basename}", ""]
    for slug, title in categories.items():
        lines.append(f"## {title}")
        items = result.get(slug, [])
        if not items:
            lines.append("_Aucun élément identifié._")
        else:
            lines.extend(f"- {item}" for item in items)
        lines.append("")
    md_path.write_text("\n".join(lines), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="Résumé structuré d'un transcript via Ollama (local)")
    parser.add_argument("--input", required=True, help="Fichier *_final.txt ou *_transcript.json")
    parser.add_argument("--output", default=None, help="Dossier de sortie (défaut : même dossier que --input)")
    parser.add_argument("--model", default="mistral", help="Modèle Ollama à utiliser (défaut : mistral)")
    parser.add_argument("--ollama-url", default="http://localhost:11434", help="URL du serveur Ollama")
    parser.add_argument("--chunk-words", type=int, default=3000, help="Taille approximative des tranches, en mots (défaut : 3000)")
    parser.add_argument("--categories", default=None, help='Catégories cibles : "slug1:Titre 1;slug2:Titre 2;..." (défaut : les 8 catégories standard)')
    parser.add_argument(
        "--context",
        default=None,
        help="Contexte de la réunion (sujet, participants, organismes, termes techniques). "
        "Si absent, recherché automatiquement dans <dossier>/*_contexte.txt (écrit par "
        "transcribe_diarize.py --context).",
    )
    args = parser.parse_args()

    input_path = Path(args.input)
    if not input_path.exists():
        sys.exit(f"Erreur : fichier introuvable : {input_path}")
    if input_path.suffix not in (".txt", ".json"):
        sys.exit("Erreur : --input doit être un fichier *_final.txt ou *_transcript.json")

    categories = parse_categories(args.categories)

    context = args.context
    if not context:
        context_files = list(input_path.parent.glob("*_contexte.txt"))
        if context_files:
            context = context_files[0].read_text(encoding="utf-8").strip()
            print(f"Contexte trouvé : {context_files[0].name}")

    out_dir = Path(args.output) if args.output else input_path.parent
    out_dir.mkdir(parents=True, exist_ok=True)

    basename = input_path.stem
    for suffix in ("_final", "_transcript"):
        if basename.endswith(suffix):
            basename = basename[: -len(suffix)]
            break

    blocks = load_blocks(input_path)
    if not blocks:
        sys.exit(f"Erreur : aucun contenu exploitable trouvé dans {input_path}")

    result = summarize(blocks, args.model, args.ollama_url, args.chunk_words, categories, context)

    json_path = out_dir / f"{basename}_resume.json"
    json_path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")

    md_path = out_dir / f"{basename}_resume.md"
    write_markdown(basename, result, categories, md_path)

    print("\nTerminé. Fichiers générés :")
    print(f"  - {md_path}   (résumé lisible)")
    print(f"  - {json_path}  (données structurées)")
    print(f"RESUME_MD:{md_path}")
    print(f"RESUME_JSON:{json_path}")


if __name__ == "__main__":
    main()
