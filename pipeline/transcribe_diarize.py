#!/usr/bin/env python3
"""
Pipeline de transcription + diarisation 100% local, pensé pour des tables
rondes confidentielles en français.

  Étape 1 : transcription avec mlx-whisper (accéléré GPU sur Apple Silicon)
  Étape 2 : diarisation (qui parle quand) avec pyannote-audio
  Étape 3 : fusion des deux pour produire un transcript étiqueté par locuteur

Rien ne quitte votre machine pendant le traitement : les seuls appels
réseau ont lieu une fois, au tout premier lancement, pour télécharger les
poids des modèles (mis en cache localement ensuite dans ~/.cache).

Usage :
    python transcribe_diarize.py --audio reunion.wav --output ./sortie
    python transcribe_diarize.py --audio reunion.mp3 --output ./sortie --num-speakers 5 --model large-v3

Voir README.md pour l'installation complète (dépendances, token Hugging Face).
"""
from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from align import assign_speakers, merge_consecutive

# Modèles Whisper packagés au format MLX (téléchargés depuis Hugging Face au
# premier lancement, puis mis en cache localement).
MODEL_REPOS = {
    "large-v3": "mlx-community/whisper-large-v3-mlx",
    "large-v3-turbo": "mlx-community/whisper-large-v3-turbo",
    "medium": "mlx-community/whisper-medium-mlx",
}


def fmt_ts(seconds: float) -> str:
    seconds = max(0.0, seconds)
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


def normalize_audio(audio_path: Path) -> Path:
    """Convertit l'audio en WAV mono 16 kHz dans un fichier temporaire.

    Nécessaire notamment pour les MP3 en VBR : la durée estimée par les
    décodeurs peut être légèrement imprécise, ce qui fait planter pyannote
    (ValueError "resulted in N samples instead of the expected M samples")
    quand il découpe l'audio en fenêtres de 10s. Repartir d'un WAV mono
    16 kHz propre élimine cette classe de bug, quel que soit le format
    d'entrée (mp3, m4a, etc.).
    """
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()
    tmp_path = Path(tmp.name)
    try:
        subprocess.run(
            ["ffmpeg", "-y", "-i", str(audio_path), "-ar", "16000", "-ac", "1", str(tmp_path)],
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        sys.exit("Erreur : ffmpeg introuvable. Installez-le avec 'brew install ffmpeg'.")
    except subprocess.CalledProcessError as exc:
        sys.exit(f"Erreur ffmpeg lors de la normalisation de l'audio :\n{exc.stderr}")
    return tmp_path


def transcribe(audio_path: str, model: str, language: str, context: str | None):
    import mlx_whisper  # import local : n'est nécessaire que sur Mac Apple Silicon

    repo = MODEL_REPOS.get(model, model)  # accepte aussi un repo HF passé directement
    print(f"[1/3] Transcription avec {repo} (langue = {language})...")
    t0 = time.time()
    result = mlx_whisper.transcribe(
        audio_path,
        path_or_hf_repo=repo,
        language=language,
        word_timestamps=False,
        verbose=False,
        # Amorce le décodage avec le contexte fourni (sujet, participants,
        # noms propres/termes techniques) : améliore nettement la
        # reconnaissance de ces mots plutôt que de les laisser au hasard.
        initial_prompt=context or None,
    )
    print(f"      terminé en {time.time() - t0:.0f}s ({len(result['segments'])} segments)")
    return result["segments"]


def diarize(audio_path: str, hf_token: str, num_speakers: int | None):
    from pyannote.audio import Pipeline

    print("[2/3] Diarisation (détection des locuteurs) avec pyannote...")
    t0 = time.time()
    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        token=hf_token,
    )
    kwargs = {}
    if num_speakers:
        kwargs["num_speakers"] = num_speakers
    diarization = pipeline(audio_path, **kwargs)
    turns = [
        (turn.start, turn.end, speaker)
        for turn, _, speaker in diarization.speaker_diarization.itertracks(yield_label=True)
    ]
    nb_locuteurs = len({s for _, _, s in turns})
    print(f"      terminé en {time.time() - t0:.0f}s — {nb_locuteurs} locuteur(s) détecté(s)")
    return turns


def _sanitize_json_floats(obj):
    # mlx-whisper peut produire avg_logprob=NaN sur un segment sans texte
    # (silence). json.dump écrit alors le token littéral NaN, valide en
    # Python mais rejeté par les parseurs JSON stricts (dont celui de
    # l'app macOS) — on le remplace par null avant l'écriture.
    if isinstance(obj, float):
        return None if (math.isnan(obj) or math.isinf(obj)) else obj
    if isinstance(obj, dict):
        return {k: _sanitize_json_floats(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_sanitize_json_floats(v) for v in obj]
    return obj


def write_outputs(basename: str, out_dir: Path, merged_segments: list[dict]):
    # 1) Transcript texte lisible
    txt_path = out_dir / f"{basename}_transcript.txt"
    with open(txt_path, "w", encoding="utf-8") as f:
        for seg in merged_segments:
            f.write(f"[{fmt_ts(seg['start'])} - {fmt_ts(seg['end'])}] {seg['speaker']}\n")
            f.write(seg["text"].strip() + "\n\n")

    # 2) Données structurées, réutilisables (renommage, résumé futur, etc.)
    json_path = out_dir / f"{basename}_transcript.json"
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(_sanitize_json_floats(merged_segments), f, ensure_ascii=False, indent=2)

    # 3) Fiche d'identification des locuteurs (aide au renommage manuel)
    speakers_seen: dict[str, list[dict]] = {}
    for seg in merged_segments:
        speakers_seen.setdefault(seg["speaker"], []).append(seg)

    speakers_map = {}
    for speaker, segs in speakers_seen.items():
        total_time = sum(s["end"] - s["start"] for s in segs)
        speakers_map[speaker] = {
            "nom": "",
            "temps_de_parole_secondes": round(total_time, 1),
            "nb_interventions": len(segs),
            "premiere_intervention": f"[{fmt_ts(segs[0]['start'])}] {segs[0]['text'][:150].strip()}",
        }
    speakers_map_path = out_dir / f"{basename}_speakers.json"
    with open(speakers_map_path, "w", encoding="utf-8") as f:
        json.dump(speakers_map, f, ensure_ascii=False, indent=2)

    return txt_path, json_path, speakers_map_path


def main():
    parser = argparse.ArgumentParser(
        description="Transcription + diarisation 100%% locale (mlx-whisper + pyannote)"
    )
    parser.add_argument("--audio", required=True, help="Fichier audio .wav ou .mp3 à transcrire")
    parser.add_argument("--output", default="./sortie", help="Dossier de sortie")
    parser.add_argument("--language", default="fr", help="Code langue (défaut : fr)")
    parser.add_argument(
        "--model",
        default="large-v3-turbo",
        choices=list(MODEL_REPOS.keys()),
        help="Modèle Whisper à utiliser (défaut : large-v3-turbo, le plus rapide)",
    )
    parser.add_argument(
        "--num-speakers",
        type=int,
        default=None,
        help="Nombre de locuteurs si connu (recommandé : améliore beaucoup la fiabilité)",
    )
    parser.add_argument(
        "--max-gap",
        type=float,
        default=1.0,
        help="Écart max en secondes toléré pour fusionner deux segments du même locuteur (défaut : 1.0)",
    )
    parser.add_argument(
        "--hf-token",
        default=os.environ.get("HF_TOKEN"),
        help="Token Hugging Face (ou variable d'environnement HF_TOKEN)",
    )
    parser.add_argument(
        "--context",
        default=None,
        help="Contexte de la réunion (sujet, participants, organismes, termes techniques) : "
        "améliore la reconnaissance des noms propres et termes spécifiques, et sert de base "
        "au résumé structuré (summarize.py) s'il n'a pas son propre --context.",
    )
    args = parser.parse_args()

    audio_path = Path(args.audio)
    if not audio_path.exists():
        sys.exit(f"Erreur : fichier introuvable : {audio_path}")

    if not args.hf_token:
        sys.exit(
            "Erreur : aucun token Hugging Face fourni.\n"
            "Passez --hf-token VOTRE_TOKEN ou définissez la variable d'environnement HF_TOKEN.\n"
            "Voir README.md, section « Token Hugging Face »."
        )

    out_dir = Path(args.output)
    out_dir.mkdir(parents=True, exist_ok=True)
    basename = audio_path.stem

    if args.context:
        (out_dir / f"{basename}_contexte.txt").write_text(args.context, encoding="utf-8")

    print("Normalisation de l'audio (conversion en WAV 16 kHz mono)...")
    normalized_path = normalize_audio(audio_path)
    try:
        whisper_segments = transcribe(str(normalized_path), args.model, args.language, args.context)
        diarization_turns = diarize(str(normalized_path), args.hf_token, args.num_speakers)
    finally:
        normalized_path.unlink(missing_ok=True)

    print("[3/3] Fusion transcription + locuteurs...")
    labeled = assign_speakers(whisper_segments, diarization_turns)
    merged = merge_consecutive(labeled, max_gap=args.max_gap)

    txt_path, json_path, speakers_map_path = write_outputs(basename, out_dir, merged)

    print("\nTerminé. Fichiers générés :")
    print(f"  - {txt_path}         (transcript lisible)")
    print(f"  - {json_path}   (données structurées)")
    print(f"  - {speakers_map_path}    (à compléter, puis utiliser avec rename_speakers.py)")


if __name__ == "__main__":
    main()
