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


if __name__ == "__main__":
    tests = [
        test_basic_assignment,
        test_split_overlap_picks_majority_speaker,
        test_merge_consecutive,
        test_merge_respects_max_gap,
        test_unknown_speaker_when_no_overlap,
        test_empty_input,
    ]
    for t in tests:
        t()
        print(f"OK  {t.__name__}")
    print("\nTous les tests sont passés.")
