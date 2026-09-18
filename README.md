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
- [Xcode](https://apps.apple.com/app/xcode/id497799835) ou ses Command Line
  Tools (pour compiler l'app).
- [Homebrew](https://brew.sh) installé.
- Un compte [Hugging Face](https://huggingface.co) gratuit.

## Installation (recommandé : un seul script)

Un script installe tout automatiquement : ffmpeg, l'environnement Python du
pipeline et ses dépendances, Ollama + Mistral, puis il compile et installe
l'application.

```bash
git clone https://github.com/rolandcahen/TranscriptionTableRonde.git
cd TranscriptionTableRonde
chmod +x TranscriptionTableRonde_install.sh
./TranscriptionTableRonde_install.sh
```

Comptez 10 à 20 minutes selon votre connexion (le téléchargement de `torch`
et du modèle Mistral sont les étapes les plus longues). Le script s'arrête
avec un message clair si Xcode ou Homebrew manquent, plutôt que de tenter
une installation à moitié faite.

Ce script est conçu pour être relancé à l'identique sur plusieurs machines :
chaque installation est indépendante et 100 % locale (rien n'est partagé ni
désinstallé ailleurs). Pour répartir le travail sur plusieurs Mac, installez
sur chacun puis utilisez le traitement par lots (icône 🗂️) avec un dossier
de fichiers différent par machine.

Par défaut, le script installe dans `~/transcription_pipeline` (pipeline) et
`~/Applications` (app). Réglable :

```bash
PIPELINE_DIR=~/ma_config APP_DEST_DIR=/Applications ./TranscriptionTableRonde_install.sh
```

Pour sauter Ollama/Mistral (résumé automatique désactivé) :
`SKIP_OLLAMA=1 ./TranscriptionTableRonde_install.sh`.

> Astuce : vous pouvez renommer le script en `install.sh`
> (`git mv TranscriptionTableRonde_install.sh install.sh`) si vous préférez
> un nom plus court — adaptez alors les commandes ci-dessus en conséquence.

### Après l'installation

1. Créez un compte [Hugging Face](https://huggingface.co) gratuit et
   acceptez les conditions d'utilisation de ces deux modèles (nécessaire
   pour la diarisation) :
   - [huggingface.co/pyannote/speaker-diarization-3.1](https://huggingface.co/pyannote/speaker-diarization-3.1)
   - [huggingface.co/pyannote/segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0)
2. Créez un token d'accès : [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens).
3. Ouvrez l'app depuis `~/Applications` (clic droit → Ouvrir au tout premier
   lancement, avertissement Gatekeeper normal pour une app non signée par un
   compte développeur Apple payant), allez dans ses **Réglages** (`⌘,`) et
   collez le token — stocké dans le trousseau macOS, jamais en clair sur le
   disque.

## Installation manuelle / développement

Pour comprendre chaque étape, la personnaliser, ou travailler sur le code
dans Xcode plutôt que de simplement utiliser l'app compilée, voir
[`docs/NOTICE.md`](docs/NOTICE.md#2-installation) qui détaille la procédure
pas à pas (pipeline Python, Ollama, compilation via Xcode).

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
(automatique, développeur, ou poste utilisateur), fonctionnement de chaque
fenêtre, format du fichier de contexte pour le traitement par lots,
limitations connues.

## Structure du dépôt

```
TranscriptionTableRonde_install.sh   Installation automatique (recommandé)
app/           Projet Xcode (SwiftUI)
pipeline/      Scripts Python (transcription, diarisation, résumé)
docs/          Notice d'utilisation
```

## Limitations connues

- Mac Apple Silicon uniquement.
- Pas de `.dmg` packagé ni de signature par un compte développeur Apple
  payant — le script d'installation compile depuis le code source avec une
  signature ad-hoc (usage local), Gatekeeper affiche un avertissement au
  premier lancement de l'app.
- Pas de mise à jour automatique — reclonez (ou téléchargez le zip à jour)
  et relancez le script d'installation pour les nouvelles versions.
