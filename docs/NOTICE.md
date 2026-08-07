# Notice d'utilisation — Transcription Table Ronde

*Version provisoire — 7 août 2026. Ce document sera retravaillé au fur et à
mesure de l'évolution de l'application ; les captures d'écran seront
ajoutées manuellement.*

## Sommaire

1. [Présentation générale et principes](#1-présentation-générale-et-principes)
2. [Installation](#2-installation)
3. [Fonctionnement général](#3-fonctionnement-général)
4. [L'interface, fenêtre par fenêtre](#4-linterface-fenêtre-par-fenêtre)
5. [Le résumé structuré](#5-le-résumé-structuré)
6. [Limitations connues](#6-limitations-connues)
7. [Glossaire](#7-glossaire)

## 1. Présentation générale et principes

**Transcription Table Ronde** est une application macOS qui transcrit et
identifie automatiquement les locuteurs (« diarisation ») dans des
enregistrements audio de réunions, tables rondes ou entretiens, puis peut en
générer un résumé structuré. Elle a été conçue pour des enregistrements en
français, typiquement des réunions de conception avec plusieurs
intervenants.

**Principe central : tout se passe en local, sur votre Mac.** Aucun
enregistrement, aucun texte transcrit n'est envoyé sur Internet. Trois
moteurs tournent entièrement sur la machine :

- **[mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper)** — reconnaissance vocale (audio → texte), optimisée pour les puces Apple Silicon.
- **[pyannote.audio](https://github.com/pyannote/pyannote-audio)** — diarisation (qui parle, et quand), c'est-à-dire la détection et la séparation des différents locuteurs.
- **[Ollama](https://ollama.com) + Mistral** — génération du résumé structuré, un modèle de langage local qui lit le transcript et en extrait une synthèse organisée par catégories.

Seule exception : la récupération du modèle de diarisation pyannote
nécessite un compte [Hugging Face](https://huggingface.co) gratuit (accès à
Internet uniquement au premier téléchargement du modèle, jamais pour l'audio
lui-même).

L'application est une interface graphique (SwiftUI) qui pilote des scripts
Python existants (le « pipeline », dossier [`pipeline/`](../pipeline))
installés séparément sur la machine. Elle ne réimplémente aucun des
traitements : elle lance ces scripts, affiche leur progression, et propose
des outils pour vérifier/corriger et résumer les résultats.

## 2. Installation

> Deux profils différents : suivez **2.A** si vous compilez et développez
> l'application (nouvelle machine de travail, mise à jour du code), ou
> **2.B** si vous recevez simplement l'application déjà compilée pour
> l'utiliser au labo, sans toucher au code.

### Prérequis (dans les deux cas)

- **Mac Apple Silicon** (puce M1 ou plus récente) — mlx-whisper ne
  fonctionne pas sur Mac Intel.
- **macOS 14 (Sonoma) ou plus récent**.
- Un compte [Hugging Face](https://huggingface.co) gratuit, avec acceptation
  des conditions d'utilisation des modèles pyannote utilisés pour la
  diarisation, et un jeton d'accès (« token », commence par `hf_`).

### 2.A Installation développeur (clonage + compilation)

**1. Cloner le dépôt**

```bash
git clone https://github.com/rolandcahen/TranscriptionTableRonde.git
cd TranscriptionTableRonde
```

**2. Installer le pipeline Python**

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
cd -
```

**3. Créer le token Hugging Face**

1. Créez un compte gratuit sur [huggingface.co](https://huggingface.co).
2. Acceptez les conditions d'utilisation du modèle de diarisation :
   [huggingface.co/pyannote/speaker-diarization-3.1](https://huggingface.co/pyannote/speaker-diarization-3.1)
   (nécessite aussi l'acceptation du modèle de segmentation associé,
   [pyannote/segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0)
   — un lien apparaît sur la page ci-dessus).
3. Créez un token d'accès : [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens).

**4. Installer Ollama (résumé structuré, optionnel)**

```bash
brew install ollama
ollama pull mistral
```

**5. Compiler et lancer l'application**

```bash
open app/TranscriptionTableRonde.xcodeproj
```

Dans Xcode : sélectionnez le schéma **TranscriptionTableRonde**, puis
**Product → Run** (`⌘R`).

**6. Configurer l'application au premier lancement** — voir
[« Configuration au premier lancement »](#configuration-au-premier-lancement)
ci-dessous.

### 2.B Installation utilisateur (application déjà compilée)

Pour un poste du labo qui n'a pas besoin de développer, seulement d'utiliser
l'application déjà compilée par ailleurs (fichier `TranscriptionTableRonde.app`
transmis par clé USB, AirDrop, etc.) :

1. Effectuez quand même les étapes **pipeline Python**, **token Hugging
   Face** et **Ollama** ci-dessus (2.A, points 2 à 4) — elles sont
   indépendantes de la compilation.
2. Copiez `TranscriptionTableRonde.app` dans le dossier **Applications**.
3. Au premier lancement, macOS affichera un avertissement Gatekeeper
   (l'app n'est pas signée par un compte développeur Apple payant) :
   faites un clic droit → **Ouvrir**, puis confirmez. Cette étape n'est
   nécessaire qu'une seule fois.
4. Configurez l'application au premier lancement — voir ci-dessous.

> Un installateur en un clic (`.dmg` + script d'installation du pipeline)
> qui éviterait le Terminal est envisagé mais n'existe pas encore — voir
> [Limitations connues](#6-limitations-connues).

### Configuration au premier lancement

Ouvrez les **Réglages** de l'application (icône ⚙️ dans la barre d'outils,
ou raccourci `⌘,`) et renseignez :

- **Dossier du pipeline** — chemin vers `~/transcription_pipeline` (déjà le
  bon si vous avez suivi les étapes ci-dessus).
- **Interpréteur Python (venv)** — chemin vers l'exécutable Python de
  l'environnement virtuel créé plus haut
  (`~/transcription_pipeline/venv/bin/python3`).
- **Token Hugging Face** — collé dans le champ dédié. Il est stocké dans le
  trousseau macOS (Keychain), jamais en clair dans les préférences de
  l'application.

> 📷 *Capture d'écran à ajouter : fenêtre Réglages*

Tant que le token n'est pas renseigné, la fenêtre principale affiche un
avertissement et le bouton « Transcrire » reste désactivé.

## 3. Fonctionnement général

Deux façons d'utiliser l'application, selon le volume à traiter :

- **Fichier par fichier** (fenêtre principale) — pour transcrire un
  enregistrement à la fois, avec suivi en direct.
- **Traitement par lots** (fenêtre dédiée) — pour pointer un dossier entier
  contenant plusieurs enregistrements (ex. toutes les sessions d'une
  conférence) et laisser la machine les traiter les uns après les autres,
  typiquement la nuit.

Dans les deux cas, le déroulement est le même pour chaque fichier :

1. **Transcription** — l'audio est converti en texte (mlx-whisper).
2. **Diarisation** — les segments de parole sont attribués à des locuteurs
   anonymes (`SPEAKER_00`, `SPEAKER_01`, …) (pyannote).
3. **Fusion** — les deux résultats sont combinés et écrits sur disque, dans
   un dossier `sortie_<nom du fichier>` créé à côté de l'audio.

À partir de là, deux étapes optionnelles, dans l'ordre que l'on souhaite :

- **Vérifier / corriger** — relire le transcript face à l'audio, corriger le
  texte, renommer les locuteurs (ex. `SPEAKER_00` → « Roland Cahen »).
- **Générer le résumé structuré** — produit une synthèse organisée par
  catégories (état de la recherche, questions, réponses, etc.), à partir du
  transcript corrigé s'il existe, sinon du transcript brut.

### Le champ « Contexte »

Un champ de texte libre optionnel permet d'indiquer le sujet, les
participants, les organismes et les termes techniques attendus dans
l'enregistrement. Ce texte sert à deux choses :

- il est transmis à mlx-whisper comme indice de départ, ce qui améliore la
  reconnaissance des noms propres et du vocabulaire spécifique (ex. « Cor
  des Alpes » plutôt que « corps des Alpes ») ;
- il est réutilisé comme base pour le résumé structuré, afin que Mistral
  comprenne le sujet et les rôles des intervenants.

**Limite à connaître** : le contexte oriente la reconnaissance mais ne
garantit pas une correction systématique — un homophone parfait comme « Cor
des Alpes » / « corps des Alpes » peut encore apparaître dans le transcript
brut. C'est le rôle de l'étape « Vérifier / corriger » de rattraper ces cas,
et le résumé (qui a accès au même contexte) corrige souvent l'erreur de
lui-même dans sa synthèse.

## 4. L'interface, fenêtre par fenêtre

### 4.1 Fenêtre principale

> 📷 *Capture d'écran à ajouter : fenêtre principale*

Éléments, de haut en bas :

- **Zone de dépôt** — glisser un fichier audio (`.wav`, `.mp3`, et autres
  formats courants) ou cliquer pour en choisir un via le sélecteur de
  fichiers.
- **Contexte** (optionnel) — zone de texte dépliable, voir
  [3.1](#le-champ--contexte-).
- **Modèle** — choix du modèle mlx-whisper (`large-v3-turbo` par défaut,
  plus rapide ; `large-v3`, plus précis mais plus lent ; `medium`, plus
  léger).
- **Nb de locuteurs** (optionnel) — si le nombre exact de participants est
  connu, le préciser améliore la fiabilité de la diarisation. Laissé vide,
  pyannote détecte automatiquement le nombre de locuteurs.
- **Bouton « Transcrire »** — lance le traitement (raccourci `⌘⏎`).
  Désactivé tant qu'aucun fichier n'est choisi ou que le token Hugging Face
  manque.
- **Barre de progression** — indique l'étape en cours (1/3 Transcription,
  2/3 Diarisation, 3/3 Fusion). Les étapes 1 et 2 n'affichent pas de
  pourcentage détaillé (le moteur ne le fournit pas) : seul le spinner
  tourne, ce qui est normal, y compris pendant plusieurs minutes sur un long
  enregistrement.
- **Journal** — sortie texte détaillée du traitement en cours, copiable via
  le bouton « Copier le journal ».
- **Bandeau de résultat** — une fois terminé, accès direct au dossier de
  sortie via « Révéler dans le Finder ».

Une fois la transcription terminée, une zone supplémentaire apparaît :

- **Bouton « Vérifier / corriger »** — ouvre l'éditeur de relecture
  ([4.3](#43-fenêtre-vérification--correction)).
- **Bouton « Générer le résumé structuré »** — lance le résumé via
  Ollama/Mistral ([section 5](#5-le-résumé-structuré)).
- **Catégories du résumé** — zone dépliable, une catégorie par ligne,
  modifiable selon le type de réunion (les catégories par défaut sont
  listées en section 5).

Barre d'outils (en haut à droite de la fenêtre), trois icônes :

- 🗂️ (plateau) — ouvre la fenêtre de traitement par lots
  ([4.4](#44-fenêtre-traitement-par-lots)).
- 🕐 (horloge) — ouvre une session déjà traitée sans refaire la
  transcription : sélectionner le fichier audio d'origine, l'application
  retrouve automatiquement le dossier `sortie_…` correspondant et recharge
  son état (y compris le contexte utilisé).
- ⚙️ (roue crantée) — ouvre les Réglages.

### 4.2 Fenêtre Réglages

Voir [« Configuration au premier lancement »](#configuration-au-premier-lancement)
pour le détail des champs (dossier du pipeline, interpréteur Python, token
Hugging Face). Accessible à tout moment via `⌘,` ou l'icône ⚙️.

### 4.3 Fenêtre Vérification / correction

> 📷 *Capture d'écran à ajouter : éditeur de vérification*

Ouverte depuis la fenêtre principale ou depuis la file de traitement par
lots, une fois qu'un transcript existe. Elle affiche le texte transcrit
segment par segment, en regard de l'audio original.

**Lecteur audio** (en haut de la fenêtre) : une barre de défilement commune
à toute la fenêtre, avec boutons lecture / pause / stop et affichage du
temps écoulé. Cliquer sur le bouton ▶ d'un segment déplace la lecture à son
début.

**En-tête des locuteurs** : un champ par locuteur détecté (`SPEAKER_00`,
`SPEAKER_01`, …), avec le nombre d'interventions, le temps de parole total,
et un aperçu du premier propos — permet de reconnaître rapidement qui est
qui et de saisir son vrai nom. Ce renommage s'applique à tous les segments
de ce locuteur à la fois.

**Liste des segments**, un par un :

- horodatage début/fin, éditable directement (format `hh:mm:ss`) ;
- menu déroulant pour réattribuer le segment à un autre locuteur (utile
  quand la diarisation automatique s'est trompée) ;
- texte éditable, avec un fond coloré selon la confiance de la
  reconnaissance : vert (bonne confiance), orange (moyenne), rouge
  (faible) ;
- icône ⚠️ si le segment est signalé : confiance faible, silence probable,
  mot répété, segment anormalement long ou court — survoler l'icône affiche
  la raison précise ;
- bouton 🗑️ pour supprimer un segment erroné, bouton « + Ajouter un
  segment » (en haut) pour en créer un manuellement au point de lecture
  actuel.

Bouton **« Enregistrer »** (`⌘S`) : réécrit le fichier transcript et
régénère le fichier texte final utilisé ensuite par le résumé — aucune
étape intermédiaire nécessaire.

### 4.4 Fenêtre Traitement par lots

> 📷 *Capture d'écran à ajouter : fenêtre de traitement par lots*

Permet de traiter tout un dossier d'enregistrements automatiquement, à la
suite, sans intervention (adapté à un traitement de nuit).

**Choisir un dossier…** — scanne le dossier sélectionné (uniquement les
fichiers à sa racine, pas les sous-dossiers) et construit la liste des
fichiers audio à traiter.

**Résolution automatique du contexte et du nombre de locuteurs** — pour
éviter de ressaisir le contexte fichier par fichier, un seul fichier texte
nommé `Contexte` (sans extension, ou `Contexte.txt`) placé à la racine du
dossier peut regrouper les informations de tous les fichiers. Format : le
nom exact de chaque fichier audio, suivi de son paragraphe de contexte,
chaque bloc séparé par une ligne vide :

```
4-RéunionJuridique 2.mp3
Locuteurs: 5
Discussion sur une convention de partenariat entre le CFMI...

1-RéunionPrésentationProjAM.mp3
Locuteurs: 3
Jean Jeltsh présente le CFMI aux concepteurs de l'ENSCi...
```

- La ligne `Locuteurs: N` est optionnelle, insensible à la casse, et peut
  aussi s'écrire `Locuteur : N`, `Nb locuteurs :` ou `Nombre de
  locuteurs :`. Elle peut être placée avant ou après le paragraphe de
  contexte.
- Sans cette ligne, le fichier est traité sans contrainte de nombre de
  locuteurs (détection automatique).
- Alternative : un fichier texte séparé portant exactement le même nom que
  l'audio (ex. `4-RéunionJuridique 2.txt`) sert de contexte spécifique à ce
  seul fichier.

**Important** : le contexte et le nombre de locuteurs ne sont résolus qu'au
moment du scan. Si le dossier a déjà été scanné une première fois avant
l'écriture ou la modification du fichier `Contexte`, il faut vider la file
(bouton « Vider la file ») puis choisir le dossier à nouveau pour que les
changements soient pris en compte.

Une fois la file constituée, chaque ligne affiche le nom du fichier, son
statut (⏳ en attente, ▶️ en cours, ✅ terminé, ❌ échoué), et un petit
résumé de ce qui a été résolu (« contexte fourni · 5 locuteurs ») pour
vérifier visuellement que tout est correct avant de lancer le traitement.

**Contrôles globaux** (en haut de la fenêtre) :

- **Démarrer / Mettre en pause** — lance ou interrompt la file. La mise en
  pause n'arrête pas le fichier en cours : il va à son terme, puis la file
  s'arrête avant le suivant.
- **Générer tous les résumés** — lance le résumé structuré pour tous les
  fichiers déjà terminés, à la suite (chemin « rapide », sans relecture
  préalable).
- **Vider la file** — interrompt immédiatement le fichier en cours et
  retire tous les jobs de la liste (les fichiers déjà transcrits restent
  sur le disque, rien n'est supprimé). Une confirmation est demandée avant
  d'agir.

**Actions par fichier**, selon son statut :

- **Réessayer** (si échoué) — remet le fichier en attente.
- **Vérifier / corriger** et **Résumé** (si terminé) — ouvrent les mêmes
  fenêtres que dans le flux fichier unique.
- **Finder** — révèle le dossier de sortie du fichier.
- 🗑️ — retire un fichier individuel de la liste (sauf s'il est en cours de
  traitement).

**Reprise après interruption** — la file d'attente est sauvegardée en
continu. Si l'application se ferme, plante, ou si le Mac s'éteint pendant un
traitement, les fichiers déjà terminés restent acquis (rien n'est refait) ;
le fichier interrompu en cours repart intégralement de zéro au redémarrage
(aucun moteur ne sait reprendre une transcription au milieu). Si la file
était active, le traitement reprend automatiquement au lancement suivant de
l'application.

**Limite matérielle à connaître** : l'application empêche la mise en veille
automatique par inactivité pendant un traitement, mais ne peut pas empêcher
la mise en veille au rabat de l'écran (capot fermé) sur un MacBook non
branché à un écran externe — c'est un comportement matériel de macOS. Pour
un traitement de nuit fiable, laisser l'écran ouvert (sur secteur) ou
brancher un écran externe.

## 5. Le résumé structuré

Une fois un transcript disponible (brut ou corrigé), le bouton « Générer le
résumé structuré » lance une analyse locale via Ollama et le modèle
Mistral. Le transcript est découpé en tranches d'environ 3000 mots, chaque
tranche est résumée, puis les résumés partiels sont fusionnés et organisés
selon les catégories définies.

Catégories par défaut (modifiables dans la zone dépliable « Catégories du
résumé », une par ligne) :

- État de la recherche
- Questions posées
- Réponses apportées
- Difficultés mises en avant
- Propositions de développement
- Implications techniques
- Implications financières
- Autres éléments pertinents

Deux fichiers sont générés dans le dossier de sortie : un `.md` (Markdown,
lisible directement, ouvert via le bouton « Ouvrir le résumé ») et un
`.json` (structuré, réutilisable par un outil externe pour croiser plusieurs
enregistrements).

## 6. Limitations connues

- **Pas de diffusion packagée** — l'installation reste manuelle
  ([section 2](#2-installation)). Un installateur en un clic (`.dmg` +
  script d'installation du pipeline) est prévu mais pas encore réalisé.
- **Fermeture de l'application pendant un traitement** — quitter
  l'application ne termine pas toujours proprement le processus Python en
  cours ; en cas de doute, vérifier via le Moniteur d'activité qu'aucun
  processus `python` résiduel ne tourne avant de relancer un traitement sur
  le même fichier.
- **Traitement par lots : dossier racine uniquement** — les sous-dossiers ne
  sont pas parcourus automatiquement dans cette version.
- **Pas de mise à jour automatique** — toute nouvelle version de
  l'application doit être réinstallée manuellement (`git pull` + recompiler,
  ou remplacement dans le dossier Applications).

## 7. Glossaire

- **Transcription** — conversion de l'audio en texte.
- **Diarisation** — détection de « qui parle quand », sans identification
  des noms (locuteurs anonymes `SPEAKER_00`, etc.).
- **Token Hugging Face** — identifiant personnel gratuit permettant de
  télécharger les modèles de diarisation pyannote.
- **Contexte** — texte libre décrivant le sujet/les participants d'un
  enregistrement, utilisé pour améliorer la reconnaissance et le résumé.
- **Résumé structuré** — synthèse organisée par catégories, générée
  localement par un modèle de langage (Mistral via Ollama).
