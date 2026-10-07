"""
Détection et nettoyage des défauts propres à Whisper, indépendamment de la
diarisation.

Trois défauts, de natures différentes, sont traités ici :

1. LES BOUCLES DE RÉPÉTITION. Whisper se bloque parfois sur un mot ou une
   courte formule qu'il répète des dizaines de fois — typiquement en fin de
   fichier, sur de la queue de silence ou du bruit. Le texte produit n'est
   pas une transcription incertaine, c'est un artefact : aucun locuteur n'a
   prononcé ce mot cent fois. On le replie donc, en gardant deux occurrences
   pour que la trace reste lisible, et on note combien ont été retirées.
   L'original n'est jamais perdu : il demeure dans le cache *_whisper_raw.json.

2. LES HALLUCINATIONS SUR DU NON-PARLÉ. Sur du bruit de fond, du brouhaha ou
   du silence, Whisper produit du texte plausible plutôt que rien. Ce texte
   est indétectable à la lecture — il est grammatical, il a l'air d'une
   phrase. Il est en revanche détectable par les indicateurs que Whisper
   fournit lui-même pour chaque segment et que personne ne regardait :
   `no_speech_prob` (sa propre estimation de l'absence de parole),
   `avg_logprob` (sa confiance) et `compression_ratio` (la répétitivité du
   texte). On ne supprime rien sur cette base — ce serait prendre le risque
   d'effacer de la vraie parole difficile — on signale.

3. LA PAROLE MANQUÉE DANS LE BROUHAHA. Celle-là n'est pas détectable ici :
   un mot audible que Whisper n'a pas écrit ne laisse aucune trace dans sa
   sortie. Seul un modèle plus solide ou une meilleure prise de son y peut
   quelque chose. Ce module ne prétend donc rien à son sujet.

Module volontairement sans dépendance : il ne manipule que des chaînes et
des dicts, et se teste sans Whisper. Voir test_qualite_transcription.py.
"""
from __future__ import annotations

import gzip
import re

# Un mot répété six fois d'affilée ne se dit pas. Quatre, si : « non non non
# non » existe dans une conversation animée, et l'effacer serait une
# falsification. Le seuil est haut exprès — mieux vaut laisser passer une
# boucle courte que mutiler de la parole réelle.
SEUIL_MOT = 6
# Pour une formule de plusieurs mots, la répétition littérale est bien plus
# rare dans la parole spontanée : quatre suffisent.
SEUIL_FORMULE = 4
LONGUEUR_FORMULE_MAX = 6

_ESPACES = re.compile(r"\s+")


def _mots(texte: str) -> list[str]:
    return [m for m in _ESPACES.split(texte.strip()) if m]


def _cle(mot: str) -> str:
    """Forme comparable d'un mot : la ponctuation et la casse ne doivent pas
    empêcher de reconnaître « oui, oui. Oui » comme une répétition.

    Limite connue : un signe de ponctuation isolé entre deux espaces donne
    une clé vide et interrompt la suite. Une boucle ainsi coupée en deux
    moitiés trop courtes échappe au repliage — elle reste repérée par le
    taux de compression et le segment est signalé, simplement pas nettoyé.
    """
    return re.sub(r"[^\w]", "", mot, flags=re.UNICODE).lower()


def replier_repetitions(texte: str, seuil_mot: int = SEUIL_MOT,
                        seuil_formule: int = SEUIL_FORMULE) -> tuple[str, int]:
    """Replie les répétitions consécutives. Retourne (texte, nombre retiré).

    Les formules de plusieurs mots sont traitées avant les mots isolés : une
    boucle sur « je ne sais pas » est une seule répétition de quatre mots, et
    non quatre boucles de mots sans rapport.
    """
    mots = _mots(texte)
    if not mots:
        return texte, 0

    # Les mots isolés d'abord, les formules ensuite. L'ordre inverse semblait
    # plus naturel — traiter le motif le plus long en premier — mais il est
    # faux : une suite de quarante fois le même mot est vue par la passe des
    # groupes de six comme six groupes identiques, repliés en deux, puis le
    # reste est repris par la passe des groupes de cinq, et ainsi de suite.
    # Le repliage se fait alors en cascade et laisse systématiquement des
    # résidus. Un mot répété est l'affaire de la règle du mot.
    retires = 0
    mots, n = _replier_a_longueur(mots, 1, seuil_mot)
    retires += n
    for longueur in range(LONGUEUR_FORMULE_MAX, 1, -1):
        mots, n = _replier_a_longueur(mots, longueur, seuil_formule)
        retires += n

    return " ".join(mots), retires


def _replier_a_longueur(mots: list[str], longueur: int, seuil: int) -> tuple[list[str], int]:
    """Replie les suites d'au moins `seuil` groupes identiques de `longueur`
    mots, en n'en gardant que deux."""
    if len(mots) < longueur * seuil:
        return mots, 0

    cles = [_cle(m) for m in mots]
    sortie: list[str] = []
    retires = 0
    i = 0
    while i < len(mots):
        motif = cles[i:i + longueur]
        if len(motif) < longueur or not any(motif):
            sortie.append(mots[i])
            i += 1
            continue

        repetitions = 1
        j = i + longueur
        while cles[j:j + longueur] == motif:
            repetitions += 1
            j += longueur

        if repetitions >= seuil:
            # deux occurrences conservées : assez pour que la relecture voie
            # ce qui s'est passé, assez peu pour que ça ne noie pas le texte
            sortie.extend(mots[i:i + longueur * 2])
            retires += (repetitions - 2) * longueur
            i = j
        else:
            sortie.append(mots[i])
            i += 1

    return sortie, retires


def taux_compression(texte: str) -> float:
    """Rapport de compression gzip du texte. C'est l'indicateur que Whisper
    utilise lui-même pour repérer ses propres sorties dégénérées : un texte
    très répétitif se comprime beaucoup mieux qu'une phrase ordinaire."""
    brut = texte.encode("utf-8")
    if not brut:
        return 0.0
    return len(brut) / max(1, len(gzip.compress(brut)))


# Causes de suspicion, sous une forme stable. Le texte lisible contient des
# chiffres qui varient d'un segment à l'autre : s'en servir pour regrouper
# obligerait à le redécouper après coup, et la moindre reformulation casserait
# le regroupement. Un code d'un côté, une phrase de l'autre.
CAUSES = {
    "sans_parole": "aucune parole détectée par la diarisation, mais du texte écrit",
    "non_parle": "Whisper ne détecte pas de parole, mais écrit du texte",
    "confiance_basse": "confiance très basse sur l'ensemble du segment",
    "repetitif": "texte anormalement répétitif",
    "boucle_repliee": "boucle de répétition repliée",
}


def diagnostiquer(segment: dict, seuil_non_parle: float = 0.6,
                  seuil_confiance: float = -1.0,
                  seuil_compression: float = 2.4) -> tuple[bool, str, list[str]]:
    """Dit si un segment a toutes les apparences d'une hallucination.

    Retourne (suspect, raison lisible, codes de cause). La raison est écrite
    pour être lue dans la fenêtre de vérification ; les codes servent aux
    regroupements statistiques.

    Aucun segment n'est supprimé sur cette base : un passage réellement
    difficile à entendre produit les mêmes indicateurs qu'une invention, et
    c'est à l'oreille de trancher. Le but est de dire où écouter.
    """
    texte = (segment.get("text") or "").strip()
    non_parle = segment.get("no_speech_prob")
    confiance = segment.get("avg_logprob")
    compression = segment.get("compression_ratio")
    if compression is None and texte:
        compression = taux_compression(texte)

    raisons: list[str] = []
    codes: list[str] = []
    # Le signal le plus fort, parce qu'il vient d'un autre modèle que celui
    # qui a écrit le texte : pyannote n'a trouvé aucune parole sur cet
    # intervalle, et Whisper y a pourtant mis des mots. Deux systèmes
    # indépendants en désaccord, c'est plus solide qu'un seul qui doute.
    if segment.get("speech_share") == 0 and texte:
        raisons.append("la diarisation ne trouve aucune parole sur ce passage")
        codes.append("sans_parole")
    # Whisper estime lui-même qu'il n'y a pas de parole, et pourtant il a
    # écrit quelque chose : c'est le cas d'école de l'hallucination.
    if non_parle is not None and non_parle > seuil_non_parle and texte:
        raisons.append(f"Whisper estime à {100 * non_parle:.0f}% qu'il n'y a pas de parole ici")
        codes.append("non_parle")
    if confiance is not None and confiance < seuil_confiance:
        raisons.append(CAUSES["confiance_basse"])
        codes.append("confiance_basse")
    if compression is not None and compression > seuil_compression:
        raisons.append(CAUSES["repetitif"])
        codes.append("repetitif")
    if segment.get("repeats_removed"):
        raisons.append(f"{segment['repeats_removed']} mots répétés en boucle ont été repliés")
        codes.append("boucle_repliee")

    return bool(raisons), " ; ".join(raisons), codes


def nettoyer_segments(segments: list[dict], **seuils) -> dict:
    """Replie les boucles et marque les segments suspects, sur place.

    Retourne un petit bilan, destiné au journal de l'application : ce genre
    de nettoyage doit se voir, sinon personne ne sait qu'il a eu lieu.
    """
    bilan = {"segments_replies": 0, "mots_retires": 0, "segments_suspects": 0}
    seuil_compression = seuils.get("seuil_compression", 2.4)
    for segment in segments:
        texte = segment.get("text") or ""
        seuil_mot = seuils.get("seuil_mot", SEUIL_MOT)
        seuil_formule = seuils.get("seuil_formule", SEUIL_FORMULE)
        # Quand Whisper signale lui-même, par son taux de compression, que sa
        # sortie a dégénéré, on resserre les seuils. Ailleurs ils restent
        # hauts : c'est le seul moyen de replier « C'est bon. C'est bon. C'est
        # bon. Oui. Oui. Oui. Oui. » sans risquer d'amputer une insistance
        # réelle dans un segment par ailleurs sain.
        compression = segment.get("compression_ratio")
        if compression is not None and compression > seuil_compression:
            seuil_mot = min(seuil_mot, 3)
            seuil_formule = min(seuil_formule, 2)
        replie, retires = replier_repetitions(texte, seuil_mot, seuil_formule)
        if retires:
            segment["text"] = replie
            segment["repeats_removed"] = retires
            bilan["segments_replies"] += 1
            bilan["mots_retires"] += retires

        suspect, raison, codes = diagnostiquer(
            segment,
            seuils.get("seuil_non_parle", 0.6),
            seuils.get("seuil_confiance", -1.0),
            seuil_compression,
        )
        if suspect:
            segment["suspect"] = True
            segment["suspect_reason"] = raison
            segment["suspect_causes"] = codes
            bilan["segments_suspects"] += 1
    return bilan
