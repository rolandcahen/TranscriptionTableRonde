# TranscriptionTableRonde

App macOS native (SwiftUI) pour transcrire et identifier automatiquement les
locuteurs (« diarisation ») dans des enregistrements de tables rondes,
réunions ou entretiens en français — **100 % local**, sans envoyer aucun
audio ni texte sur Internet.

- **Transcription** : [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) (accéléré GPU sur Apple Silicon)
- **Diarisation** : [pyannote.audio](https://github.com/pyannote/pyannote-audio) (qui parle, et quand)
- **Résumé structuré** : [Ollama](https://ollama.com) + Mistral (analyse locale par catégories)

Seule exception au fonctionnement local : le tout premier téléchargement des
modèles (Hugging Face), ensuite mis en cache — jamais l'audio lui-même.

## Prérequis

- **Mac Apple Silicon** (M1 ou plus récent) — mlx-whisper ne fonctionne pas
  sur Mac Intel.
- macOS 14 (Sonoma) ou plus récent.
- [Xcode](https://apps.apple.com/app/xcode/id497799835) (pour compiler l'app).
- Python 3.10+ (`python3 --version`).
- Un compte [Hugging Face](https://huggingface.co) gratuit.

## 1. Installer le pipeline Python

```bash
# Homebrew si absent (https://brew.sh), puis ffmpeg
brew install ffmpeg

# Environnement virtuel — installé ici pour que l'app le retrouve
# automatiquement sans configuration (chemin par défaut des Réglages)
mkdir -p ~/transcription_pipeline
cp pipeline/*.py pipeline/requirements.txt ~/transcription_pipeline/
cd ~/transcription_pipeline
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### Compte Hugging Face et modèle de diarisation

1. Créez un compte gratuit sur [huggingface.co](https://huggingface.co).
2. Acceptez les conditions d'utilisation du modèle de diarisation :
   [huggingface.co/pyannote/speaker-diarization-3.1](https://huggingface.co/pyannote/speaker-diarization-3.1)
   (nécessite aussi l'acceptation du modèle de segmentation associé,
   [pyannote/segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0)
   — un lien apparaît sur la page ci-dessus).
3. Créez un token d'accès : [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens).

### Ollama (résumé structuré, optionnel)

```bash
brew install ollama
ollama pull mistral
```

## 2. Installer l'application

```bash
git clone <url-de-ce-dépôt>
cd TranscriptionTableRonde/app
open TranscriptionTableRonde.xcodeproj
```

Dans Xcode : sélectionnez le schéma **TranscriptionTableRonde**, puis
**Product → Run** (`⌘R`).

Au premier lancement, ouvrez les **Réglages** (`⌘,`) et renseignez :

- **Dossier du pipeline** : `~/transcription_pipeline` (déjà le bon si vous
  avez suivi l'étape 1 ci-dessus).
- **Interpréteur Python (venv)** : `~/transcription_pipeline/venv/bin/python3`.
- **Token Hugging Face** : collé depuis l'étape précédente — stocké dans le
  trousseau macOS, jamais en clair sur le disque.

## Utilisation rapide

1. Glissez un fichier audio dans la fenêtre principale, cliquez
   **Transcrire**.
2. Une fois terminé : **Vérifier / corriger** pour relire et corriger le
   texte face à l'audio, ou **Générer le résumé structuré** pour une
   synthèse par catégories (Ollama).
3. Pour traiter tout un dossier d'un coup (icône 🗂️ dans la barre
   d'outils) : voir la notice complète.

## Documentation complète

[`docs/NOTICE.md`](docs/NOTICE.md) — principes, installation détaillée
(développeur ou poste utilisateur), fonctionnement de chaque fenêtre, format
du fichier de contexte pour le traitement par lots, limitations connues.

## Structure du dépôt

```
app/           Projet Xcode (SwiftUI)
pipeline/      Scripts Python (transcription, diarisation, résumé)
docs/          Notice d'utilisation
```

## Limitations connues

- Mac Apple Silicon uniquement.
- Pas encore de `.dmg` packagé — installation par compilation Xcode
  uniquement pour l'instant (voir ci-dessus).
- Pas de mise à jour automatique — reclonez et recompilez pour les
  nouvelles versions.
