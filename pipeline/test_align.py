"""
Tests unitaires pour align.py — ne nécessitent ni mlx-whisper ni pyannote,
juste de la donnée simulée. Lancer avec : python test_align.py
"""
from align import assign_speakers, merge_consecutive


def test_basic_assignment():
    whisper_segments = [
        {"start": 0.0, "end": 3.0, "text": "Bonjour à tous."},
        {"start": 3.2, "end": 6.0, "text": "Merci d'être là."},
        {"start": 6.5, "end": 10.0, "text": "Je voulais réagir sur ce point."},
    ]
    diarization_turns = [
        (0.0, 6.2, "SPEAKER_00"),
        (6.3, 12.0, "SPEAKER_01"),
    ]
    labeled = assign_speakers(whisper_segments, diarization_turns)
    assert labeled[0]["speaker"] == "SPEAKER_00"
    assert labeled[1]["speaker"] == "SPEAKER_00"
    assert labeled[2]["speaker"] == "SPEAKER_01"
    # les dicts d'entrée ne doivent pas être modifiés
    assert "speaker" not in whisper_segments[0]


def test_split_overlap_picks_majority_speaker():
    # un segment Whisper qui chevauche deux tours de parole doit être
    # attribué au locuteur avec le plus de recouvrement temporel
    whisper_segments = [{"start": 5.0, "end": 9.0, "text": "phrase à cheval"}]
    diarization_turns = [
        (0.0, 6.0, "SPEAKER_00"),   # 1s de recouvrement (5-6)
        (6.0, 20.0, "SPEAKER_01"),  # 3s de recouvrement (6-9)
    ]
    labeled = assign_speakers(whisper_segments, diarization_turns)
    assert labeled[0]["speaker"] == "SPEAKER_01"


def test_merge_consecutive():
    labeled = [
        {"start": 0.0, "end": 3.0, "text": "Bonjour à tous.", "speaker": "SPEAKER_00"},
        {"start": 3.2, "end": 6.0, "text": "Merci d'être là.", "speaker": "SPEAKER_00"},
        {"start": 6.5, "end": 10.0, "text": "Je voulais réagir.", "speaker": "SPEAKER_01"},
    ]
    merged = merge_consecutive(labeled, max_gap=1.0)
    assert len(merged) == 2
    assert merged[0]["speaker"] == "SPEAKER_00"
    assert merged[0]["text"] == "Bonjour à tous. Merci d'être là."
    assert merged[0]["start"] == 0.0
    assert merged[0]["end"] == 6.0
    assert merged[1]["speaker"] == "SPEAKER_01"


def test_merge_respects_max_gap():
    labeled = [
        {"start": 0.0, "end": 3.0, "text": "A", "speaker": "SPEAKER_00"},
        {"start": 8.0, "end": 10.0, "text": "B", "speaker": "SPEAKER_00"},  # trou de 5s
    ]
    merged = merge_consecutive(labeled, max_gap=1.0)
    assert len(merged) == 2  # pas fusionné, trou trop grand


def test_unknown_speaker_when_no_overlap():
    whisper_segments = [{"start": 100.0, "end": 102.0, "text": "silence avant"}]
    diarization_turns = [(0.0, 5.0, "SPEAKER_00")]
    labeled = assign_speakers(whisper_segments, diarization_turns)
    assert labeled[0]["speaker"] == "INCONNU"


def test_empty_input():
    assert assign_speakers([], [(0.0, 5.0, "SPEAKER_00")]) == []
    assert merge_consecutive([]) == []


# --- fiabilité de l'attribution -------------------------------------------
# Ces tests portent sur ce qui était jusqu'ici perdu en silence : un segment
# à cheval sur un changement de locuteur, et deux personnes qui parlent en
# même temps. L'enjeu n'est pas de mieux deviner, mais de savoir dire que
# l'on ne sait pas.

def test_segment_net_est_annonce_comme_sur():
    whisper_segments = [{"start": 0.0, "end": 4.0, "text": "tour de parole propre"}]
    diarization_turns = [(0.0, 10.0, "SPEAKER_00")]
    seg = assign_speakers(whisper_segments, diarization_turns)[0]
    assert seg["speaker_share"] == 1.0
    assert seg["speaker_alt"] is None
    assert seg["overlap_share"] == 0.0


def test_segment_a_cheval_est_signale():
    # 1s pour SPEAKER_00, 3s pour SPEAKER_01 : l'attribution reste la bonne,
    # mais un quart du segment appartient à quelqu'un d'autre et doit se voir.
    whisper_segments = [{"start": 5.0, "end": 9.0, "text": "phrase à cheval"}]
    diarization_turns = [(0.0, 6.0, "SPEAKER_00"), (6.0, 20.0, "SPEAKER_01")]
    seg = assign_speakers(whisper_segments, diarization_turns)[0]
    assert seg["speaker"] == "SPEAKER_01"
    assert abs(seg["speaker_share"] - 0.75) < 1e-6
    assert seg["speaker_alt"] == "SPEAKER_00"
    assert abs(seg["speaker_alt_share"] - 0.25) < 1e-6
    # tours successifs, pas simultanés : aucun chevauchement
    assert seg["overlap_share"] == 0.0


def test_parole_simultanee_est_mesuree():
    # les deux locuteurs se recouvrent de 4.0 à 6.0, soit 2s sur 8s
    whisper_segments = [{"start": 0.0, "end": 8.0, "text": "tout le monde parle"}]
    diarization_turns = [(0.0, 6.0, "SPEAKER_00"), (4.0, 8.0, "SPEAKER_01")]
    seg = assign_speakers(whisper_segments, diarization_turns)[0]
    assert abs(seg["overlap_share"] - 0.25) < 1e-6
    assert seg["speaker"] == "SPEAKER_00"
    assert seg["speaker_alt"] == "SPEAKER_01"


def test_pistes_multiples_du_meme_locuteur_ne_font_pas_un_chevauchement():
    # pyannote peut émettre deux pistes pour une même personne ; les compter
    # séparément inventerait un chevauchement inexistant
    whisper_segments = [{"start": 0.0, "end": 10.0, "text": "une seule voix"}]
    diarization_turns = [(0.0, 6.0, "SPEAKER_00"), (3.0, 10.0, "SPEAKER_00")]
    seg = assign_speakers(whisper_segments, diarization_turns)[0]
    assert seg["overlap_share"] == 0.0
    assert seg["speaker_share"] == 1.0
    assert seg["speaker_alt"] is None


def test_segment_sans_locuteur_est_a_zero_de_fiabilite():
    whisper_segments = [{"start": 100.0, "end": 102.0, "text": "hors tour de parole"}]
    seg = assign_speakers(whisper_segments, [(0.0, 5.0, "SPEAKER_00")])[0]
    assert seg["speaker"] == "INCONNU"
    assert seg["speaker_share"] == 0.0


def test_fusion_pondere_les_indices_par_la_duree():
    # 3s parfaitement attribuées puis 1s douteuse : le tour fusionné doit
    # rester signalé, mais à proportion — ni blanchi, ni noirci.
    labeled = [
        {"start": 0.0, "end": 3.0, "text": "A", "speaker": "S0",
         "speaker_share": 1.0, "speaker_alt": None, "speaker_alt_share": 0.0,
         "overlap_share": 0.0},
        {"start": 3.0, "end": 4.0, "text": "B", "speaker": "S0",
         "speaker_share": 0.5, "speaker_alt": "S1", "speaker_alt_share": 0.5,
         "overlap_share": 0.4},
    ]
    merged = merge_consecutive(labeled, max_gap=1.0)
    assert len(merged) == 1
    assert abs(merged[0]["speaker_share"] - (1.0 * 3 + 0.5 * 1) / 4) < 1e-6
    assert abs(merged[0]["overlap_share"] - (0.0 * 3 + 0.4 * 1) / 4) < 1e-6
    assert merged[0]["speaker_alt"] == "S1"
    assert abs(merged[0]["speaker_alt_share"] - (0.5 * 1) / 4) < 1e-6


def test_fusion_de_donnees_anciennes_ne_fabrique_pas_de_faux_signalement():
    # un transcript produit avant cette version n'a pas ces clés : il ne doit
    # pas se retrouver marqué « totalement incertain » (part = 0), ce qui
    # serait un contresens. Mieux vaut ne rien dire.
    labeled = [
        {"start": 0.0, "end": 3.0, "text": "A", "speaker": "S0"},
        {"start": 3.0, "end": 4.0, "text": "B", "speaker": "S0"},
    ]
    merged = merge_consecutive(labeled, max_gap=1.0)
    assert len(merged) == 1
    assert "speaker_share" not in merged[0]
    assert "overlap_share" not in merged[0]
    assert merged[0]["text"] == "A B"


def test_les_dicts_d_entree_restent_intacts():
    whisper_segments = [{"start": 0.0, "end": 4.0, "text": "x"}]
    assign_speakers(whisper_segments, [(0.0, 4.0, "S0")])
    assert set(whisper_segments[0]) == {"start", "end", "text"}


# --- silence contre ambiguïté -----------------------------------------------
# Ces tests fixent la leçon d'une erreur de conception : la part du locuteur
# était rapportée à la durée du segment, si bien que le silence entourant une
# courte réplique la faisait passer pour douteuse. Les deux questions sont
# désormais distinctes — « est-ce ambigu ? » et « y a-t-il de la parole ? ».

def test_une_courte_replique_dans_un_long_silence_reste_certaine():
    # « D'accord. » : une seconde de parole dans huit secondes de segment.
    # Personne d'autre ne parle : l'attribution est certaine, point.
    whisper_segments = [{"start": 0.0, "end": 8.0, "text": "D'accord."}]
    diarization_turns = [(3.0, 4.0, "SPEAKER_00")]
    seg = assign_speakers(whisper_segments, diarization_turns)[0]
    assert seg["speaker"] == "SPEAKER_00"
    assert seg["speaker_share"] == 1.0
    assert abs(seg["speech_share"] - 0.125) < 1e-6


def test_le_silence_se_lit_separement_de_l_ambiguite():
    # moitié de parole, et dans cette parole deux locuteurs à parts égales
    whisper_segments = [{"start": 0.0, "end": 10.0, "text": "x"}]
    diarization_turns = [(0.0, 2.5, "SPEAKER_00"), (2.5, 5.0, "SPEAKER_01")]
    seg = assign_speakers(whisper_segments, diarization_turns)[0]
    assert abs(seg["speech_share"] - 0.5) < 1e-6
    assert abs(seg["speaker_share"] - 0.5) < 1e-6
    assert seg["speaker_alt"] is not None


def test_texte_sans_aucune_parole_detectee():
    # le signal le plus net d'une invention de Whisper sur du silence
    whisper_segments = [{"start": 50.0, "end": 55.0, "text": "Merci d'avoir regardé."}]
    seg = assign_speakers(whisper_segments, [(0.0, 10.0, "SPEAKER_00")])[0]
    assert seg["speech_share"] == 0.0
    assert seg["speaker"] == "INCONNU"


def test_la_parole_simultanee_ne_depasse_jamais_la_duree():
    # trois locuteurs sur les mêmes 4 secondes : 4 secondes de parole, pas 12
    whisper_segments = [{"start": 0.0, "end": 4.0, "text": "brouhaha"}]
    diarization_turns = [(0.0, 4.0, "A"), (0.0, 4.0, "B"), (0.0, 4.0, "C")]
    seg = assign_speakers(whisper_segments, diarization_turns)[0]
    assert seg["speech_share"] == 1.0
    assert seg["overlap_share"] == 1.0
    assert abs(seg["speaker_share"] - 1.0) < 1e-6


def test_la_part_de_parole_se_fusionne_aussi():
    labeled = [
        {"start": 0.0, "end": 4.0, "text": "A", "speaker": "S0", "speaker_share": 1.0,
         "speaker_alt": None, "speaker_alt_share": 0.0, "overlap_share": 0.0,
         "speech_share": 1.0},
        {"start": 4.0, "end": 8.0, "text": "B", "speaker": "S0", "speaker_share": 1.0,
         "speaker_alt": None, "speaker_alt_share": 0.0, "overlap_share": 0.0,
         "speech_share": 0.0},
    ]
    merged = merge_consecutive(labeled, max_gap=1.0)
    assert len(merged) == 1
    assert abs(merged[0]["speech_share"] - 0.5) < 1e-6
    assert merged[0]["speaker_share"] == 1.0


# --- attribution mot à mot -------------------------------------------------
# Whisper découpe selon la prosodie, sans rien savoir des tours de parole :
# un segment peut enjamber un changement de locuteur, et l'attribution au
# segment le fait alors basculer tout entier du mauvais côté. Avec
# l'horodatage de chaque mot, la coupe tombe au bon endroit.

def _mot(texte, debut, fin):
    return {"word": texte, "start": debut, "end": fin}


SEGMENT_A_CHEVAL = {
    "start": 0.0, "end": 4.0, "avg_logprob": -0.21,
    "text": " oui tout à fait non je ne crois pas",
    "words": [
        _mot(" oui", 0.0, 0.5), _mot(" tout", 0.5, 0.9), _mot(" à", 0.9, 1.1),
        _mot(" fait", 1.1, 1.5),
        _mot(" non", 2.1, 2.5), _mot(" je", 2.5, 2.8), _mot(" ne", 2.8, 3.0),
        _mot(" crois", 3.0, 3.4), _mot(" pas", 3.4, 4.0),
    ],
}
TOURS_A_CHEVAL = [(0.0, 2.0, "SPEAKER_00"), (2.0, 6.0, "SPEAKER_01")]


def test_sans_horodatage_mot_le_segment_bascule_en_entier():
    # le comportement d'avant, qu'on veut pouvoir comparer : 2s contre 2s,
    # départagées par l'ordre, et la moitié du texte est mal attribuée
    seg = dict(SEGMENT_A_CHEVAL)
    seg.pop("words")
    resultat = assign_speakers([seg], TOURS_A_CHEVAL)
    assert len(resultat) == 1
    assert "non je ne crois pas" in resultat[0]["text"]
    assert "oui tout à fait" in resultat[0]["text"]


def test_le_mode_mot_a_mot_coupe_au_changement_de_locuteur():
    resultat = assign_speakers([SEGMENT_A_CHEVAL], TOURS_A_CHEVAL, par_mot=True)
    assert len(resultat) == 2
    assert resultat[0]["speaker"] == "SPEAKER_00"
    assert resultat[0]["text"] == "oui tout à fait"
    assert resultat[1]["speaker"] == "SPEAKER_01"
    assert resultat[1]["text"] == "non je ne crois pas"
    # les bornes suivent les mots, pas celles du segment d'origine
    assert resultat[0]["start"] == 0.0 and resultat[0]["end"] == 1.5
    assert resultat[1]["start"] == 2.1 and resultat[1]["end"] == 4.0


def test_les_morceaux_bien_decoupes_s_annoncent_comme_surs():
    resultat = assign_speakers([SEGMENT_A_CHEVAL], TOURS_A_CHEVAL, par_mot=True)
    for morceau in resultat:
        assert morceau["speaker_share"] == 1.0
        assert morceau["overlap_share"] == 0.0


def test_les_morceaux_heritent_des_cles_du_segment():
    # avg_logprob alimente l'indice de confiance de la fenêtre de
    # vérification : le perdre en découpant rendrait l'indicateur muet
    resultat = assign_speakers([SEGMENT_A_CHEVAL], TOURS_A_CHEVAL, par_mot=True)
    assert all(m["avg_logprob"] == -0.21 for m in resultat)


def test_un_segment_mono_locuteur_n_est_pas_decoupe():
    resultat = assign_speakers([SEGMENT_A_CHEVAL], [(0.0, 10.0, "SPEAKER_00")], par_mot=True)
    assert len(resultat) == 1
    assert resultat[0]["text"] == "oui tout à fait non je ne crois pas"


def test_horodatage_mot_incomplet_retombe_sur_le_segment():
    # un seul mot sans bornes suffit : on ne devine pas, on renonce au mode
    # fin pour ce segment plutôt que d'attribuer au hasard
    seg = dict(SEGMENT_A_CHEVAL)
    seg["words"] = [dict(m) for m in SEGMENT_A_CHEVAL["words"]]
    seg["words"][3] = {"word": " fait", "start": None, "end": None}
    resultat = assign_speakers([seg], TOURS_A_CHEVAL, par_mot=True)
    assert len(resultat) == 1


def test_par_mot_sans_mots_equivaut_au_mode_segment():
    seg = dict(SEGMENT_A_CHEVAL)
    seg.pop("words")
    assert (assign_speakers([seg], TOURS_A_CHEVAL, par_mot=True)
            == assign_speakers([seg], TOURS_A_CHEVAL))


def test_les_morceaux_se_refusionnent_correctement():
    # découper puis refusionner ne doit pas recréer le mélange : les deux
    # morceaux appartiennent à des locuteurs différents
    morceaux = assign_speakers([SEGMENT_A_CHEVAL], TOURS_A_CHEVAL, par_mot=True)
    fusionnes = merge_consecutive(morceaux, max_gap=1.0)
    assert len(fusionnes) == 2


if __name__ == "__main__":
    tests = [
        test_basic_assignment,
        test_split_overlap_picks_majority_speaker,
        test_merge_consecutive,
        test_merge_respects_max_gap,
        test_unknown_speaker_when_no_overlap,
        test_empty_input,
        test_segment_net_est_annonce_comme_sur,
        test_segment_a_cheval_est_signale,
        test_parole_simultanee_est_mesuree,
        test_pistes_multiples_du_meme_locuteur_ne_font_pas_un_chevauchement,
        test_segment_sans_locuteur_est_a_zero_de_fiabilite,
        test_fusion_pondere_les_indices_par_la_duree,
        test_fusion_de_donnees_anciennes_ne_fabrique_pas_de_faux_signalement,
        test_les_dicts_d_entree_restent_intacts,
        test_une_courte_replique_dans_un_long_silence_reste_certaine,
        test_le_silence_se_lit_separement_de_l_ambiguite,
        test_texte_sans_aucune_parole_detectee,
        test_la_parole_simultanee_ne_depasse_jamais_la_duree,
        test_la_part_de_parole_se_fusionne_aussi,
        test_sans_horodatage_mot_le_segment_bascule_en_entier,
        test_le_mode_mot_a_mot_coupe_au_changement_de_locuteur,
        test_les_morceaux_bien_decoupes_s_annoncent_comme_surs,
        test_les_morceaux_heritent_des_cles_du_segment,
        test_un_segment_mono_locuteur_n_est_pas_decoupe,
        test_horodatage_mot_incomplet_retombe_sur_le_segment,
        test_par_mot_sans_mots_equivaut_au_mode_segment,
        test_les_morceaux_se_refusionnent_correctement,
    ]
    for t in tests:
        t()
        print(f"OK  {t.__name__}")
    print("\nTous les tests sont passés.")
