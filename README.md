# TranscriptionTableRonde

App macOS native (SwiftUI) pour transcrire et identifier automatiquement les
locuteurs (« diarisation ») dans des enregistrements de tables rondes,
réunions ou entretiens en français — **100 % local**, sans envoyer aucun
audio ni texte sur Internet.

- **Transcription** : [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) (accéléré GPU sur Apple Silicon)
- **Diarisation** : [pyannote.audio](https://github.com/pyannote/pyannote-audio) (qui parle, et quand)
- **Résumé structuré** : [Ollama](https://ollama.com) avec un modèle local de 24 milliards
  de paramètres — relevé de notes attribuées aux locuteurs, rangement par
  catégories analytiques, et chaque point du résumé cite les passages dont
  il découle.

L'application mesure aussi ce qu'elle ne sait pas faire : chaque segment
porte un indice de netteté d'attribution, les passages où plusieurs
personnes parlent en même temps sont signalés, et le texte écrit là où la
diarisation n'entend personne — invention probable de Whisper sur du bruit —
est marqué pour relecture.

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

   Facultatif : [`speaker-diarization-community-1`](https://huggingface.co/pyannote/speaker-diarization-community-1),
   plus récent, utilisable avec `--diarization-model communaute-1`. Il n'est
   pas activé par défaut : mesurez-le d'abord sur vos propres
   enregistrements (voir `bench_diarization.py --reference`), car il améliore
   la distinction entre locuteurs mais pas la détection des passages où
   plusieurs personnes parlent ensemble.
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

1. Glissez un fichier audio dans la fenêtre principale. Un lecteur apparaît
   avec les caractéristiques du fichier (format, fréquence
   d'échantillonnage, canaux, durée) : vérifiez d'un coup d'œil que c'est
   bien le bon avant d'engager le calcul.
2. Cliquez **Transcrire**. Le bouton **Interrompre** arrête le traitement
   sans quitter l'application ; ce qui est déjà transcrit est conservé et
   une relance reprend à la diarisation.
3. Une fois terminé : **Vérifier / corriger** pour relire le texte face à
   l'audio, ou **Générer le résumé structuré**.
4. Pour traiter tout un dossier d'un coup, bouton **Lots** dans la barre
   d'outils, ou menu *Traitement* : voir la notice complète.

## Documentation complète

[`docs/NOTICE.md`](docs/NOTICE.md) — principes, installation détaillée
(automatique, développeur, ou poste utilisateur), fonctionnement de chaque
fenêtre, format du fichier de contexte pour le traitement par lots,
limitations connues.

## Structure du dépôt

```
TranscriptionTableRonde_install.sh   Installation automatique (recommandé)
app/           Projet Xcode (SwiftUI)
pipeline/      Scripts Python (transcription, diarisation, résumé, diagnostic)
docs/          Notice d'utilisation
docs/logos/    Logos institutionnels à pleine résolution (sources)
```

Les scripts du pipeline sont accompagnés de leurs tests, exécutables sans
rien installer de plus et sans toucher à un modèle :

```bash
cd ~/transcription_pipeline
venv/bin/python3 test_align.py                 # attribution des locuteurs
venv/bin/python3 test_qualite_transcription.py # défauts propres à Whisper
venv/bin/python3 test_summarize.py             # résumé : citations, synthèse
venv/bin/python3 test_transcript_to_csv.py     # export tableur
venv/bin/python3 test_bench_reference.py       # mesure contre une référence
```

## Limitations connues

- Mac Apple Silicon uniquement.
- **La parole simultanée ne se sépare pas.** Quand deux personnes parlent en
  même temps dans un enregistrement mono, aucun traitement ne démêle les
  voix. L'application le signale plutôt que de prétendre le contraire. La
  réponse est à la prise de son : un micro par participant rend la
  diarisation triviale.
- **Pas d'horodatage mot à mot.** Il serait la bonne façon de recaler une
  coupure au mot près, mais il multiplie par vingt le temps de
  transcription sur Apple Silicon — mesuré, puis écarté. La correspondance
  entre une position dans le texte et un instant du son reste donc
  proportionnelle, et approximative.
- Pas de `.dmg` packagé ni de signature par un compte développeur Apple
  payant — le script d'installation compile depuis le code source avec une
  signature ad-hoc (usage local), Gatekeeper affiche un avertissement au
  premier lancement de l'app.
- Pas de mise à jour automatique — reclonez (ou téléchargez le zip à jour)
  et relancez le script d'installation pour les nouvelles versions.
