#!/usr/bin/env bash
# Installation complète, en une commande, SUR CETTE MACHINE :
# ffmpeg, pipeline Python (transcription + diarisation + résumé), Ollama +
# Mistral, puis compilation et installation de l'app.
#
# Pensé pour tourner à l'identique sur plusieurs machines : chaque
# installation est indépendante et 100 % locale (rien n'est partagé entre
# machines, rien n'est envoyé en ligne à part le tout premier téléchargement
# des modèles). Lancer ce même script sur chaque poste pour les faire
# travailler en parallèle, chacun sur ses propres fichiers.
#
# Usage :
#   chmod +x install.sh
#   ./install.sh
#
# Variables surchargeables (exemple : PIPELINE_DIR=~/ma_config ./install.sh) :
#   PIPELINE_DIR   dossier du pipeline Python   (défaut : ~/transcription_pipeline)
#   APP_DEST_DIR   dossier d'installation de l'app (défaut : ~/Applications)
#   SKIP_OLLAMA=1  pour sauter Ollama/Mistral (résumé automatique indisponible)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="${PIPELINE_DIR:-$HOME/transcription_pipeline}"
APP_DEST_DIR="${APP_DEST_DIR:-$HOME/Applications}"
SKIP_OLLAMA="${SKIP_OLLAMA:-0}"
APP_TARGET="TranscriptionTableRonde"
XCODEPROJ="$REPO_DIR/app/${APP_TARGET}.xcodeproj"

echo "=== 0/5 : Vérifications préalables ==="

if [ "$(uname)" != "Darwin" ]; then
    echo "Ce script doit être exécuté sur macOS. Arrêt."
    exit 1
fi

if [ ! -d "$XCODEPROJ" ]; then
    echo "Projet Xcode introuvable : $XCODEPROJ"
    echo "Lancez ce script depuis la racine du dépôt cloné."
    exit 1
fi

ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ]; then
    echo "Attention : mlx-whisper nécessite une puce Apple Silicon (arm64)."
    echo "Architecture détectée : $ARCH. La suite risque d'échouer."
    read -r -p "Continuer quand même ? [o/N] " reponse
    [[ "$reponse" =~ ^[oO]$ ]] || exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode (ou ses Command Line Tools) n'est pas installé."
    echo "Lancement de l'installation (une fenêtre va s'ouvrir) :"
    xcode-select --install || true
    echo "Relancez ce script une fois l'installation terminée."
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 introuvable. Installez-le avec : brew install python"
    exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew n'est pas installé. Installez-le depuis https://brew.sh puis relancez ce script."
    exit 1
fi

echo ""
echo "=== 1/5 : ffmpeg ==="
if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "Installation de ffmpeg…"
    brew install ffmpeg
else
    echo "ffmpeg déjà présent."
fi

echo ""
echo "=== 2/5 : Pipeline Python (transcription + diarisation + résumé) ==="
mkdir -p "$PIPELINE_DIR"
cp "$REPO_DIR"/pipeline/*.py "$PIPELINE_DIR"/
cp "$REPO_DIR"/pipeline/requirements.txt "$PIPELINE_DIR"/

if [ ! -d "$PIPELINE_DIR/venv" ]; then
    echo "Création de l'environnement virtuel…"
    python3 -m venv "$PIPELINE_DIR/venv"
fi
echo "Installation des dépendances (mlx-whisper, pyannote, torch — peut prendre plusieurs minutes)…"
"$PIPELINE_DIR/venv/bin/pip" install --upgrade pip --quiet
"$PIPELINE_DIR/venv/bin/pip" install -r "$PIPELINE_DIR/requirements.txt"

echo "Vérification de la logique d'alignement (tests unitaires, hors ligne)…"
(cd "$PIPELINE_DIR" && "$PIPELINE_DIR/venv/bin/python3" test_align.py)

echo ""
echo "=== 3/5 : Ollama + Mistral (résumé structuré) ==="
if [ "$SKIP_OLLAMA" = "1" ]; then
    echo "SKIP_OLLAMA=1 : étape sautée (le résumé automatique ne sera pas disponible)."
else
    if ! command -v ollama >/dev/null 2>&1; then
        echo "Installation d'Ollama…"
        brew install ollama
    else
        echo "Ollama déjà présent."
    fi
    echo "Démarrage du service Ollama en arrière-plan (si pas déjà lancé)…"
    brew services start ollama >/dev/null 2>&1 || true
    echo "Téléchargement du modèle Mistral (peut prendre plusieurs minutes)…"
    ollama pull mistral
fi

echo ""
echo "=== 4/5 : Compilation et installation de l'app macOS ==="
BUILD_DIR="$REPO_DIR/app/.build_tmp"
rm -rf "$BUILD_DIR"
# Signature ad-hoc forcée en ligne de commande (n'affecte pas le projet lui
# -même) : permet de compiler sans compte développeur Apple, pour un usage
# strictement local, sur n'importe quelle machine.
xcodebuild \
    -project "$XCODEPROJ" \
    -target "$APP_TARGET" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="-" \
    DEVELOPMENT_TEAM="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    build

BUILT_APP="$BUILD_DIR/Build/Products/Release/${APP_TARGET}.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "Erreur : app introuvable après compilation ($BUILT_APP)"
    exit 1
fi

mkdir -p "$APP_DEST_DIR"
rm -rf "${APP_DEST_DIR:?}/${APP_TARGET}.app"
cp -R "$BUILT_APP" "$APP_DEST_DIR/"
rm -rf "$BUILD_DIR"

echo ""
echo "=== 5/5 : Terminé ==="
echo "App installée      : $APP_DEST_DIR/${APP_TARGET}.app"
echo "Pipeline installé  : $PIPELINE_DIR"
echo ""
echo "Il reste, une seule fois par machine :"
echo "  1. Compte Hugging Face + acceptation des conditions de :"
echo "       https://huggingface.co/pyannote/speaker-diarization-3.1"
echo "       https://huggingface.co/pyannote/segmentation-3.0"
echo "  2. Un token : https://huggingface.co/settings/tokens"
echo "  3. Ouvrir l'app depuis $APP_DEST_DIR, Réglages (⌘,), coller le token."
echo ""
echo "Premier lancement : clic droit sur l'app → Ouvrir (avertissement"
echo "Gatekeeper attendu une seule fois, l'app n'étant pas signée par un"
echo "compte développeur Apple payant)."
