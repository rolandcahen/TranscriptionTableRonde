"""Rend les bibliothèques FFmpeg visibles pour torchcodec, sur macOS.

Le problème : les .dylib livrés par torchcodec (utilisé par pyannote pour
décoder l'audio) référencent FFmpeg via `@rpath/libavutil.NN.dylib` sans
embarquer le moindre LC_RPATH. dyld n'a donc aucun endroit où chercher et
le chargement échoue sur « Could not load libtorchcodec / no LC_RPATH's
found », même quand FFmpeg est parfaitement installé par Homebrew.

La variable d'environnement DYLD_FALLBACK_LIBRARY_PATH répare ça, mais
dyld ne la lit qu'au démarrage du processus : la définir depuis Python
une fois l'interpréteur lancé n'aurait aucun effet sur les dlopen()
suivants. La seule solution fiable côté script est donc de relancer
l'interpréteur une fois, avec la variable en place.

Ce module existe pour que la correction s'applique partout — l'app macOS,
la ligne de commande, le banc d'essai — plutôt que dans le seul
PipelineRunner.swift, qui ne couvre que l'app.
"""
from __future__ import annotations

import os
import sys

# Empêche toute boucle de relance : si la variable est posée et que le
# problème persiste (SIP qui la filtre, FFmpeg réellement absent), on
# laisse l'erreur d'origine remonter plutôt que de relancer sans fin.
RELAUNCH_FLAG = "TTR_DYLD_RELAUNCHED"

CANDIDATE_PATHS = (
    "/opt/homebrew/lib",
    "/opt/homebrew/opt/ffmpeg/lib",
    "/usr/local/lib",
    "/usr/local/opt/ffmpeg/lib",
)


def paths_to_add(existing: str, candidates=None, isdir=os.path.isdir) -> list[str]:
    """Dossiers à ajouter : ceux qui existent et ne sont pas déjà listés.

    Fonction pure (les dépendances système sont injectables) pour être
    testable sans macOS ni FFmpeg. `candidates` est résolu à l'appel et
    non lié comme valeur par défaut, pour qu'une installation atypique
    puisse redéfinir CANDIDATE_PATHS et que ce soit effectivement pris en
    compte.
    """
    candidates = CANDIDATE_PATHS if candidates is None else candidates
    present = {p for p in existing.split(":") if p}
    return [p for p in candidates if p not in present and isdir(p)]


def ensure_ffmpeg_visible(platform: str = sys.platform, environ=None, execve=None) -> bool:
    """Relance l'interpréteur avec DYLD_FALLBACK_LIBRARY_PATH si nécessaire.

    Ne rend la main que s'il n'y a rien à faire ; sinon le processus est
    remplacé et cette fonction ne retourne jamais. Renvoie True quand une
    relance a été déclenchée (utile pour les tests, où execve est simulé).
    """
    environ = os.environ if environ is None else environ
    execve = os.execve if execve is None else execve

    if platform != "darwin" or environ.get(RELAUNCH_FLAG):
        return False

    existing = environ.get("DYLD_FALLBACK_LIBRARY_PATH", "")
    ajouts = paths_to_add(existing)
    if not ajouts:
        return False

    nouvel_env = dict(environ)
    nouvel_env["DYLD_FALLBACK_LIBRARY_PATH"] = ":".join(ajouts + ([existing] if existing else []))
    nouvel_env[RELAUNCH_FLAG] = "1"
    execve(sys.executable, [sys.executable] + sys.argv, nouvel_env)
    return True
