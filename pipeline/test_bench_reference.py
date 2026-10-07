"""Vérifie la lecture d'un transcript corrigé comme vérité de terrain et le
calcul de DER qui en découle (bench_diarization.py --reference).

Ces deux fonctions décident lequel de deux modèles de diarisation est adopté :
une erreur ici ne ferait pas planter le banc d'essai, elle le ferait mentir.
D'où ces cas-pièges : locuteurs non tranchés, segments dégénérés, étiquettes
qui ne se correspondent pas d'un modèle à l'autre, et référence qui déborde
de l'extrait mesuré.

Lancer depuis le dossier du pipeline :
    python3 test_bench_reference.py
"""
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import bench_diarization as B
from pyannote.core import Annotation, Segment, Timeline

ok = True


def check(label, cond, detail=""):
    global ok
    print(("  OK    " if cond else "  ÉCHEC") + f" {label}" + (f"  → {detail}" if detail and not cond else ""))
    if not cond:
        ok = False


SEGMENTS = [
    {"start": 0.0, "end": 10.0, "speaker": "Roland", "text": "a"},
    {"start": 10.0, "end": 20.0, "speaker": "Élodie", "text": "b"},
    # non tranché à la relecture : ne doit pas être compté comme une vérité
    {"start": 20.0, "end": 24.0, "speaker": "INCONNU", "text": "c"},
    # durée nulle : à écarter plutôt qu'à propager dans la métrique
    {"start": 24.0, "end": 24.0, "speaker": "Roland", "text": "dégénéré"},
    # au-delà de l'extrait que l'on mesurera
    {"start": 30.0, "end": 40.0, "speaker": "Roland", "text": "hors extrait"},
]

tmp = Path(tempfile.mkdtemp())
source = tmp / "reunion_transcript.json"
source.write_text(json.dumps(SEGMENTS, ensure_ascii=False), encoding="utf-8")

print("== lecture de la référence ==")
reference = B.lire_reference(source)
check("segments INCONNU et de durée nulle écartés",
      sorted(reference.labels()) == ["Roland", "Élodie"], str(sorted(reference.labels())))

print("\n== DER contre la référence ==")
fenetre = Timeline([Segment(0.0, 25.0)])

parfait = Annotation()
parfait[Segment(0, 10), 0] = "SPEAKER_01"
parfait[Segment(10, 20), 1] = "SPEAKER_00"
m = B.evaluer(reference, parfait, uem=fenetre)
check("DER nulle malgré des étiquettes de locuteurs différentes",
      m is not None and m["der"] < 1e-9, str(m))
check("ce qui déborde de l'extrait n'est pas compté comme parole manquée",
      m is not None and m["manquee"] < 1e-9, str(m))

sans_fenetre = B.evaluer(reference, parfait, uem=None)
check("sans fenêtre d'évaluation, ce même débordement compte bien",
      sans_fenetre is not None and sans_fenetre["manquee"] > 0.2, str(sans_fenetre))

fusionne = Annotation()
fusionne[Segment(0, 10), 0] = "X"
fusionne[Segment(10, 20), 1] = "X"
m3 = B.evaluer(reference, fusionne, uem=fenetre)
check("deux locuteurs confondus en un seul → confusion élevée",
      m3 is not None and m3["confusion"] > 0.4, str(m3))
check("les trois composantes se somment bien à la DER",
      m3 is not None and abs(m3["confusion"] + m3["manquee"] + m3["fausse"] - m3["der"]) < 1e-6,
      str(m3))

print("\n== configurations ==")
check("la configuration communaute1 pointe bien sur community-1",
      B.CONFIGS["communaute1"].get("modele") == "communaute-1"
      and B.MODELES["communaute-1"].endswith("speaker-diarization-community-1"))
check("les configurations historiques gardent le modèle 3.1",
      "modele" not in B.CONFIGS["mps-lot32"] and B.MODELE_PAR_DEFAUT == "3.1")

print("\nRÉSULTAT :", "tout est vert" if ok else "DES TESTS ÉCHOUENT")
sys.exit(0 if ok else 1)
