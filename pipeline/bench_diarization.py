#!/usr/bin/env python3
"""
Banc d'essai de la diarisation : mesure, sur un court extrait, ce que
rapporte chaque réglage d'accélération — et ce qu'il coûte en qualité.

La transcription (mlx-whisper) tourne sur le GPU et va vite ; la
diarisation (pyannote) est le goulot d'étranglement. Plutôt que de
supposer quel réglage aide, ce script les essaie l'un après l'autre sur le
même extrait et affiche un tableau : temps, nombre de locuteurs trouvés,
et écart avec la configuration de référence.

L'écart est mesuré avec la DER (Diarization Error Rate) de
pyannote.metrics, en prenant la PREMIÈRE configuration comme référence.
Ce n'est donc pas une mesure de justesse absolue — il faudrait une
annotation manuelle pour cela — mais une mesure de divergence : « ce
réglage plus rapide donne-t-il toujours le même découpage ? ». 0 % = un
résultat identique à la référence.

Usage :
    python bench_diarization.py --audio reunion.mp3 --minutes 10 --hf-token hf_xxx
    python bench_diarization.py --audio reunion.mp3 --configs cpu-defaut,mps-lot32
    python bench_diarization.py --audio extrait.wav --num-speakers 5 --list-configs

Le token peut aussi venir de la variable d'environnement HF_TOKEN. Il
n'est jamais affiché ni écrit sur le disque.
"""
from __future__ import annotations

import argparse
import gc
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# Voir transcribe_diarize.py : indispensable avant l'import de torch pour
# que les rares opérations absentes de MPS retombent sur le CPU au lieu de
# faire échouer tout le calcul.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

from ffmpeg_paths import ensure_ffmpeg_visible

ensure_ffmpeg_visible()


# Chaque configuration : (périphérique, taille de lot, pas de la fenêtre
# glissante en ratio de sa durée). `None` = on garde ce que le dépôt
# Hugging Face a configuré, sans y toucher.
CONFIGS = {
    "cpu-defaut": {
        "device": "cpu", "batch": None, "step": None,
        "description": "l'existant : CPU, réglages du dépôt tels quels",
    },
    "cpu-lot32": {
        "device": "cpu", "batch": 32, "step": None,
        "description": "CPU, traitement par lots de 32 fenêtres",
    },
    "mps-defaut": {
        "device": "mps", "batch": None, "step": None,
        "description": "GPU Apple, réglages du dépôt tels quels",
    },
    "mps-lot32": {
        "device": "mps", "batch": 32, "step": None,
        "description": "GPU Apple + lots de 32",
    },
    "mps-lot64": {
        "device": "mps", "batch": 64, "step": None,
        "description": "GPU Apple + lots de 64",
    },
    "mps-lot32-pas0.25": {
        "device": "mps", "batch": 32, "step": 0.25,
        "description": "GPU + lots de 32 + fenêtre glissante 2,5× moins dense",
    },
    "mps-lot32-pas0.5": {
        "device": "mps", "batch": 32, "step": 0.5,
        "description": "GPU + lots de 32 + fenêtre glissante 5× moins dense",
    },
}

DEFAULT_CONFIGS = ["cpu-defaut", "mps-lot32", "mps-lot32-pas0.25", "mps-lot32-pas0.5"]


def extract(audio_path: Path, minutes: float) -> Path:
    """Découpe les `minutes` premières minutes en WAV 16 kHz mono."""
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()
    out = Path(tmp.name)
    cmd = ["ffmpeg", "-y", "-i", str(audio_path)]
    if minutes > 0:
        cmd += ["-t", str(int(minutes * 60))]
    cmd += ["-ar", "16000", "-ac", "1", str(out)]
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True)
    except FileNotFoundError:
        sys.exit("Erreur : ffmpeg introuvable (brew install ffmpeg).")
    except subprocess.CalledProcessError as exc:
        sys.exit(f"Erreur ffmpeg :\n{exc.stderr}")
    return out


def audio_seconds(path: Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
        capture_output=True, text=True,
    )
    try:
        return float(out.stdout.strip())
    except ValueError:
        return 0.0


def load_pipeline(hf_token: str):
    from pyannote.audio import Pipeline

    return Pipeline.from_pretrained("pyannote/speaker-diarization-3.1", token=hf_token)


def annotation_of(result):
    """pyannote 4.x renvoie un objet structuré, 3.x une Annotation."""
    return getattr(result, "speaker_diarization", result)


def apply_config(pipeline, config: dict) -> dict:
    """Applique une configuration et renvoie ce qui a réellement été posé."""
    import torch

    applied = {}

    device_name = config["device"]
    if device_name == "mps" and not torch.backends.mps.is_available():
        return {"skipped": "GPU (MPS) indisponible sur cette machine"}
    pipeline.to(torch.device(device_name))
    applied["device"] = device_name

    if config["batch"] is not None:
        pipeline.segmentation_batch_size = config["batch"]
        pipeline.embedding_batch_size = config["batch"]
    applied["segmentation_batch"] = pipeline.segmentation_batch_size
    applied["embedding_batch"] = pipeline.embedding_batch_size

    if config["step"] is not None:
        try:
            inference = pipeline._segmentation
            inference.step = config["step"] * inference.duration
        except AttributeError:
            return {"skipped": "cette version de pyannote n'expose pas le pas de fenêtre"}
    try:
        inference = pipeline._segmentation
        applied["window"] = f"{inference.duration:.0f}s/pas {inference.step:.2f}s"
    except AttributeError:
        applied["window"] = "?"

    return applied


def run_one(name: str, config: dict, wav: Path, hf_token: str, num_speakers: int | None):
    print(f"\n── {name} : {config['description']}")
    pipeline = load_pipeline(hf_token)
    applied = apply_config(pipeline, config)
    if "skipped" in applied:
        print(f"   ignoré ({applied['skipped']})")
        return None

    print(f"   périphérique={applied['device']}  "
          f"lots seg/emb={applied['segmentation_batch']}/{applied['embedding_batch']}  "
          f"fenêtre={applied['window']}")

    kwargs = {"num_speakers": num_speakers} if num_speakers else {}
    t0 = time.time()
    try:
        result = pipeline(str(wav), **kwargs)
    except Exception as exc:
        print(f"   ÉCHEC : {type(exc).__name__}: {exc}")
        return {"name": name, "error": f"{type(exc).__name__}: {exc}", "applied": applied}
    elapsed = time.time() - t0

    annotation = annotation_of(result)
    speakers = sorted(annotation.labels())
    speech = sum(seg.duration for seg in annotation.get_timeline().support())
    print(f"   {elapsed:.0f}s — {len(speakers)} locuteur(s), {speech:.0f}s de parole")

    del pipeline
    gc.collect()
    return {
        "name": name, "seconds": elapsed, "annotation": annotation,
        "speakers": speakers, "speech": speech, "applied": applied,
    }


def divergence(reference, hypothesis) -> float | None:
    """DER entre deux résultats : 0 = découpages identiques."""
    try:
        from pyannote.metrics.diarization import DiarizationErrorRate
    except ImportError:
        return None
    try:
        return float(DiarizationErrorRate()(reference, hypothesis))
    except Exception:
        return None


def main():
    parser = argparse.ArgumentParser(description="Banc d'essai des réglages de diarisation")
    parser.add_argument("--audio", help="Fichier audio (un extrait suffit)")
    parser.add_argument("--minutes", type=float, default=10.0,
                        help="Ne garder que les N premières minutes (0 = tout le fichier). Défaut : 10")
    parser.add_argument("--num-speakers", type=int, default=None,
                        help="Nombre de locuteurs, si connu (à garder identique entre configurations)")
    parser.add_argument("--hf-token", default=os.environ.get("HF_TOKEN"))
    parser.add_argument("--configs", default=",".join(DEFAULT_CONFIGS),
                        help="Configurations à comparer, séparées par des virgules")
    parser.add_argument("--list-configs", action="store_true", help="Afficher les configurations disponibles")
    args = parser.parse_args()

    if args.list_configs:
        for name, cfg in CONFIGS.items():
            print(f"  {name:22s} {cfg['description']}")
        return

    if not args.audio:
        sys.exit("Erreur : --audio est requis.")
    if not args.hf_token:
        sys.exit("Erreur : aucun token Hugging Face (--hf-token ou variable HF_TOKEN).")

    audio_path = Path(args.audio)
    if not audio_path.exists():
        sys.exit(f"Erreur : fichier introuvable : {audio_path}")

    names = [n.strip() for n in args.configs.split(",") if n.strip()]
    inconnues = [n for n in names if n not in CONFIGS]
    if inconnues:
        sys.exit(f"Configuration(s) inconnue(s) : {', '.join(inconnues)}\n"
                 f"Disponibles : {', '.join(CONFIGS)}")

    print(f"Extraction de l'échantillon depuis {audio_path.name}…")
    wav = extract(audio_path, args.minutes)
    duree = audio_seconds(wav)
    print(f"Échantillon : {duree:.0f}s d'audio ({duree / 60:.1f} min)")
    if args.num_speakers:
        print(f"Nombre de locuteurs imposé : {args.num_speakers}")

    results = []
    try:
        for name in names:
            results.append(run_one(name, CONFIGS[name], wav, args.hf_token, args.num_speakers))
    except KeyboardInterrupt:
        print("\nInterrompu — résultats partiels ci-dessous.")
    finally:
        wav.unlink(missing_ok=True)

    valides = [r for r in results if r and "annotation" in r]
    if not valides:
        print("\nAucune configuration n'a abouti.")
        return

    reference = valides[0]
    print("\n" + "=" * 78)
    print(f"RÉSULTATS — {duree / 60:.1f} min d'audio, référence = {reference['name']}")
    print("=" * 78)
    print(f"{'configuration':24s} {'temps':>8s} {'×temps réel':>12s} {'gain':>7s} {'loc.':>5s} {'écart':>8s}")
    print("-" * 78)
    for r in valides:
        ratio = duree / r["seconds"] if r["seconds"] else 0
        gain = reference["seconds"] / r["seconds"] if r["seconds"] else 0
        if r is reference:
            ecart = "réf."
        else:
            d = divergence(reference["annotation"], r["annotation"])
            ecart = f"{100 * d:.1f}%" if d is not None else "n/d"
        print(f"{r['name']:24s} {r['seconds']:7.1f}s {ratio:11.1f}× {gain:6.1f}× "
              f"{len(r['speakers']):5d} {ecart:>8s}")
    for r in results:
        if r and "error" in r:
            print(f"{r['name']:24s}  ÉCHEC : {r['error']}")
    print("-" * 78)
    print("×temps réel : combien de secondes d'audio traitées par seconde de calcul.")
    print("écart : divergence avec la référence (0 % = découpage identique).")
    print("Un écart inférieur à ~5 % est en général sans conséquence sur un transcript ;")
    print("au-delà de ~15 %, vérifiez à l'oreille avant d'adopter le réglage.")

    if valides:
        meilleur = min(valides, key=lambda r: r["seconds"])
        heures = 30

        def projection(r) -> str:
            h = heures * 3600 / (duree / r["seconds"]) / 3600
            return f"{h * 60:.0f} min" if h < 1 else f"{h:.1f} h"

        print(f"\nProjection pour {heures} h d'enregistrements : "
              f"{projection(reference)} de calcul avec « {reference['name']} », "
              f"contre {projection(meilleur)} avec « {meilleur['name']} ».")


if __name__ == "__main__":
    main()
