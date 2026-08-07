#!/usr/bin/env python3
"""
Deuxième passe : remplace les étiquettes génériques (SPEAKER_00, ...) par les
vrais noms des participants, une fois que vous les avez identifiés.

Marche à suivre :
    1. Ouvrez le fichier <base>_speakers.json généré par transcribe_diarize.py
    2. Remplissez le champ "nom" de chaque locuteur (aidez-vous du champ
       "premiere_intervention" et/ou d'une écoute rapide de l'audio à
       l'horodatage indiqué)
    3. Lancez :
       python rename_speakers.py \
           --transcript sortie/reunion_transcript.json \
           --speakers sortie/reunion_speakers.json \
           --output sortie/reunion_final.txt
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def fmt_ts(seconds: float) -> str:
    seconds = max(0.0, seconds)
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


def main():
    parser = argparse.ArgumentParser(description="Renomme les locuteurs dans un transcript diarisé")
    parser.add_argument("--transcript", required=True, help="Fichier *_transcript.json")
    parser.add_argument("--speakers", required=True, help="Fichier *_speakers.json (complété avec les noms)")
    parser.add_argument("--output", required=True, help="Fichier texte final à générer")
    args = parser.parse_args()

    segments = json.loads(Path(args.transcript).read_text(encoding="utf-8"))
    speakers_map = json.loads(Path(args.speakers).read_text(encoding="utf-8"))

    missing = [sp for sp, info in speakers_map.items() if not info.get("nom", "").strip()]
    if missing:
        print(f"Attention : locuteurs sans nom renseigné (étiquette d'origine conservée) : {', '.join(missing)}")

    out_path = Path(args.output)
    with open(out_path, "w", encoding="utf-8") as f:
        for seg in segments:
            speaker_id = seg["speaker"]
            nom = speakers_map.get(speaker_id, {}).get("nom", "").strip() or speaker_id
            f.write(f"[{fmt_ts(seg['start'])} - {fmt_ts(seg['end'])}] {nom}\n")
            f.write(seg["text"].strip() + "\n\n")

    print(f"Transcript final écrit : {out_path}")


if __name__ == "__main__":
    main()
