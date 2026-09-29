#!/usr/bin/env python3
"""
Convertit un transcript (JSON produit par le pipeline, ou corrigé dans la
fenêtre de vérification) en CSV prêt pour le codage et l'annotation dans un
tableur.

Colonnes produites :
    n            numéro d'ordre du segment
    locuteur     nom du locuteur (ou SPEAKER_xx si non renommé)
    debut        début au format hh:mm:ss, lisible
    fin          fin au format hh:mm:ss
    debut_s      début en secondes, pour trier et calculer
    fin_s        fin en secondes
    duree_s      durée du segment en secondes
    mots         nombre de mots, utile pour pondérer le temps de parole
    texte        le texte du segment

Les trois dernières colonnes sont laissées vides et nommées code_1, code_2,
code_3 : de la place pour annoter directement, sans avoir à insérer des
colonnes dans le tableur.

Par défaut le fichier est écrit pour Excel en français : séparateur
point-virgule et encodage UTF-8 avec BOM, faute de quoi Excel colle tout
dans une seule colonne et massacre les accents. Pour Numbers, LibreOffice
ou une lecture par script, `--style international` donne une virgule et de
l'UTF-8 sans BOM.

Usage :
    python3 transcript_to_csv.py --transcript sortie_reunion/reunion_transcript.json
    python3 transcript_to_csv.py --dossier ~/Enregistrements --style international
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

COLONNES = ["n", "locuteur", "debut", "fin", "debut_s", "fin_s", "duree_s",
            "mots", "texte", "code_1", "code_2", "code_3"]


def fmt_ts(seconds: float) -> str:
    total = max(0, int(seconds))
    return f"{total // 3600:02d}:{(total % 3600) // 60:02d}:{total % 60:02d}"


def lire_segments(chemin: Path) -> list[dict]:
    """Lit un transcript JSON. Accepte la liste de segments produite par le
    pipeline comme la variante enveloppée dans un objet, au cas où le
    format évoluerait."""
    with open(chemin, encoding="utf-8") as f:
        donnees = json.load(f)
    if isinstance(donnees, dict):
        for cle in ("segments", "transcript"):
            if isinstance(donnees.get(cle), list):
                return donnees[cle]
        raise ValueError("objet JSON sans liste de segments reconnaissable")
    if not isinstance(donnees, list):
        raise ValueError("le JSON ne contient ni liste ni objet de segments")
    return donnees


def convertir(source: Path, destination: Path, separateur: str, bom: bool) -> int:
    segments = lire_segments(source)

    encodage = "utf-8-sig" if bom else "utf-8"
    # newline="" : exigé par le module csv pour que les retours à la ligne
    # présents dans un texte soient correctement encadrés par des guillemets
    # plutôt que de casser la ligne du tableur.
    with open(destination, "w", encoding=encodage, newline="") as f:
        writer = csv.writer(f, delimiter=separateur, quoting=csv.QUOTE_MINIMAL)
        writer.writerow(COLONNES)

        for n, seg in enumerate(segments, 1):
            debut = float(seg.get("start") or 0)
            fin = float(seg.get("end") or 0)
            texte = (seg.get("text") or "").strip()
            writer.writerow([
                n,
                seg.get("speaker") or "INCONNU",
                fmt_ts(debut),
                fmt_ts(fin),
                f"{debut:.2f}",
                f"{fin:.2f}",
                f"{max(0.0, fin - debut):.2f}",
                len(texte.split()),
                texte,
                "", "", "",
            ])
    return len(segments)


def transcripts_du_dossier(dossier: Path) -> list[Path]:
    """Tous les transcripts sous ce dossier, y compris dans les sous-dossiers
    sortie_*. Le transcript corrigé prime sur l'original quand les deux
    existent."""
    trouves = sorted(dossier.rglob("*_transcript.json"))
    return [p for p in trouves if "_whisper_raw" not in p.name]


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Transcript JSON vers CSV pour codage et annotation")
    parser.add_argument("--transcript", help="Un fichier *_transcript.json")
    parser.add_argument("--dossier", help="Un dossier : convertit tous les transcripts trouves dedans")
    parser.add_argument("--output", help="Fichier CSV de sortie (un seul transcript ; defaut : a cote du JSON)")
    parser.add_argument("--style", default="excel-fr", choices=["excel-fr", "international"],
                        help="excel-fr : point-virgule et BOM (defaut). international : virgule, sans BOM.")
    args = parser.parse_args()

    if not args.transcript and not args.dossier:
        sys.exit("Erreur : indiquez --transcript ou --dossier.")
    if args.transcript and args.dossier:
        sys.exit("Erreur : --transcript et --dossier s'excluent.")
    if args.output and args.dossier:
        sys.exit("Erreur : --output ne vaut que pour un transcript unique.")

    separateur = ";" if args.style == "excel-fr" else ","
    bom = args.style == "excel-fr"

    if args.transcript:
        source = Path(args.transcript)
        if not source.exists():
            sys.exit(f"Erreur : fichier introuvable : {source}")
        sources = [source]
    else:
        dossier = Path(args.dossier)
        if not dossier.is_dir():
            sys.exit(f"Erreur : dossier introuvable : {dossier}")
        sources = transcripts_du_dossier(dossier)
        if not sources:
            sys.exit(f"Aucun fichier *_transcript.json trouve sous {dossier}")

    total = 0
    for source in sources:
        destination = Path(args.output) if args.output else source.with_suffix(".csv")
        try:
            n = convertir(source, destination, separateur, bom)
        except (json.JSONDecodeError, ValueError, OSError) as exc:
            print(f"  echec   {source.name} : {exc}")
            continue
        total += n
        print(f"  ok      {destination}  ({n} segments)")

    if len(sources) > 1:
        print(f"\n{len(sources)} transcripts convertis, {total} segments au total.")


if __name__ == "__main__":
    main()
