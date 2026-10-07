#!/usr/bin/env python3
"""
Mesure, sur un transcript déjà produit, ce qui ne va pas — et surtout dans
quelle proportion, pour savoir si une correction coûteuse mérite d'être
construite avant de la construire.

Deux familles de défauts, à ne pas confondre parce qu'elles n'ont pas les
mêmes remèdes : l'attribution des locuteurs (diarisation et alignement) et
la transcription elle-même (inventions de Whisper, boucles de répétition).
Le même passage illisible peut relever de l'une ou de l'autre.

Chaque segment porte depuis align.py la part de sa durée réellement occupée
par le locuteur retenu (`speaker_share`) et la part où plusieurs personnes
parlent en même temps (`overlap_share`). Ce script en fait une distribution :
combien de segments sont parfaitement nets, combien sont à cheval, et quelle
proportion du temps de parole cela représente.

À quoi ça sert concrètement : savoir si une correction automatique coûteuse
vaut la peine d'être construite. Si 2 % du temps de parole est douteux, une
relecture ciblée suffit. Si c'est 25 %, le problème est structurel et mérite
qu'on y consacre du calcul.

Usage :
    python3 diagnostic_attribution.py sortie_reunion/reunion_transcript.json
    python3 diagnostic_attribution.py sortie_reunion/ --pires 20
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from qualite_transcription import CAUSES

# Seuils d'interprétation. 0.95 : un segment peut mordre très légèrement sur
# le tour suivant sans que cela change un mot du transcript. En dessous de
# 0.80, une part appréciable du texte appartient à quelqu'un d'autre. En
# dessous de 0.60, l'attribution elle-même est un pari.
SEUILS = [
    (0.95, "quasi certains", "rien à faire"),
    (0.80, "légèrement à cheval", "souvent sans conséquence"),
    (0.60, "franchement à cheval", "à vérifier"),
    (0.00, "attribution incertaine", "à réécouter"),
]


def fmt_ts(secondes: float) -> str:
    total = max(0, int(secondes))
    return f"{total // 3600:02d}:{(total % 3600) // 60:02d}:{total % 60:02d}"


def charger(chemin: Path) -> list[dict]:
    donnees = json.loads(chemin.read_text(encoding="utf-8"))
    if isinstance(donnees, dict):
        donnees = donnees.get("segments") or donnees.get("transcript") or []
    if not isinstance(donnees, list):
        sys.exit(f"Erreur : format inattendu dans {chemin}")
    return donnees


def transcripts(cible: Path) -> list[Path]:
    if cible.is_dir():
        trouves = sorted(p for p in cible.rglob("*_transcript.json")
                         if "_whisper_raw" not in p.name)
        if not trouves:
            sys.exit(f"Aucun *_transcript.json sous {cible}")
        return trouves
    if not cible.exists():
        sys.exit(f"Erreur : fichier introuvable : {cible}")
    return [cible]


def analyser(chemin: Path, nb_pires: int) -> None:
    segments = charger(chemin)
    if not segments:
        print(f"\n{chemin.name} : aucun segment.")
        return

    mesures = [s for s in segments if "speaker_share" in s]
    if not mesures:
        print(f"\n{chemin.name} : transcript produit avant la mesure de fiabilité.")
        print("  Relancez la transcription pour obtenir ces indicateurs — ou, si la")
        print("  diarisation est encore en cache, seule l'étape 3 sera refaite.")
        return

    duree_totale = sum(max(0.0, s["end"] - s["start"]) for s in mesures)
    if duree_totale <= 0:
        print(f"\n{chemin.name} : durée totale nulle.")
        return

    print(f"\n{'=' * 72}")
    print(f"{chemin.name} — {len(segments)} segments, {fmt_ts(duree_totale)} au total")
    print("=" * 72)

    # Les segments où la diarisation n'entend aucune parole sont écartés de la
    # distribution : leur attribution n'est pas « douteuse », elle n'existe
    # pas. Les y laisser noyait le diagnostic sous des 0 % qui ne disaient
    # rien de la diarisation et tout de la transcription.
    # On garde la liste entière de côté : la qualité de transcription se
    # juge sur tous les segments, et c'est précisément parmi les muets que
    # se trouvent les inventions les plus nettes.
    tous = mesures
    muets = [s for s in mesures if s.get("speech_share") == 0]
    mesures = [s for s in mesures if s.get("speech_share") != 0]
    if muets:
        temps_muet = sum(max(0.0, s["end"] - s["start"]) for s in muets)
        avec_texte = [s for s in muets if (s.get("text") or "").strip()]
        print(f"\nSegments sans aucune parole détectée : {len(muets)} "
              f"({fmt_ts(temps_muet)}), dont {len(avec_texte)} porteurs de texte.")
        print("Ceux-là relèvent de la transcription, pas de l'attribution : du texte")
        print("écrit là où la diarisation n'entend personne est presque toujours une")
        print("invention de Whisper sur du silence ou du bruit.")

    if not mesures:
        print("\nAucun segment avec de la parole détectée.")
        _qualite_transcription(tous, duree_totale, nb_pires)
        return
    duree_totale = sum(max(0.0, s["end"] - s["start"]) for s in mesures)

    entete = "netteté de l'attribution"
    print(f"\nParmi les {len(mesures)} segments contenant de la parole :")
    print(f"\n{entete:34s} {'segments':>10s} {'temps':>10s} {'part':>7s}")
    print("-" * 72)
    borne_haute = 1.01
    for seuil, libelle, commentaire in SEUILS:
        lot = [s for s in mesures if seuil <= s["speaker_share"] < borne_haute]
        temps = sum(max(0.0, s["end"] - s["start"]) for s in lot)
        etiquette = f"≥ {seuil:.2f}  {libelle}" if seuil else f"< 0.60  {libelle}"
        print(f"{etiquette:34s} {len(lot):10d} {fmt_ts(temps):>10s} "
              f"{100 * temps / duree_totale:6.1f}%")
        borne_haute = seuil

    douteux = [s for s in mesures if s["speaker_share"] < 0.80]
    temps_douteux = sum(max(0.0, s["end"] - s["start"]) for s in douteux)

    avec_chevauchement = [s for s in mesures if s.get("overlap_share", 0) > 0.05]
    temps_chevauchement = sum(
        max(0.0, s["end"] - s["start"]) * s.get("overlap_share", 0)
        for s in mesures
    )

    silencieux = [s for s in mesures if s.get("speech_share", 1.0) < 0.4]
    print("-" * 72)
    print(f"À vérifier (netteté < 0.80) : {len(douteux)} segments, "
          f"{fmt_ts(temps_douteux)} — {100 * temps_douteux / duree_totale:.1f}% du temps.")
    if silencieux:
        print(f"Pour information, {len(silencieux)} segments sont majoritairement du")
        print("silence (moins de 40% de parole) : c'est le découpage large de Whisper,")
        print("pas un défaut d'attribution.")
    print(f"Parole réellement simultanée : {fmt_ts(temps_chevauchement)} "
          f"({100 * temps_chevauchement / duree_totale:.1f}%), "
          f"répartie sur {len(avec_chevauchement)} segments.")

    # Deux causes très différentes se cachent derrière une netteté faible, et
    # elles n'appellent pas le même remède : un segment à cheval sur deux
    # tours successifs se répare en le coupant, deux voix superposées ne se
    # réparent pas du tout.
    a_cheval = [s for s in douteux if s.get("overlap_share", 0) <= 0.05]
    superposes = [s for s in douteux if s.get("overlap_share", 0) > 0.05]
    print(f"   dont {len(a_cheval)} à cheval sur deux tours successifs (réparables par découpe)")
    print(f"   dont {len(superposes)} avec parole superposée (non réparables sans séparation de sources)")

    _qualite_transcription(tous, duree_totale, nb_pires)

    if nb_pires and douteux:
        print(f"\nLes {min(nb_pires, len(douteux))} segments les moins nets, à réécouter :")
        print("-" * 72)
        for s in sorted(douteux, key=lambda s: s["speaker_share"])[:nb_pires]:
            second = s.get("speaker_alt") or "—"
            texte = " ".join((s.get("text") or "").split())[:52]
            chevauche = "≈" if s.get("overlap_share", 0) > 0.05 else " "
            print(f"  [{fmt_ts(s['start'])}] {s['speaker']:>12s} {100 * s['speaker_share']:3.0f}% "
                  f"{chevauche} {second:>12s}  {texte}")
        print("  (« ≈ » marque une parole réellement simultanée ; sans lui, les deux")
        print("   locuteurs se succèdent et la coupure est au mauvais endroit.)")


def _qualite_transcription(segments: list[dict], duree_totale: float, nb_pires: int) -> None:
    """Défauts propres à Whisper, par opposition aux défauts d'attribution.

    Les deux familles se mélangent à la lecture — un passage incompréhensible
    peut l'être parce que deux personnes parlent ensemble, ou parce que
    Whisper a inventé — mais elles n'ont pas les mêmes remèdes. Les séparer
    ici évite de chercher du côté de la diarisation ce qui relève de la
    transcription, et réciproquement.
    """
    suspects = [s for s in segments if s.get("suspect")]
    replies = [s for s in segments if s.get("repeats_removed")]
    if not suspects and not replies:
        print("\nTranscription : aucun segment signalé comme douteux, aucune boucle de répétition.")
        return

    temps_suspect = sum(max(0.0, s["end"] - s["start"]) for s in suspects)
    mots_retires = sum(s.get("repeats_removed", 0) for s in replies)

    print("\nQualité de transcription (indépendante des locuteurs)")
    print("-" * 72)
    print(f"Segments signalés comme douteux : {len(suspects)} — {fmt_ts(temps_suspect)} "
          f"({100 * temps_suspect / duree_totale:.1f}% du temps de parole)")
    if replies:
        print(f"Boucles de répétition repliées : {len(replies)} segments, "
              f"{mots_retires} mots retirés")

    # Le détail des causes compte : « Whisper pense qu'il n'y a pas de parole »
    # et « confiance basse » n'appellent pas la même réaction. La première
    # sent l'invention sur du bruit, la seconde, de la parole difficile.
    causes: dict[str, int] = {}
    for s in suspects:
        for code in s.get("suspect_causes") or []:
            causes[code] = causes.get(code, 0) + 1
    if causes:
        print("Causes relevées :")
        for code, n in sorted(causes.items(), key=lambda kv: -kv[1]):
            print(f"   {n:4d} × {CAUSES.get(code, code)}")

    if nb_pires and suspects:
        print(f"\nLes {min(nb_pires, len(suspects))} segments les plus douteux, à réécouter :")
        print("-" * 72)
        tries = sorted(suspects, key=lambda s: -(s.get("no_speech_prob") or 0))
        for s in tries[:nb_pires]:
            texte = " ".join((s.get("text") or "").split())[:52]
            print(f"  [{fmt_ts(s['start'])}] {s['speaker']:>12s}  {texte}")
            print(f"{'':16s}↳ {s.get('suspect_reason', '')}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Fiabilité de l'attribution des locuteurs dans un transcript")
    parser.add_argument("cible", help="Un *_transcript.json, ou un dossier à parcourir")
    parser.add_argument("--pires", type=int, default=10,
                        help="Nombre de segments les moins nets à lister (0 pour aucun)")
    args = parser.parse_args()

    for chemin in transcripts(Path(args.cible)):
        analyser(chemin, args.pires)


if __name__ == "__main__":
    main()
