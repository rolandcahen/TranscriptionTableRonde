# Notice d'utilisation — Transcription Table Ronde

*Application version 1.1 — notice mise à jour le 7 octobre 2026. Ce
document suit l'évolution de l'application ; les captures d'écran seront
ajoutées manuellement.*

## Sommaire

1. [Présentation générale et principes](#1-présentation-générale-et-principes)
2. [Installation](#2-installation)
3. [Fonctionnement général](#3-fonctionnement-général)
4. [L'interface, fenêtre par fenêtre](#4-linterface-fenêtre-par-fenêtre)
5. [Le résumé structuré](#5-le-résumé-structuré)
6. [Exporter vers un tableur](#6-exporter-vers-un-tableur)
7. [Limitations connues](#7-limitations-connues)
8. [Glossaire](#8-glossaire)

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

> Trois façons de faire, du plus simple au plus manuel : **2.0** pour
> installer en une commande sur une nouvelle machine (recommandé, y compris
> pour un simple poste d'utilisation) ; **2.A** si vous voulez comprendre ou
> personnaliser chaque étape, ou travailler sur le code dans Xcode ; **2.B**
> si on vous a transmis directement `TranscriptionTableRonde.app` déjà
> compilée (clé USB, AirDrop) et que vous ne voulez pas du tout de Terminal
> pour la partie compilation.

### Prérequis (dans les trois cas)

- **Mac Apple Silicon** (puce M1 ou plus récente) — mlx-whisper ne
  fonctionne pas sur Mac Intel.
- **macOS 14 (Sonoma) ou plus récent**.
- Un compte [Hugging Face](https://huggingface.co) gratuit, avec acceptation
  des conditions d'utilisation des modèles pyannote utilisés pour la
  diarisation, et un jeton d'accès (« token », commence par `hf_`).

### 2.0 Installation automatique (recommandé)

Un script installe tout en une commande : ffmpeg, pipeline Python complet
(avec son environnement virtuel), Ollama + Mistral, puis compile et installe
l'application dans `~/Applications`.

```bash
git clone https://github.com/rolandcahen/TranscriptionTableRonde.git
cd TranscriptionTableRonde
chmod +x TranscriptionTableRonde_install.sh
./TranscriptionTableRonde_install.sh
```

Comptez 10 à 20 minutes (le téléchargement de `torch` et du modèle Mistral
sont les étapes les plus longues). Le script vérifie Xcode et Homebrew au
démarrage et s'arrête avec un message clair s'ils manquent, plutôt que de
laisser une installation à moitié faite.

Il est prévu pour être relancé à l'identique sur plusieurs Mac : chaque
installation est indépendante et entièrement locale (rien n'est partagé, ni
désinstallé, d'une machine à l'autre). Pour répartir un lot d'enregistrements
sur plusieurs machines, installez sur chacune puis utilisez le traitement
par lots ([4.4](#44-fenêtre-traitement-par-lots)) avec un dossier différent
par machine.

Deux variables d'environnement optionnelles :

```bash
# Emplacements différents du défaut (~/transcription_pipeline, ~/Applications)
PIPELINE_DIR=~/ma_config APP_DEST_DIR=/Applications ./TranscriptionTableRonde_install.sh

# Sans Ollama/Mistral (le résumé automatique restera indisponible)
SKIP_OLLAMA=1 ./TranscriptionTableRonde_install.sh
```

Une fois le script terminé, il ne reste que la création du token Hugging
Face (étape 3 de 2.A juste en dessous) puis [« Configuration au premier
lancement »](#configuration-au-premier-lancement) — les autres étapes de
2.A (pipeline, Ollama, compilation) sont déjà faites par le script.

### 2.A Installation développeur (étape par étape)

Pour comprendre ou personnaliser chaque étape plutôt que de passer par
2.0, ou pour travailler sur le code dans Xcode :

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

> Pour ce cas précis (app déjà compilée, transmise directement), 2.0 ne
> s'applique pas telle quelle puisqu'elle recompile depuis le code source —
> mais rien n'empêche de lancer quand même
> `TranscriptionTableRonde_install.sh` sur le poste receveur pour préparer
> pipeline + Ollama automatiquement, puis de remplacer l'app qu'il vient de
> compiler par celle reçue si vous préférez ne pas recompiler localement.

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
   un dossier `sortie_<nom du fichier>`, créé à côté de l'audio ou dans le
   dossier de sauvegarde si vous en avez configuré un ([4.2](#42-fenêtre-réglages)).

La diarisation s'exécute sur le GPU de la puce Apple quand il est
disponible, avec repli automatique sur le processeur en cas d'échec. Sur un
extrait de dix minutes mesuré à l'identique, le passage au GPU fait tomber
le temps de diarisation de 409 à 28 secondes — soit 21 fois le temps réel —
pour un découpage rigoureusement identique. Concrètement, une table ronde de
2 h 30 se diarise en une dizaine de minutes au lieu d'une heure quarante.

Pour mesurer ce gain sur votre propre machine et vos propres
enregistrements, `pipeline/bench_diarization.py` compare plusieurs réglages
sur un court extrait et affiche un tableau : temps, accélération, et surtout
écart de résultat avec la configuration de référence. Le script
`transcribe_diarize.py` accepte par ailleurs `--device cpu` si vous devez
forcer l'ancien comportement.

La transcription est écrite sur disque dès la fin de l'étape 1, dans un
fichier `<nom>_whisper_raw.json`. Si la diarisation échoue ou si vous
interrompez le traitement, la transcription est acquise : la relance repart
directement à l'étape 2. Ce cache n'est réutilisé que si l'audio, le modèle,
la langue, le contexte **et les réglages de décodage** sont inchangés —
modifier l'un d'eux refait la transcription. Effet utile : relancer avec un
nombre de locuteurs différent ne recalcule que la diarisation.

### Pourquoi Whisper ne réinjecte plus son propre texte

Par défaut, Whisper reprend le texte déjà transcrit comme contexte de la
fenêtre suivante. Ce mécanisme améliore la cohérence d'une fenêtre à
l'autre, mais c'est aussi lui qui permet au modèle de se bloquer en boucle
de répétition et de propager une invention sur plusieurs minutes.

Mesuré sur un extrait de dix minutes : avec la réinjection, **258 mots
inventés en boucle, dont 216 sur un seul segment** — et ces 216 mots
remplaçaient la parole réelle du passage. Sans elle, aucune boucle, et la
part de temps signalée comme douteuse tombe de 16,8 % à 7,9 %.

La réinjection est donc **désactivée par défaut** depuis la version 1.1.
`--condition-on-previous-text` la rétablit si la cohérence des noms propres
d'une fenêtre à l'autre compte plus, pour vous, que la robustesse.

### Ce que l'application sait de sa propre fiabilité

Trois indicateurs sont calculés pour chaque segment, sans aucun coût de
calcul supplémentaire — ils étaient déjà dans la sortie de pyannote, et
l'alignement les jetait :

- **netteté d'attribution** — parmi la parole détectée dans ce segment,
  quelle part revient au locuteur retenu. 100 % signifie qu'il est seul à
  parler. Une valeur basse signale soit un segment à cheval sur deux tours
  successifs, soit une parole réellement simultanée ;
- **part de parole** — quelle fraction de la durée du segment contient de la
  parole détectée. Un segment porteur de texte mais sans aucune parole
  détectée est le signe le plus solide d'une invention de Whisper, parce que
  deux modèles indépendants s'y contredisent ;
- **taux de chevauchement** — part du segment où au moins deux personnes
  parlent en même temps.

Ces deux dernières distinctions comptent, car elles n'appellent pas le même
remède. Un segment à cheval se répare en le coupant ; deux voix superposées
ne se réparent pas du tout dans un enregistrement mono, et la réponse est à
la prise de son.

`pipeline/diagnostic_attribution.py` relit un transcript déjà produit et en
donne la distribution, sans refaire aucun calcul :

```bash
cd ~/transcription_pipeline
venv/bin/python3 diagnostic_attribution.py ~/chemin/sortie_reunion
```

Il sépare ce qui relève de l'attribution des locuteurs de ce qui relève de
la transcription, et liste les segments les moins nets avec leur
horodatage — confondre les deux familles fait chercher du côté de la
diarisation ce qui vient de Whisper, et réciproquement.

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

Depuis la version 1.1, **le contexte et les catégories du résumé sont
écrits en fichiers texte dans le dossier de la session** —
`<nom>_contexte.txt` et `<nom>_categories.txt` — et relus à son ouverture.
Ils décrivent cette réunion-là, ses participants, ses sigles, les rubriques
qu'on veut en tirer : les garder dans les préférences de l'application
faisait qu'ouvrir une autre session montrait le contexte de la précédente,
et qu'un dossier de résultats transmis à quelqu'un d'autre arrivait sans ce
qui permet de le relire. En fichiers texte, ils voyagent avec le dossier et
s'éditent sans l'application.

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
  fichiers. Volontairement basse : elle n'affiche qu'une ligne.
- **Lecteur de vérification** — apparaît dès qu'un fichier est chargé :
  lecture, pause, barre de progression, temps écoulé, et surtout une ligne
  de caractéristiques lue dans le fichier — « WAV · 48 kHz · stéréo ·
  1 h 47 ». C'est elle qui attrape les erreurs que l'oreille ne relève pas
  tout de suite : le mauvais fichier, un enregistrement tronqué, ou un
  fichier de secours échantillonné sous 16 kHz qui dégraderait toute la
  transcription sans qu'on comprenne pourquoi en la relisant. Ces deux
  derniers cas déclenchent un avertissement orange.

  *Pas de forme d'onde* : sur de la parole continue à niveau constant, elle
  ne montrerait qu'un aplat uniforme. La structure de l'enregistrement se
  lit bien mieux dans la fenêtre de vérification, qui en donne le découpage
  par locuteurs.
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
- **Bouton « Interrompre »** (rouge, `⌘.`) — n'apparaît que pendant un
  traitement et l'arrête sans quitter l'application. Le bandeau distingue
  alors une interruption d'un échec : ce qui était déjà transcrit est
  conservé, et une relance sur le même fichier reprend à la diarisation. Un
  bouton équivalent existe pour la génération du résumé.
- **Barre de progression** — indique l'étape en cours (1/3 Transcription,
  2/3 Diarisation, 3/3 Fusion) avec un pourcentage pour les deux premières.
  L'étape 2 précise en outre la phase interne de pyannote en cours
  (segmentation de la parole, empreintes vocales, comptage des locuteurs,
  assemblage). Seule l'étape 3, très brève, reste sans pourcentage.
- **Journal** — sortie texte détaillée du traitement en cours, copiable via
  le bouton « Copier le journal ». Replié par défaut dans un onglet, comme
  Contexte et Catégories ; refermé, son en-tête affiche la dernière ligne
  produite, pour qu'il ne laisse jamais croire que rien ne se passe.

Toute la page défile verticalement, avec un ascenseur visible en
permanence : avec les trois onglets dépliés, le contenu dépasse la hauteur
de la fenêtre, et il doit rester possible d'atteindre le bas — journal et
bandeau de fin compris.
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

**Reprise automatique au lancement** — le fichier choisi, le contexte, le
nombre de locuteurs et les catégories du résumé sont enregistrés en continu
et restaurés au démarrage suivant : plus rien à ressaisir après avoir quitté
l'application. Si un traitement avait été interrompu en cours de route, un
bandeau bleu le signale au lieu de laisser croire qu'il s'est terminé.

En haut à droite du titre figurent les signatures institutionnelles du
projet : ENSCi-Les Ateliers, Centre de Recherche en Design (ENSCI-Les
Ateliers / ENS Paris-Saclay), École normale supérieure Paris-Saclay, et
Comprehensive Sepsis Center. Chaque logo a sa hauteur propre, calibrée à
l'œil et non géométriquement : à hauteur égale, les blocs typographiques
deviendraient des textures illisibles.

Barre d'outils (en haut à droite de la fenêtre), trois boutons portant leur
nom à côté de leur icône — **Lots**, **Ouvrir**, **Réglages**. Les trois
mêmes actions figurent aussi dans le menu **Traitement**, avec leurs
raccourcis (`⇧⌘L`, `⌘O`, `⌘,`) : une icône se devine, un menu se lit.

- **Lots** — ouvre la fenêtre de traitement par lots
  ([4.4](#44-fenêtre-traitement-par-lots)).
- **Ouvrir** — ouvre une session déjà traitée sans refaire la
  transcription. Trois gestes fonctionnent indifféremment : désigner le
  dossier `sortie_…`, désigner n'importe quel fichier qu'il contient, ou
  désigner l'enregistrement d'origine. L'application remonte la session
  complète — audio, contexte, dossier de sortie — et récapitule dans le
  journal ce qu'elle a trouvé : nombre de segments, nombre de locuteurs,
  audio retrouvé, fichiers présents dans le dossier.

  L'enregistrement est cherché dans le dossier de sortie lui-même, puis à
  côté, puis dans le dossier des enregistrements configuré. À défaut, l'app
  se rabat sur l'audio de relecture `<nom>_review_audio.wav` conservé dans
  le dossier : une session transmise par un collègue reste donc corrigeable
  sans l'enregistrement d'origine.
- **Réglages** — ouvre les Réglages.

### 4.2 Fenêtre Réglages

Accessible à tout moment via `⌘,`, le bouton **Réglages** ou le menu
*Traitement*. La fenêtre est redimensionnable horizontalement et s'ouvre
assez large pour que les chemins se lisent en entier : c'est leur
illisibilité qui permettait de confondre deux réglages voisins et de coller
un dossier de sortie à la place du dossier du pipeline.

**Chaque chemin porte son verdict**, recalculé à la frappe. Le dossier du
pipeline n'est vert que si `transcribe_diarize.py` **et** `summarize.py` s'y
trouvent réellement, et nomme sinon celui qui manque. L'interpréteur Python
distingue l'absence, le dossier pris pour le fichier, et le fichier non
exécutable. Les dossiers de travail laissés vides ne disent rien — c'est un
réglage légitime, pas une anomalie.

Et avant tout lancement, l'application vérifie que l'installation existe :
plutôt que de laisser passer un « No such file or directory » de Python, le
journal nomme le champ des Réglages à corriger.

Voir
[« Configuration au premier lancement »](#configuration-au-premier-lancement)
pour le détail des champs techniques (dossier du pipeline, interpréteur
Python, token Hugging Face).

Deux réglages de dossiers, dans la section **Dossiers de travail** — à ne
pas confondre avec la section **Pipeline Python (installation)**, qui
désigne l'emplacement du logiciel et non celui des données :

- **Dossier des enregistrements** — emplacement où s'ouvrent par défaut les
  sélecteurs de fichiers et de dossiers. Purement pratique : il évite de
  renaviguer à chaque fois vers le même endroit.
- **Dossier de sauvegarde** — où écrire les transcriptions. Laissé vide, le
  comportement historique s'applique : chaque sortie reste dans un
  sous-dossier `sortie_…` à côté de son fichier audio. Renseigné, toutes les
  sorties sont regroupées sous ce dossier.

Une combinaison utile si vous travaillez avec un nuage : gardez les
**enregistrements en local** — c'est la matière la plus lourde et la plus
sensible, et les fichiers « à la demande » se téléchargent mal au moment où
ffmpeg en a besoin — et placez le **dossier de sauvegarde dans le nuage**,
puisque les transcriptions sont de petits fichiers texte et que c'est ce
qu'on partage. Rappel : ce que vous déposez sur OneDrive, Google Drive ou
iCloud quitte votre machine, ce qui contredit le principe de fonctionnement
local — à arbitrer selon la confidentialité de vos enregistrements.

### 4.3 Fenêtre Vérification / correction

> 📷 *Capture d'écran à ajouter : éditeur de vérification*

Ouverte depuis la fenêtre principale ou depuis la file de traitement par
lots, une fois qu'un transcript existe. Elle affiche le texte transcrit
segment par segment, en regard de l'audio original.

La fenêtre se recharge intégralement quand on y ouvre une autre session :
segments, locuteurs, lecteur audio et historique d'annulation repartent à
zéro. (Dans les versions précédentes, la fenêtre étant réutilisée par macOS,
le titre affichait le nouveau fichier pendant que le contenu restait celui
du précédent.)

**Lecteur audio** (en haut de la fenêtre) : une barre de défilement commune
à toute la fenêtre, avec boutons lecture / pause / stop et affichage du
temps écoulé. Le bouton de chaque segment fonctionne en bascule : il
positionne la lecture au début du segment et démarre, puis arrête si on le
reclique pendant que ce segment joue — son icône passe de ▶ à ⏹.

**Lire au curseur (`⌘⏎`)** : reprend la lecture à l'endroit exact où se
trouve le curseur dans le texte d'un segment. C'est la commande qui rend
praticable la correction d'un gros bloc : on clique dans la phrase
douteuse, on réécoute juste ce passage. Le raccourci fonctionne pendant la
frappe.

**Barre d'espace** : même bascule lecture/pause, mais **hors** d'une zone de
texte — dans une zone de texte, elle doit taper une espace, sinon on ne peut
plus écrire. Cliquez dans le fond de la liste et elle répond.

**Suivi de la lecture dans le texte** : le mot en cours est surligné dans le
cartouche du segment qui joue. La correspondance entre un instant du son et
une position dans le texte est **proportionnelle à la longueur du texte** :
elle suppose un débit régulier, ce qui est faux dans le détail, mais permet
de retomber à quelques secondes près dans un bloc de deux cents mots. Le mot
entier est surligné plutôt que le caractère calculé, pour ne pas donner une
fausse impression de précision.

À la première ouverture d'une session, l'application prépare pendant
quelques secondes un fichier `<nom>_review_audio.wav` : une copie normalisée
en 16 kHz mono, identique à celle sur laquelle les horodatages ont été
calculés. Sans elle, le son et le texte se décalent progressivement sur un
long enregistrement. Ce fichier est mis en cache, l'attente ne se reproduit
pas.

**En-tête des locuteurs** : un champ par locuteur détecté (`SPEAKER_00`,
`SPEAKER_01`, …), avec le nombre d'interventions, le temps de parole total,
et un aperçu du premier propos — permet de reconnaître rapidement qui est
qui et de saisir son vrai nom. Ce renommage s'applique à tous les segments
de ce locuteur à la fois.

**Liste des segments**, un par un :

- horodatage début/fin, éditable directement (format `hh:mm:ss`) ;
- menu déroulant pour réattribuer le segment à un autre locuteur (utile
  quand la diarisation automatique s'est trompée) ;
- **indice de confiance en pourcentage**, dans l'en-tête du cartouche, dans
  la teinte correspondante — voir l'encadré ci-dessous ;
- **pastille orange d'attribution partagée**, cliquable, du type
  « 53 % · ou Dominique ? », quand la parole du segment se partage entre
  deux locuteurs. Un clic réattribue le segment à l'autre candidat, et
  l'annulation fonctionne dessus. L'icône distingue les deux situations :
  deux silhouettes quand les locuteurs se succèdent — la coupure est au
  mauvais endroit, réattribuer ou diviser règle l'affaire — et une forme
  d'onde barrée quand ils parlent réellement en même temps, auquel cas c'est
  le texte lui-même qui est douteux et aucun clic n'y changera rien ;
- icône ⚠️ **suivie de sa raison en clair** si le segment est signalé. La
  raison vient du pipeline quand elle existe — « la diarisation ne trouve
  aucune parole sur ce passage » croise deux modèles indépendants, ce
  qu'aucune heuristique interne à l'application ne pourrait faire — et des
  heuristiques locales pour les transcripts plus anciens : confiance faible,
  silence probable, mot répété, segment anormalement long ou court.

  **Ces indicateurs disparaissent dès que vous corrigez le segment.** Un
  segment dont vous venez de rectifier le locuteur ou le texte n'est plus
  décrit par des mesures calculées avant votre correction : les laisser
  ferait réapparaître l'alerte sur un segment devenu juste ;
- texte éditable, sur fond coloré selon la confiance, **dimensionné à la
  hauteur de son contenu** : un segment long s'affiche en entier, sans
  défilement interne ;
- bouton ✂️ **toujours actif** pour diviser le segment — voir ci-dessous ;
- bouton 🗑️ pour supprimer un segment erroné, bouton « + Ajouter un
  segment » (en haut) pour en créer un manuellement au point de lecture
  actuel.

**Diviser un segment où deux personnes parlent à la suite.** Trois gestes,
au choix, et les ciseaux ✂️ restent toujours cliquables :

- **au tiret de dialogue** — passez à la ligne au changement de locuteur et
  commencez par un tiret, comme dans un texte dialogué. Trait d'union, tiret
  demi-cadratin et cadratin sont acceptés, le tiret peut être indenté. Il
  doit être suivi d'une espace, faute de quoi une ligne commençant par
  « -5 % » serait coupée en deux ;
- **au marqueur `|`** — tapé directement à l'endroit du changement ;
- **à la position du curseur** — si le texte ne contient ni tiret ni
  marqueur, les ciseaux coupent simplement là où vous avez cliqué.

Dans les trois cas, la durée est répartie entre les morceaux au prorata de
la longueur de leur texte, et les horodatages restent modifiables ensuite.
L'infobulle des ciseaux change selon ce que le bouton va réellement faire.

**Ce que signifie le pourcentage de confiance.** C'est l'exponentielle de
l'`avg_logprob` de Whisper, c'est-à-dire la probabilité moyenne que le
modèle a attribuée à chacun de ses propres mots. Les seuils de couleur
correspondent à 74 % (vert) et 45 % (orange). **Ce n'est pas un taux
d'exactitude** : un contresens parfaitement formulé sort avec une confiance
élevée. Sa valeur est comparative — elle classe les segments par ordre de
suspicion et vous dit par où commencer une relecture. Les segments ajoutés à
la main affichent « — », n'ayant aucune confiance du modèle à rapporter.

**Annuler** (`⌘Z`) : rétablit l'état précédent après une suppression, un
ajout, une division ou une fusion de locuteurs, sur trente niveaux.
L'enregistrement écrasant le transcript sur place, une suppression par
mégarde était auparavant définitive — et l'interface bouge sous le curseur
au fil de la lecture, ce qui rend le clic malheureux fréquent.

Bouton **« Enregistrer »** (`⌘S`) : réécrit le fichier transcript et
régénère le fichier texte final utilisé ensuite par le résumé. Le bouton est
**rouge tant que des corrections ne sont pas écrites sur le disque**, gris
avec une coche une fois enregistré. Il se fonde sur une empreinte du contenu
et non sur un simple drapeau : annuler jusqu'à revenir exactement à l'état
enregistré le fait repasser au gris.

Bouton **« Exporter CSV »** : écrit un tableau à côté du transcript, prêt
pour le codage — voir [section 6](#6-exporter-vers-un-tableur).

### 4.4 Fenêtre Traitement par lots

> 📷 *Capture d'écran à ajouter : fenêtre de traitement par lots*

Permet de traiter tout un dossier d'enregistrements automatiquement, à la
suite, sans intervention (adapté à un traitement de nuit).

**Choisir un dossier…** — scanne le dossier sélectionné (uniquement les
fichiers à sa racine, pas les sous-dossiers) et construit la liste des
fichiers audio à traiter.

**Ajouter des fichiers…** — ajoute un ou plusieurs enregistrements choisis
un par un, sans rescanner tout un dossier. Utile pour compléter une file
déjà constituée, ou pour composer un lot à partir de fichiers dispersés. Le
contexte et le nombre de locuteurs sont résolus pour chaque fichier ajouté
selon les mêmes règles que le scan, à partir du dossier où il se trouve. Les
fichiers déjà présents dans la file sont ignorés silencieusement.

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
résumé structuré » lance une analyse locale via Ollama. Le modèle par défaut
est `mistral-small3.2:24b` : un modèle de 24 milliards de paramètres lit le
français avec beaucoup plus de finesse qu'un 7B, et c'est le premier facteur
de qualité. `--model mistral` revient à un modèle plus léger si la mémoire
manque.

### Trois passes, et pourquoi

**1. Relevé de notes.** La première passe ne rédige pas, elle relève : une
liste de notes typées — position défendue, désaccord, question restée
ouverte, décision, action, terme ambigu, moment de bascule — chacune avec
son horodatage et le ou les locuteurs concernés. Un modèle de cette taille
s'en sort bien mieux à relever qu'à résumer, et la passe suivante a dès lors
des prises pour ranger plutôt que de reparaphraser un texte déjà appauvri.

L'attribution est demandée explicitement : « Untel soutient que », « Untel
objecte que », jamais un « les participants » collectif — c'est ce qui
faisait disparaître la substance d'une table ronde. Un nom de locuteur qui
n'apparaît pas réellement dans la tranche est écarté.

**2. Rangement avec citations vérifiées.** La seconde passe range les notes
dans les catégories, et **cite pour chaque item les identifiants des notes
dont il découle**. Ces citations sont résolues par le programme, pas par le
modèle : un item qui ne cite rien, ou qui cite un identifiant inexistant,
part dans une section « À vérifier — points sans source identifiable » au
lieu d'être affirmé. Un modèle qui invente cite mal, et cela se détecte sans
un seul appel supplémentaire. Les horodatages et les noms de locuteurs des
items sont déduits des notes citées : eux non plus ne peuvent pas être
inventés.

**3. Synthèse d'ouverture.** Le document s'ouvre sur une section « En bref »
de deux à dix lignes, en prose continue, sans horodatage — pour qui veut
savoir en trente secondes ce qui s'est joué. Elle est rédigée **à partir du
compte rendu retenu**, et non des notes brutes : ce qui a été écarté faute
de source ne peut donc pas revenir par la porte de derrière. `--sans-synthese`
la supprime si seul le corps vous intéresse.

### Les grilles de lecture

La grille par défaut est **analytique** : elle demande ce qui ne se lit pas
directement dans le transcript.

- Positions défendues, et par qui
- Désaccords et tensions non résolus
- Questions restées sans réponse
- Décisions prises
- Actions à mener
- Difficultés mises en avant
- Propositions de développement
- Implications techniques et financières
- Termes employés dans des sens différents selon les participants
- Moments où la discussion change de nature

La grille **descriptive** reprend les huit catégories factuelles d'origine
(état de la recherche, questions posées, réponses apportées, etc.) :
`--grille descriptive`. Et la zone dépliable « Catégories du résumé » de
l'application reste prioritaire sur les deux, une catégorie par ligne.

La profondeur que l'ancienne version ne donnait pas n'était pas une affaire
de modèle : l'ancienne grille ne la demandait pas.

### Réserves et traçabilité

Un item qui s'appuie sur un passage que le pipeline a signalé — parole
superposée, segment douteux — porte un avertissement dans le document.
L'incertitude de la transcription remonte ainsi jusqu'au résumé au lieu de
se perdre en chemin.

Chaque point porte l'horodatage des passages dont il découle : ouvrez la
session dans l'application et écoutez-les pour vérifier, corriger ou
préciser. C'est ce qui permet de contrôler une affirmation en dix secondes
au lieu de rouvrir tout l'enregistrement.

Deux fichiers sont générés dans le dossier de sortie : un `.md` (Markdown,
lisible directement, ouvert via le bouton « Ouvrir le résumé ») et un
`.json`, qui contient en plus la synthèse, toutes les notes relevées et les
citations de chaque item — de quoi reconstruire le raisonnement ou croiser
plusieurs enregistrements avec un outil externe.

La console rend compte de l'attente au fil de l'eau : avec un modèle de
cette taille, une tranche prend plusieurs minutes, et un affichage muet
laisserait croire à un blocage.

## 6. Exporter vers un tableur

Le codage et l'annotation se font dans un tableur, pas dans un transcript.
L'export CSV fait le pont : une ligne par segment, avec de quoi trier,
filtrer, calculer des temps de parole et ajouter ses propres colonnes.

Deux façons d'obtenir le fichier. Depuis l'application, le bouton
**« Exporter CSV »** de la fenêtre de vérification écrit le tableau à côté
du transcript, en tenant compte des noms de locuteurs que vous avez saisis.
En ligne de commande, `pipeline/transcript_to_csv.py` fait la même chose et
sait traiter tout un corpus d'un coup :

```bash
cd ~/transcription_pipeline && source venv/bin/activate
python3 transcript_to_csv.py --transcript sortie_reunion/reunion_transcript.json
python3 transcript_to_csv.py --dossier ~/Enregistrements
```

La seconde forme parcourt les sous-dossiers et convertit tous les
transcripts trouvés, en ignorant les caches `_whisper_raw`.

**Colonnes produites** : `n` (numéro d'ordre), `locuteur`, `debut` et `fin`
au format `hh:mm:ss`, `debut_s` et `fin_s` en secondes pour trier et
calculer, `duree_s`, `mots` (utile pour pondérer un temps de parole),
`texte`, puis `code_1`, `code_2` et `code_3` laissées vides pour annoter
directement sans avoir à insérer des colonnes.

**Encodage** : par défaut point-virgule et UTF-8 avec BOM, faute de quoi
Excel en français met toute la ligne dans une seule colonne et abîme les
accents. Pour Numbers, LibreOffice ou une relecture par script, l'option
`--style international` donne une virgule et de l'UTF-8 sans BOM.

Un point-virgule, un guillemet ou un retour à la ligne présents dans le
texte transcrit sont correctement protégés : ils ne décalent pas les
colonnes. Le fichier `pipeline/test_transcript_to_csv.py` vérifie ces cas,
parmi 24 contrôles, et peut être relancé à tout moment.

## 7. Limitations connues

- **La parole simultanée ne se sépare pas.** Quand deux personnes parlent en
  même temps dans un enregistrement mono, aucun traitement ne démêle les
  voix, et le texte produit sur ces passages est au mieux approximatif.
  L'application les signale plutôt que de prétendre le contraire. La réponse
  n'est pas logicielle : un micro par participant sur un enregistreur
  multipiste rend la diarisation triviale, puisque le locuteur est alors
  connu par construction.
- **Pas d'horodatage mot à mot.** Ce serait la bonne façon de couper un
  segment au mot près et de suivre la lecture exactement. Mesuré sur cette
  machine, il multiplie par vingt le temps de transcription — vingt minutes
  pour dix minutes d'audio, contre cinquante-sept secondes. Écarté pour
  cette raison. La correspondance entre une position dans le texte et un
  instant du son reste donc proportionnelle, et approximative de quelques
  secondes.
- **Le modèle `large-v3` est hors d'usage à ce volume.** Plus précis que
  `large-v3-turbo` sur l'audio difficile, mais vingt fois plus lent sur
  cette machine : soixante heures de calcul pour trente heures
  d'enregistrement. L'option reste disponible pour un extrait court.
- **« Aucune parole détectée » ne distingue pas deux cas.** Un segment
  porteur de texte là où pyannote n'entend personne peut être une invention
  de Whisper sur du bruit, ou une courte réplique réelle que la diarisation
  a manquée. Les deux produisent exactement le même signal, et seule une
  écoute tranche. L'application pointe l'endroit, elle ne décide pas.
- **Pas de `.dmg` packagé ni de signature par un compte développeur Apple
  payant** — l'installation automatique ([2.0](#20-installation-automatique-recommandé))
  compile depuis le code source avec une signature ad-hoc (usage local),
  d'où l'avertissement Gatekeeper au premier lancement. Pas de double-clic
  sur un `.dmg` téléchargé : `TranscriptionTableRonde_install.sh` reste une
  commande à lancer dans le Terminal, une fois par machine.
- **Fermeture de l'application pendant un traitement** — quitter
  l'application ne termine pas toujours proprement le processus Python en
  cours ; en cas de doute, vérifier via le Moniteur d'activité qu'aucun
  processus `python` résiduel ne tourne avant de relancer un traitement sur
  le même fichier.
- **Traitement par lots : dossier racine uniquement** — les sous-dossiers ne
  sont pas parcourus automatiquement dans cette version. Le bouton
  « Ajouter des fichiers… » permet de contourner ponctuellement cette
  limite.
- **Noms de locuteurs écrits en dur à l'enregistrement** — quand vous
  enregistrez depuis la fenêtre de vérification, les noms saisis remplacent
  les identifiants `SPEAKER_xx` dans le transcript. Le renommage n'est donc
  pas réversible, et la correspondance n'est pas conservée séparément. Le
  fichier `_speakers.json` produit par le pipeline n'est pas encore relu par
  l'application.
- **L'avancement des corrections ne se partage pas encore** — l'état de la
  session est mémorisé par machine et par compte, pas dans le dossier de
  sortie. Copier ou synchroniser un dossier `sortie_…` transmet les
  transcripts, les corrections déjà enregistrées, le contexte et les
  catégories, mais pas l'état de travail. Un correcteur qui reprend le
  dossier repart donc de ce qui a été écrit sur disque.
- **Le journal défile dans une page qui défile** — quand le pointeur est
  au-dessus du journal, la molette fait défiler le journal ; il faut la
  déplacer sur le reste de la page pour faire défiler la fenêtre.
- **Pas de mise à jour automatique** — toute nouvelle version doit être
  réinstallée manuellement : `git pull` (ou nouveau téléchargement du zip)
  puis relancer `TranscriptionTableRonde_install.sh`, qui écrase l'ancienne
  app dans `~/Applications` et met à jour le pipeline en place.

## 8. Glossaire

- **Transcription** — conversion de l'audio en texte.
- **Diarisation** — détection de « qui parle quand », sans identification
  des noms (locuteurs anonymes `SPEAKER_00`, etc.).
- **Token Hugging Face** — identifiant personnel gratuit permettant de
  télécharger les modèles de diarisation pyannote.
- **Contexte** — texte libre décrivant le sujet/les participants d'un
  enregistrement, utilisé pour améliorer la reconnaissance et le résumé.
- **Résumé structuré** — synthèse organisée par catégories, générée
  localement par un modèle de langage (via Ollama). Chaque point cite les
  passages dont il découle.
- **Netteté d'attribution** — part de la parole détectée dans un segment qui
  revient au locuteur retenu. Mesure l'ambiguïté, non la qualité du texte.
- **Chevauchement** — part d'un segment où au moins deux personnes parlent
  en même temps. Irréductible dans un enregistrement mono.
- **Hallucination** — texte plausible produit par Whisper là où il n'y a pas
  de parole. Détectable quand la diarisation, modèle indépendant, n'entend
  personne sur le même passage.
- **Boucle de répétition** — blocage de Whisper sur un mot ou une formule
  qu'il répète des dizaines de fois, généralement sur du silence ou du
  bruit. Repliée automatiquement, et l'original reste dans le cache.
