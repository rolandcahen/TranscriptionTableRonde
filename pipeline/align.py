"""
Fonctions d'alignement entre les segments de transcription (Whisper) et les
tours de parole détectés par la diarisation (pyannote).

Ce module est volontairement indépendant de mlx-whisper et pyannote : il ne
manipule que des structures Python simples (listes de dicts / tuples), ce
qui permet de le tester sans installer ces deux librairies.
Voir test_align.py.

Au-delà de l'attribution d'un locuteur à chaque segment, ce module mesure
la FIABILITÉ de cette attribution. C'est une addition importante : Whisper
découpe selon la prosodie et la ponctuation, sans rien savoir des tours de
parole, si bien qu'un segment peut parfaitement enjamber un changement de
locuteur. Jusqu'ici, un tel segment était attribué en silence au locuteur
qui occupait le plus de secondes, et la moitié mal attribuée disparaissait
sans laisser de trace. Les tours de parole simultanés subissaient le même
sort : pyannote les signale, et l'alignement les écrasait.

On ne cherche pas à séparer deux voix superposées — c'est hors de portée
sans séparation de sources. On cherche à savoir OÙ se taire : chaque
segment emporte désormais la part du locuteur retenu, le nom du second, et
la part du segment où deux personnes parlent en même temps. La fenêtre de
vérification n'a plus qu'à mettre ces passages en évidence, pour qu'ils
soient écoutés plutôt que relus au hasard.

Deux granularités d'attribution coexistent, selon que la transcription
porte ou non l'horodatage de chaque mot (`par_mot=True`) :

    au segment  le locuteur majoritaire sur tout le segment. Rapide, mais
                un segment à cheval sur un changement de locuteur part
                entièrement du mauvais côté.
    au mot      chaque mot reçoit son locuteur, puis les mots consécutifs
                du même locuteur sont regroupés. Le segment se coupe alors
                exactement là où la parole change de mains. C'est la seule
                façon de réparer les segments à cheval, et non plus
                seulement de les signaler.

Clés ajoutées à chaque segment :
    speaker            locuteur retenu (inchangé)
    speaker_share      part de la PAROLE DÉTECTÉE dans le segment qui revient
                       à ce locuteur (1.0 = il est seul à parler ici)
    speaker_alt        second locuteur présent dans le segment, ou None
    speaker_alt_share  sa part de la parole détectée
    overlap_share      part de la parole détectée où au moins deux locuteurs
                       parlent simultanément
    speech_share       part de la DURÉE DU SEGMENT où de la parole est
                       détectée (le reste est du silence ou du bruit)

La distinction entre les deux dénominateurs n'est pas un détail, c'est la
leçon d'une erreur : rapporter la part du locuteur à la durée du segment
mélange deux questions sans rapport. Whisper taille large et englobe les
pauses, si bien qu'un « D'accord. » d'une seconde isolé dans huit secondes de
segment ressortait à 12 % — comme s'il était douteux, alors que son
attribution est parfaitement certaine : personne d'autre ne parle.

Les deux questions sont donc posées séparément :
    speaker_share  « parmi ce qui est dit ici, quelle part est de lui ? »
                   C'est la mesure de l'ambiguïté d'attribution.
    speech_share   « y a-t-il seulement de la parole ici ? »
                   Un segment porteur de texte mais sans aucune parole
                   détectée est le signe le plus net d'une invention de
                   Whisper sur du silence ou du bruit.
"""
from __future__ import annotations

INCONNU = "INCONNU"


def _intervalles_par_locuteur(seg_start: float, seg_end: float, diarization_turns):
    """Tours de parole rognés aux bornes du segment, regroupés par locuteur.

    Les intervalles d'un même locuteur sont fusionnés : pyannote peut
    émettre plusieurs pistes pour une même personne, et les compter deux
    fois ferait croire à un chevauchement là où il n'y en a pas.
    """
    par_locuteur: dict[str, list[tuple[float, float]]] = {}
    for turn_start, turn_end, speaker in diarization_turns:
        debut = max(seg_start, turn_start)
        fin = min(seg_end, turn_end)
        if fin > debut:
            par_locuteur.setdefault(speaker, []).append((debut, fin))

    for speaker, intervalles in par_locuteur.items():
        intervalles.sort()
        fusionnes = [list(intervalles[0])]
        for debut, fin in intervalles[1:]:
            if debut <= fusionnes[-1][1]:
                fusionnes[-1][1] = max(fusionnes[-1][1], fin)
            else:
                fusionnes.append([debut, fin])
        par_locuteur[speaker] = [(d, f) for d, f in fusionnes]

    return par_locuteur


def _duree_simultanee(par_locuteur: dict[str, list[tuple[float, float]]]) -> float:
    """Durée pendant laquelle au moins deux locuteurs sont actifs.

    Balayage des bornes : entre deux bornes consécutives, le nombre de
    locuteurs actifs est constant, il suffit donc de le compter une fois au
    milieu de l'intervalle.
    """
    if len(par_locuteur) < 2:
        return 0.0
    bornes = sorted({b for intervalles in par_locuteur.values()
                     for intervalle in intervalles for b in intervalle})
    total = 0.0
    for debut, fin in zip(bornes, bornes[1:]):
        if fin <= debut:
            continue
        milieu = (debut + fin) / 2
        actifs = sum(
            1 for intervalles in par_locuteur.values()
            if any(d <= milieu < f for d, f in intervalles)
        )
        if actifs >= 2:
            total += fin - debut
    return total


def _duree_de_parole(par_locuteur: dict[str, list[tuple[float, float]]]) -> float:
    """Durée couverte par au moins un locuteur, chaque instant compté une fois.

    Ce n'est pas la somme des durées par locuteur : deux personnes parlant
    ensemble pendant deux secondes occupent deux secondes de l'enregistrement,
    pas quatre. Sans cette union, un passage très chevauché afficherait plus
    de parole que le segment ne dure.
    """
    intervalles = sorted(iv for ivs in par_locuteur.values() for iv in ivs)
    if not intervalles:
        return 0.0
    total = 0.0
    debut_courant, fin_courante = intervalles[0]
    for debut, fin in intervalles[1:]:
        if debut <= fin_courante:
            fin_courante = max(fin_courante, fin)
        else:
            total += fin_courante - debut_courant
            debut_courant, fin_courante = debut, fin
    return total + (fin_courante - debut_courant)


def _indices(seg_start: float, seg_end: float, diarization_turns):
    """Locuteur dominant d'un intervalle et indices de fiabilité associés.

    Retourne (locuteur, part, second, part_second, chevauchement, part_parlée).
    Sert aussi bien pour un segment entier que pour un mot isolé : c'est la
    même question posée à deux échelles.
    """
    duree = max(0.0, seg_end - seg_start)
    par_locuteur = _intervalles_par_locuteur(seg_start, seg_end, diarization_turns)
    durees = {
        speaker: sum(f - d for d, f in intervalles)
        for speaker, intervalles in par_locuteur.items()
    }
    if not durees:
        return INCONNU, 0.0, None, 0.0, 0.0, 0.0

    parole = _duree_de_parole(par_locuteur)
    classement = sorted(durees.items(), key=lambda kv: (-kv[1], kv[0]))
    speaker, duree_1 = classement[0]
    second, duree_2 = classement[1] if len(classement) > 1 else (None, 0.0)

    # Les parts d'attribution se rapportent à la parole détectée, pas à la
    # durée du segment : le silence autour d'une réplique ne rend pas cette
    # réplique douteuse.
    def part_parole(valeur: float) -> float:
        return round(min(1.0, valeur / parole), 4) if parole > 0 else 0.0

    part_parlee = round(min(1.0, parole / duree), 4) if duree > 0 else 1.0

    return (speaker, part_parole(duree_1), second, part_parole(duree_2),
            part_parole(_duree_simultanee(par_locuteur)), part_parlee)


def _mots_horodates(seg: dict):
    """Mots exploitables d'un segment, ou None si l'horodatage manque.

    Whisper n'attribue pas toujours un horodatage à chaque mot (ponctuation
    isolée, segment sans parole). Un mot sans bornes ne peut pas être
    attribué : plutôt que de le perdre ou de l'attribuer au hasard, on
    renonce au mode mot à mot pour ce segment-là et on retombe sur
    l'attribution au segment, qui elle ne dépend d'aucun horodatage fin.
    """
    mots = seg.get("words")
    if not isinstance(mots, list) or not mots:
        return None
    for mot in mots:
        if not isinstance(mot, dict):
            return None
        if mot.get("start") is None or mot.get("end") is None:
            return None
    return mots


def _texte_des_mots(mots) -> str:
    """Recolle les mots. mlx-whisper conserve l'espace initial dans chaque
    mot, d'où la concaténation brute plutôt qu'une jointure par espaces."""
    return "".join(str(mot.get("word", "")) for mot in mots).strip()


def _decouper_par_locuteur(seg: dict, mots, diarization_turns):
    """Découpe un segment en autant de morceaux que de locuteurs successifs.

    Les clés du segment d'origine autres que les bornes, le texte et les
    mots sont recopiées à l'identique dans chaque morceau — `avg_logprob`
    en particulier, dont la fenêtre de vérification tire son indice de
    confiance. C'est une moyenne de segment, donc la meilleure estimation
    disponible pour chacun de ses morceaux, à défaut d'être exacte.
    """
    attribues = [(mot, _indices(float(mot["start"]), float(mot["end"]), diarization_turns)[0])
                 for mot in mots]

    groupes: list[list] = []
    for mot, locuteur in attribues:
        if groupes and groupes[-1][0] == locuteur:
            groupes[-1][1].append(mot)
        else:
            groupes.append([locuteur, [mot]])

    commun = {k: v for k, v in seg.items() if k not in ("start", "end", "text", "words")}
    morceaux = []
    for locuteur, mots_du_groupe in groupes:
        debut = float(mots_du_groupe[0]["start"])
        fin = float(mots_du_groupe[-1]["end"])
        texte = _texte_des_mots(mots_du_groupe)
        if not texte:
            continue
        # Les indices sont recalculés sur les bornes réelles du morceau :
        # un morceau bien découpé doit pouvoir s'annoncer comme sûr, même
        # si le segment dont il est issu était, lui, à cheval.
        _, part, second, part_second, chevauchement, part_parlee = _indices(
            debut, fin, diarization_turns)
        morceau = dict(commun)
        morceau.update({
            "start": debut,
            "end": fin,
            "text": texte,
            "speaker": locuteur,
            "speaker_share": part,
            "speaker_alt": second,
            "speaker_alt_share": part_second,
            "overlap_share": chevauchement,
            "speech_share": part_parlee,
            "words": mots_du_groupe,
        })
        morceaux.append(morceau)
    return morceaux


def assign_speakers(whisper_segments, diarization_turns, par_mot: bool = False):
    """
    Associe à chaque segment de transcription le locuteur qui parle le plus
    pendant ce segment (recouvrement temporel maximal), et mesure à quel
    point cette attribution est nette.

    whisper_segments   : liste de dicts {"start": float, "end": float, "text": str, ...}
    diarization_turns  : liste de tuples (start: float, end: float, speaker: str)
    par_mot            : si vrai et que les segments portent une liste
                         "words" horodatée, l'attribution se fait mot à mot
                         et un segment peut être scindé en plusieurs — un
                         segment en entrée ne correspond donc plus
                         forcément à un segment en sortie.

    Retourne une nouvelle liste de dicts (les dicts d'entrée ne sont pas
    modifiés), avec les clés décrites en tête de module. Si aucun tour de
    parole ne recouvre le segment (silence entre deux tours, bruit, etc.),
    le locuteur vaut "INCONNU".
    """
    labeled = []
    for seg in whisper_segments:
        mots = _mots_horodates(seg) if par_mot else None
        if mots:
            morceaux = _decouper_par_locuteur(seg, mots, diarization_turns)
            if morceaux:
                labeled.extend(morceaux)
                continue
            # Un segment sans texte exploitable retombe sur le cas général
            # plutôt que de disparaître silencieusement du transcript.

        speaker, part, second, part_second, chevauchement, part_parlee = _indices(
            seg["start"], seg["end"], diarization_turns
        )
        new_seg = dict(seg)
        new_seg["speaker"] = speaker
        new_seg["speaker_share"] = part
        new_seg["speaker_alt"] = second
        new_seg["speaker_alt_share"] = part_second
        new_seg["overlap_share"] = chevauchement
        new_seg["speech_share"] = part_parlee
        labeled.append(new_seg)

    return labeled


def _combiner_indices(courant: dict, seg: dict) -> None:
    """Fond les indices de fiabilité de `seg` dans `courant`, au prorata des
    durées. À appeler AVANT d'étendre la fin de `courant`, sinon la
    pondération est fausse.

    Si l'un des deux segments ne porte pas ces indices (données produites
    avant cette version), la clé est retirée plutôt que remplacée par un
    zéro : « inconnu » et « totalement incertain » ne veulent pas dire la
    même chose, et afficher le second serait un faux signalement.
    """
    d1 = max(0.0, courant["end"] - courant["start"])
    d2 = max(0.0, seg["end"] - seg["start"])
    total = d1 + d2

    for cle in ("speaker_share", "overlap_share", "speech_share"):
        if cle in courant and cle in seg and total > 0:
            courant[cle] = round((courant[cle] * d1 + seg[cle] * d2) / total, 4)
        else:
            courant.pop(cle, None)

    if "speaker_alt" in courant and "speaker_alt" in seg and total > 0:
        poids: dict[str, float] = {}
        for source, duree in ((courant, d1), (seg, d2)):
            nom = source.get("speaker_alt")
            if nom:
                poids[nom] = poids.get(nom, 0.0) + source.get("speaker_alt_share", 0.0) * duree
        if poids:
            nom = max(poids, key=lambda k: (poids[k], k))
            courant["speaker_alt"] = nom
            courant["speaker_alt_share"] = round(poids[nom] / total, 4)
        else:
            courant["speaker_alt"] = None
            courant["speaker_alt_share"] = 0.0
    else:
        courant.pop("speaker_alt", None)
        courant.pop("speaker_alt_share", None)


def merge_consecutive(labeled_segments, max_gap=1.0):
    """
    Fusionne les segments consécutifs attribués au même locuteur (utile car
    Whisper découpe souvent un même tour de parole en plusieurs segments).

    max_gap : écart maximal (en secondes) toléré entre deux segments pour
    les considérer comme faisant partie du même tour de parole.

    Les indices de fiabilité sont fondus au prorata des durées : un tour de
    parole dont un seul morceau était douteux reste signalé, à proportion.
    """
    if not labeled_segments:
        return []
    merged = [dict(labeled_segments[0])]
    for seg in labeled_segments[1:]:
        current = merged[-1]
        if seg["speaker"] == current["speaker"] and (seg["start"] - current["end"]) <= max_gap:
            _combiner_indices(current, seg)
            current["end"] = seg["end"]
            current["text"] = (current["text"].strip() + " " + seg["text"].strip()).strip()
        else:
            merged.append(dict(seg))
    return merged
