"""
Fonctions d'alignement entre les segments de transcription (Whisper) et les
tours de parole détectés par la diarisation (pyannote).

Ce module est volontairement indépendant de mlx-whisper et pyannote : il ne
manipule que des structures Python simples (listes de dicts / tuples), ce
qui permet de le tester sans installer ces deux librairies.
Voir test_align.py.
"""
from __future__ import annotations


def assign_speakers(whisper_segments, diarization_turns):
    """
    Associe à chaque segment de transcription le locuteur qui parle le plus
    pendant ce segment (recouvrement temporel maximal).

    whisper_segments   : liste de dicts {"start": float, "end": float, "text": str, ...}
    diarization_turns  : liste de tuples (start: float, end: float, speaker: str)

    Retourne une nouvelle liste de dicts (les dicts d'entrée ne sont pas
    modifiés), avec une clé "speaker" ajoutée. Si aucun tour de parole ne
    recouvre le segment (silence entre deux tours, bruit, etc.), le
    locuteur vaut "INCONNU".
    """
    labeled = []
    for seg in whisper_segments:
        seg_start, seg_end = seg["start"], seg["end"]
        overlap_by_speaker = {}
        for turn_start, turn_end, speaker in diarization_turns:
            overlap = min(seg_end, turn_end) - max(seg_start, turn_start)
            if overlap > 0:
                overlap_by_speaker[speaker] = overlap_by_speaker.get(speaker, 0.0) + overlap
        speaker = max(overlap_by_speaker, key=overlap_by_speaker.get) if overlap_by_speaker else "INCONNU"
        new_seg = dict(seg)
        new_seg["speaker"] = speaker
        labeled.append(new_seg)
    return labeled


def merge_consecutive(labeled_segments, max_gap=1.0):
    """
    Fusionne les segments consécutifs attribués au même locuteur (utile car
    Whisper découpe souvent un même tour de parole en plusieurs segments).

    max_gap : écart maximal (en secondes) toléré entre deux segments pour
    les considérer comme faisant partie du même tour de parole.
    """
    if not labeled_segments:
        return []
    merged = [dict(labeled_segments[0])]
    for seg in labeled_segments[1:]:
        current = merged[-1]
        if seg["speaker"] == current["speaker"] and (seg["start"] - current["end"]) <= max_gap:
            current["end"] = seg["end"]
            current["text"] = (current["text"].strip() + " " + seg["text"].strip()).strip()
        else:
            merged.append(dict(seg))
    return merged
