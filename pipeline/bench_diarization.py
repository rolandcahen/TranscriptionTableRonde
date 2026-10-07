#!/usr/bin/env python3
"""
Banc d'essai de la diarisation : mesure, sur un court extrait, ce que
rapporte chaque réglage d'accélération — et ce qu'il coûte en qualité.

La transcription (mlx-whisper) tourne sur le GPU et va vite ; la
diarisation (pyannote) est le goulot d'étranglement. Plutôt que de
supposer quel réglage aide, ce script les essaie l'un après l'autre sur le
même extrait et affiche un tableau : temps, nombre de locuteurs trouvés,
et écart avec la configuration de référence.

Deux manières de mesurer, selon qu'on dispose ou non d'une référence :

  Sans --reference, l'écart est une DIVERGENCE : la première configuration
  sert d'étalon, les autres lui sont comparées. 0 % = découpage identique.
  C'est suffisant pour répondre à « ce réglage plus rapide change-t-il
  quelque chose ? », mais incapable de répondre à « lequel des deux a
  raison ? » : deux résultats peuvent diverger parce que l'un s'améliore
  tout autant que parce qu'il se dégrade.

  Avec --reference, l'écart devient une vraie DER (Diarization Error Rate),
  mesurée contre un transcript corrigé à la main dans la fenêtre de
  vérification. C'est la seule façon honnête de départager deux MODÈLES.
  Elle est décomposée en ses trois termes, qui ne se corrigent pas de la
  même manière :
      confusion  la parole est détectée mais attribuée au mauvais
                 locuteur — c'est ce que les chevauchements dégradent ;
      manquée    de la parole n'a pas été détectée du tout ;
      fausse     du silence ou du bruit pris pour de la parole.

Usage :
    python bench_diarization.py --audio reunion.mp3 --minutes 10 --hf-token hf_xxx
    python bench_diarization.py --audio reunion.mp3 --configs cpu-defaut,mps-lot32
    python bench_diarization.py --audio reunion.wav --minutes 10 \\
        --configs mps-lot32,communaute1 \\
        --reference sortie_reunion/reunion_transcript.json
    python bench_diarization.py --audio extrait.wav --num-speakers 5 --list-configs

Le token peut aussi venir de la variable d'environnement HF_TOKEN. Il
n'est jamais affiché ni écrit sur le disque.
"""
from __future__ import annotations

import argparse
import gc
import json
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


# Modèles de diarisation comparables. community-1 est le successeur annoncé
# de 3.1 : même détection de parole superposée d'après pyannote, mais
# nettement moins de confusion entre locuteurs. « Annoncé » : d'où ce banc
# d'essai, pour le vérifier sur VOS enregistrements plutôt que sur AMI.
MODELES = {
    "3.1": "pyannote/speaker-diarization-3.1",
    "communaute-1": "pyannote/speaker-diarization-community-1",
}
MODELE_PAR_DEFAUT = "3.1"

# Chaque configuration : (modèle, périphérique, taille de lot, pas de la
# fenêtre glissante en ratio de sa durée). `None` = on garde ce que le dépôt
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
        "description": "GPU Apple + lots de 32 (le réglage en production)",
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
    "communaute1": {
        "modele": "communaute-1",
        "device": "mps", "batch": 32, "step": None,
        "description": "modèle community-1, GPU + lots de 32 (à comparer à mps-lot32)",
    },
    "communaute1-cpu": {
        "modele": "communaute-1",
        "device": "cpu", "batch": 32, "step": None,
        "description": "modèle community-1 sur CPU, si le GPU pose problème",
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


def load_pipeline(hf_token: str, modele: str):
    from pyannote.audio import Pipeline

    repo = MODELES.get(modele, modele)
    return Pipeline.from_pretrained(repo, token=hf_token)


def annotation_of(result):
    """pyannote 4.x renvoie un objet structuré, 3.x une Annotation."""
    return getattr(result, "speaker_diarization", result)


def lire_reference(chemin: Path):
    """Construit une annotation de référence à partir d'un transcript corrigé.

    Le format attendu est celui que produit la fenêtre de vérification :
    une liste de segments {start, end, speaker, text}. C'est volontairement
    le fichier que vous corrigez déjà, pour qu'établir une vérité de terrain
    ne demande aucun outil ni aucun format supplémentaire — relire dix
    minutes d'extrait dans l'app suffit.

    Limite à garder en tête : les frontières de ces segments viennent du
    découpage de Whisper, pas des vraies frontières acoustiques de parole.
    La DER obtenue est donc une DER « de terrain », pas une DER de
    laboratoire. Elle reste parfaitement valable pour comparer deux modèles
    entre eux sur le même extrait, ce qui est tout ce qu'on lui demande.
    """
    from pyannote.core import Annotation, Segment

    try:
        donnees = json.loads(chemin.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        sys.exit(f"Erreur : référence illisible ({chemin}) : {exc}")
    if isinstance(donnees, dict):
        donnees = donnees.get("segments") or donnees.get("transcript") or []
    if not isinstance(donnees, list) or not donnees:
        sys.exit(f"Erreur : aucun segment exploitable dans {chemin}")

    annotation = Annotation(uri="reference")
    retenus = 0
    for i, seg in enumerate(donnees):
        try:
            debut, fin = float(seg["start"]), float(seg["end"])
        except (KeyError, TypeError, ValueError):
            continue
        locuteur = str(seg.get("speaker") or "").strip()
        # Un segment laissé « INCONNU » n'est pas une vérité : l'inclure
        # reviendrait à compter comme erreur ce que vous n'avez pas tranché.
        if fin <= debut or not locuteur or locuteur.upper() == "INCONNU":
            continue
        annotation[Segment(debut, fin), i] = locuteur
        retenus += 1

    if not retenus:
        sys.exit(f"Erreur : aucun segment avec un locuteur nommé dans {chemin}")
    duree = sum(s.duration for s in annotation.get_timeline().support())
    print(f"Référence : {retenus} segments, {len(annotation.labels())} locuteurs, "
          f"{duree / 60:.1f} min de parole annotée ({chemin.name})")
    return annotation


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
    # getattr plutôt qu'un accès direct : un modèle plus récent peut ne pas
    # exposer ces attributs, et l'absence d'un indicateur d'affichage ne
    # doit pas faire échouer la mesure elle-même.
    applied["segmentation_batch"] = getattr(pipeline, "segmentation_batch_size", "?")
    applied["embedding_batch"] = getattr(pipeline, "embedding_batch_size", "?")

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
    modele = config.get("modele", MODELE_PAR_DEFAUT)
    try:
        pipeline = load_pipeline(hf_token, modele)
    except Exception as exc:
        # Cas le plus fréquent : les conditions d'utilisation du modèle
        # n'ont pas encore été acceptées sur Hugging Face. On le dit
        # plutôt que de laisser une trace d'exception brute.
        print(f"   ÉCHEC au chargement de {MODELES.get(modele, modele)} : {type(exc).__name__}: {exc}")
        print(f"   (si c'est un refus d'accès : acceptez les conditions sur "
              f"https://huggingface.co/{MODELES.get(modele, modele)})")
        return {"name": name, "error": f"chargement du modèle : {exc}", "modele": modele}
    applied = apply_config(pipeline, config)
    if "skipped" in applied:
        print(f"   ignoré ({applied['skipped']})")
        return None

    print(f"   modèle={modele}  périphérique={applied['device']}  "
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
        "modele": modele,
    }


def divergence(reference, hypothesis, uem=None) -> float | None:
    """DER entre deux résultats : 0 = découpages identiques.

    La fenêtre d'évaluation est passée explicitement : sans elle,
    pyannote.metrics l'approxime par l'union des deux annotations et
    l'annonce par un avertissement, qui venait s'imprimer au milieu du
    tableau de résultats.
    """
    try:
        from pyannote.metrics.diarization import DiarizationErrorRate
    except ImportError:
        return None
    try:
        return float(DiarizationErrorRate()(reference, hypothesis, uem=uem))
    except Exception:
        return None


def evaluer(reference, hypothesis, uem=None) -> dict | None:
    """DER détaillée contre une vérité de terrain.

    Renvoie la DER globale et ses trois composantes, ramenées à la durée de
    parole de la référence. Séparer ces termes compte : une confusion élevée
    se soigne en changeant de modèle ou en désambiguïsant les chevauchements,
    une détection manquée en reprenant la prise de son ou le seuil de
    détection de parole. Un chiffre unique mélangerait deux diagnostics.
    """
    try:
        from pyannote.metrics.diarization import DiarizationErrorRate
    except ImportError:
        return None
    try:
        detail = DiarizationErrorRate()(reference, hypothesis, uem=uem, detailed=True)
    except Exception:
        return None
    total = detail.get("total") or 0.0
    if not total:
        return None
    return {
        "der": detail.get("diarization error rate", 0.0),
        "confusion": detail.get("confusion", 0.0) / total,
        "manquee": detail.get("missed detection", 0.0) / total,
        "fausse": detail.get("false alarm", 0.0) / total,
    }


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
    parser.add_argument(
        "--reference",
        default=None,
        help="Transcript corrige a la main (*_transcript.json) servant de verite de terrain. "
        "L'ecart affiche devient alors une vraie DER, decomposee en confusion / manquee / fausse, "
        "au lieu d'une simple divergence entre configurations.",
    )
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

    reference_verite = None
    if args.reference:
        chemin_ref = Path(args.reference)
        if not chemin_ref.exists():
            sys.exit(f"Erreur : référence introuvable : {chemin_ref}")
        reference_verite = lire_reference(chemin_ref)

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
    largeur = 92 if reference_verite is not None else 78
    print("\n" + "=" * largeur)
    if reference_verite is not None:
        print(f"RÉSULTATS — {duree / 60:.1f} min d'audio, mesurés contre votre transcript corrigé")
    else:
        print(f"RÉSULTATS — {duree / 60:.1f} min d'audio, référence = {reference['name']}")
    print("=" * largeur)

    # Toutes les mesures sont bornées à l'extrait réellement traité. Sans
    # cette fenêtre, ce que la référence contient au-delà serait compté
    # comme de la parole non détectée — et en mode divergence,
    # pyannote.metrics imprimait un avertissement en plein tableau.
    uem = None
    if duree > 0:
        from pyannote.core import Segment, Timeline

        uem = Timeline([Segment(0.0, duree)])

    if reference_verite is not None:
        print(f"{'configuration':20s} {'modèle':13s} {'temps':>7s} {'loc.':>5s} "
              f"{'DER':>7s} {'confus.':>8s} {'manquée':>8s} {'fausse':>7s}")
    else:
        print(f"{'configuration':24s} {'temps':>8s} {'×temps réel':>12s} {'gain':>7s} "
              f"{'loc.':>5s} {'écart':>8s}")
    print("-" * largeur)

    for r in valides:
        ratio = duree / r["seconds"] if r["seconds"] else 0
        gain = reference["seconds"] / r["seconds"] if r["seconds"] else 0
        if reference_verite is not None:
            m = evaluer(reference_verite, r["annotation"], uem=uem)
            if m is None:
                print(f"{r['name']:20s} {r.get('modele', ''):13s} {r['seconds']:6.1f}s "
                      f"{len(r['speakers']):5d} {'n/d':>7s}")
                continue
            print(f"{r['name']:20s} {r.get('modele', ''):13s} {r['seconds']:6.1f}s "
                  f"{len(r['speakers']):5d} "
                  f"{100 * m['der']:6.1f}% {100 * m['confusion']:7.1f}% "
                  f"{100 * m['manquee']:7.1f}% {100 * m['fausse']:6.1f}%")
        else:
            if r is reference:
                ecart = "réf."
            else:
                d = divergence(reference["annotation"], r["annotation"], uem=uem)
                ecart = f"{100 * d:.1f}%" if d is not None else "n/d"
            print(f"{r['name']:24s} {r['seconds']:7.1f}s {ratio:11.1f}× {gain:6.1f}× "
                  f"{len(r['speakers']):5d} {ecart:>8s}")

    for r in results:
        if r and "error" in r:
            print(f"{r['name']:24s}  ÉCHEC : {r['error']}")
    print("-" * largeur)

    if reference_verite is not None:
        print("DER : part du temps de parole mal traitée — plus bas vaut mieux.")
        print("confus. : parole attribuée au mauvais locuteur. C'est le terme que")
        print("          dégradent les chevauchements, et celui que vise un changement")
        print("          de modèle de diarisation.")
        print("manquée : parole non détectée. Relève de la prise de son ou du seuil")
        print("          de détection, pas du modèle de locuteurs.")
        print("fausse  : silence ou bruit pris pour de la parole.")
        print("\nCes chiffres sont mesurés sur VOS enregistrements et sur les frontières")
        print("de segments de Whisper : comparables entre eux, mais pas avec les DER")
        print("publiées sur des corpus de référence comme AMI ou DIHARD.")
    else:
        print("×temps réel : combien de secondes d'audio traitées par seconde de calcul.")
        print("écart : divergence avec la référence (0 % = découpage identique).")
        print("Un écart inférieur à ~5 % est en général sans conséquence sur un transcript ;")
        print("au-delà de ~15 %, vérifiez à l'oreille avant d'adopter le réglage.")
        print("\nAttention : la divergence ne dit pas qui a raison. Pour départager deux")
        print("modèles, relisez dix minutes dans la fenêtre de vérification et relancez")
        print("avec --reference sortie_xxx/xxx_transcript.json.")

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
