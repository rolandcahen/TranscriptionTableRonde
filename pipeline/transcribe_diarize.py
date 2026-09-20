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
import hashlib
import json
import math
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# Doit être défini AVANT le premier import de torch (fait plus bas, dans
# diarize()) : sur Apple Silicon, quelques opérations utilisées par
# pyannote — notamment la FFT des filtres mel du modèle d'empreintes
# vocales — n'existent pas encore côté MPS. Sans ce drapeau, la
# diarisation sur GPU s'arrête net sur une NotImplementedError ; avec lui,
# ces opérations-là seules retombent sur le CPU, le reste (les
# convolutions, qui dominent le temps de calcul) restant sur le GPU.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

# Doit aussi précéder l'import de torch : rend les bibliothèques FFmpeg de
# Homebrew visibles pour torchcodec, quitte à relancer l'interpréteur une
# fois (voir ffmpeg_paths.py). Sans ça, la diarisation échoue sur « Could
# not load libtorchcodec » dès qu'on lance le script hors de l'app macOS,
# qui est la seule à poser la variable d'environnement nécessaire.
from ffmpeg_paths import ensure_ffmpeg_visible

ensure_ffmpeg_visible()

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


def _transcription_signature(audio_path: Path, model: str, language: str, context: str | None) -> dict:
    """Empreinte de ce qui influence le résultat de la transcription.

    Sert à ne réutiliser un cache que s'il correspond exactement au même
    audio et aux mêmes paramètres : changer de modèle, de langue ou de
    contexte doit refaire la transcription, pas recycler l'ancienne.
    """
    stat = audio_path.stat()
    return {
        "version": 1,
        "audio_name": audio_path.name,
        "audio_size": stat.st_size,
        "audio_mtime": int(stat.st_mtime),
        "model": model,
        "language": language,
        "context_sha1": hashlib.sha1((context or "").encode("utf-8")).hexdigest(),
    }


def load_cached_transcription(cache_path: Path, signature: dict):
    """Relit la transcription déjà calculée pour cet audio, s'il y en a une.

    L'étape 1 (Whisper) peut prendre plusieurs dizaines de minutes et
    l'étape 2 (diarisation) bien davantage : sans ce cache, la moindre
    interruption pendant l'étape 2 obligeait à tout refaire depuis le
    début, alors que la transcription, elle, était déjà terminée.
    """
    if not cache_path.exists():
        return None
    try:
        with open(cache_path, encoding="utf-8") as f:
            payload = json.load(f)
    except (json.JSONDecodeError, OSError):
        return None
    if payload.get("signature") != signature:
        return None
    segments = payload.get("segments")
    if not isinstance(segments, list) or not segments:
        return None
    print(f"[1/3] Transcription déjà calculée — réutilisation de {cache_path.name} ({len(segments)} segments)")
    return segments


def save_transcription_cache(cache_path: Path, signature: dict, segments: list) -> None:
    payload = {"signature": signature, "segments": _sanitize_json_floats(segments)}
    try:
        with open(cache_path, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False)
    except OSError as exc:
        # Le cache est un confort, pas une condition de réussite.
        print(f"      (impossible d'enregistrer le cache de transcription : {exc})")


# Phases internes de pyannote, avec le libellé affiché et la part qu'elles
# représentent sur l'échelle 0-100 % de l'étape 2. Les bornes sont
# empiriques : l'extraction des empreintes vocales domine très largement le
# temps de calcul, la segmentation vient loin derrière, et le regroupement
# finit en quelques instants. Sans ce découpage, chaque phase repartirait de
# 0 % et la barre de progression ferait plusieurs allers-retours.
_DIARIZATION_PHASES = {
    "segmentation": ("segmentation de la parole", 0.0, 30.0),
    "embeddings": ("empreintes vocales", 30.0, 95.0),
    "speaker_counting": ("comptage des locuteurs", 95.0, 97.0),
    "discrete_diarization": ("assemblage des tours de parole", 97.0, 100.0),
}


class DiarizationProgress:
    """Hook pyannote qui imprime une progression en texte simple.

    pyannote fournit bien un `ProgressHook`, mais il dessine une barre
    interactive à coups de retours chariot : dans le journal de l'app
    macOS, qui empile des lignes, ça produirait des centaines de lignes
    illisibles. On imprime donc une ligne courte, au plus toutes les
    `min_interval` secondes, dans un format que `PipelineRunner.swift` sait
    relire pour alimenter sa barre de progression.
    """

    def __init__(self, min_interval: float = 5.0):
        self.min_interval = min_interval
        self._last_print = 0.0
        self._step = None

    def __call__(self, step_name, step_artifact, file=None, total=None, completed=None):
        label, start, end = _DIARIZATION_PHASES.get(step_name, (step_name, None, None))

        if step_name != self._step:
            self._step = step_name
            self._last_print = 0.0

        # Phase sans progression chiffrée : on annonce juste son début.
        if not total or completed is None or start is None:
            if completed is None:
                print(f"      Diarisation — {label}", flush=True)
            return

        now = time.time()
        if completed < total and (now - self._last_print) < self.min_interval:
            return
        self._last_print = now

        overall = start + (end - start) * min(completed / total, 1.0)
        print(f"      Diarisation {overall:.0f}% — {label}", flush=True)


def _select_device(preference: str):
    """Choisit le périphérique de calcul pour pyannote.

    Par défaut ("auto"), le GPU Apple (MPS) s'il est disponible : le modèle
    d'empreintes vocales, qui représente l'essentiel du temps de calcul, y
    est nettement plus rapide que sur CPU. `--device cpu` force l'ancien
    comportement si jamais MPS pose problème.
    """
    import torch

    if preference == "cpu":
        return torch.device("cpu")
    if not torch.backends.mps.is_available():
        if preference == "mps":
            print("      GPU (MPS) demandé mais indisponible — repli sur le CPU.")
        return torch.device("cpu")
    return torch.device("mps")


def _apply_pipeline(pipeline, audio_path: str, hook, kwargs: dict):
    """Lance le pipeline, en se passant du hook si la version installée ne
    le connaît pas — la progression est un confort, pas une dépendance."""
    try:
        return pipeline(audio_path, hook=hook, **kwargs)
    except TypeError as exc:
        if "hook" not in str(exc):
            raise
        print("      (cette version de pyannote n'expose pas de progression : étape 2 sans pourcentage)")
        return pipeline(audio_path, **kwargs)


def diarize(audio_path: str, hf_token: str, num_speakers: int | None, device_preference: str = "auto"):
    import torch
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
    hook = DiarizationProgress()

    device = _select_device(device_preference)
    print(f"      calcul sur {'GPU (MPS)' if device.type == 'mps' else 'CPU'}")
    try:
        pipeline.to(device)
        diarization = _apply_pipeline(pipeline, audio_path, hook, kwargs)
    except Exception as exc:
        # Un échec propre au GPU ne doit pas faire perdre le travail : on
        # reprend la diarisation sur le CPU, plus lent mais éprouvé.
        if device.type != "mps":
            raise
        print(f"      Échec de la diarisation sur le GPU : {exc}")
        print("      Reprise depuis le début sur le CPU (plus lent, mais fiable)...")
        pipeline.to(torch.device("cpu"))
        diarization = _apply_pipeline(pipeline, audio_path, hook, kwargs)

    # pyannote 4.x renvoie un objet structuré (.speaker_diarization),
    # pyannote 3.x renvoie directement l'Annotation : on accepte les deux.
    annotation = getattr(diarization, "speaker_diarization", diarization)
    turns = [
        (turn.start, turn.end, speaker)
        for turn, _, speaker in annotation.itertracks(yield_label=True)
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
        "--device",
        default="auto",
        choices=["auto", "mps", "cpu"],
        help="Périphérique de calcul pour la diarisation (défaut : auto = GPU Apple si disponible)",
    )
    parser.add_argument(
        "--force-transcription",
        action="store_true",
        help="Refaire la transcription même si un résultat en cache existe pour ce fichier",
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

    cache_path = out_dir / f"{basename}_whisper_raw.json"
    signature = _transcription_signature(audio_path, args.model, args.language, args.context)

    print("Normalisation de l'audio (conversion en WAV 16 kHz mono)...")
    normalized_path = normalize_audio(audio_path)
    try:
        whisper_segments = None
        if not args.force_transcription:
            whisper_segments = load_cached_transcription(cache_path, signature)
        if whisper_segments is None:
            whisper_segments = transcribe(str(normalized_path), args.model, args.language, args.context)
            # Écrit sur disque immédiatement : si la diarisation échoue ou
            # est interrompue, cette transcription-là est acquise et la
            # prochaine exécution repartira directement de l'étape 2.
            save_transcription_cache(cache_path, signature, whisper_segments)
        diarization_turns = diarize(
            str(normalized_path), args.hf_token, args.num_speakers, args.device
        )
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
