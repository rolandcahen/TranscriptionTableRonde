"""Vérifie la conversion CSV sur des cas qui cassent naïvement un export :
accents, point-virgule dans le texte, guillemets, retour à la ligne,
timestamps manquants, et relecture réelle par le module csv."""
import csv, io, json, subprocess, sys, tempfile
from pathlib import Path

HERE = Path(__file__).parent
ok = True
def check(label, cond, detail=""):
    global ok
    print(("  OK   " if cond else "  ÉCHEC") + f" {label}" + (f"  → {detail}" if detail and not cond else ""))
    if not cond: ok = False

SEGMENTS = [
    {"start": 0.0, "end": 3.5, "text": "Bonjour à toutes et à tous.", "speaker": "Roland"},
    # piège 1 : un point-virgule, qui est justement le séparateur en style excel-fr
    {"start": 3.5, "end": 9.25, "text": "Trois points ; le premier est budgétaire.", "speaker": "Élodie"},
    # piège 2 : des guillemets doubles
    {"start": 9.25, "end": 14.0, "text": 'Il a dit "on verra" et personne n\'a réagi.', "speaker": "Roland"},
    # piège 3 : un retour à la ligne dans le texte
    {"start": 14.0, "end": 20.0, "text": "Première ligne\nseconde ligne.", "speaker": "SPEAKER_02"},
    # piège 4 : champs absents
    {"text": "Segment sans horodatage.", "speaker": "INCONNU"},
    # piège 5 : virgule, pour le style international
    {"start": 20.0, "end": 26.5, "text": "Oui, non, peut-être.", "speaker": "Élodie"},
]

tmp = Path(tempfile.mkdtemp())
src = tmp / "reunion_transcript.json"
src.write_text(json.dumps(SEGMENTS, ensure_ascii=False), encoding="utf-8")

print("== style excel-fr (point-virgule + BOM) ==")
r = subprocess.run([sys.executable, str(HERE / "transcript_to_csv.py"), "--transcript", str(src)],
                   capture_output=True, text=True)
print("   " + r.stdout.strip())
dest = src.with_suffix(".csv")
check("le script se termine bien", r.returncode == 0, r.stderr[-300:])
check("le CSV est créé", dest.exists())

brut = dest.read_bytes()
check("BOM présent pour Excel", brut.startswith(b"\xef\xbb\xbf"))

with open(dest, encoding="utf-8-sig", newline="") as f:
    lignes = list(csv.reader(f, delimiter=";"))
entetes, donnees = lignes[0], lignes[1:]
check("en-têtes attendus", entetes[:4] == ["n", "locuteur", "debut", "fin"], str(entetes[:4]))
check("colonnes de codage vides présentes", entetes[-3:] == ["code_1", "code_2", "code_3"], str(entetes[-3:]))
check("6 segments relus", len(donnees) == 6, str(len(donnees)))
check("toutes les lignes ont 12 colonnes", all(len(l) == 12 for l in donnees), str([len(l) for l in donnees]))
check("accents intacts", donnees[1][1] == "Élodie", donnees[1][1])
check("point-virgule du texte non interprété comme séparateur",
      donnees[1][8] == "Trois points ; le premier est budgétaire.", donnees[1][8])
check("guillemets préservés", '"on verra"' in donnees[2][8], donnees[2][8])
check("retour à la ligne conservé dans une seule cellule",
      donnees[3][8] == "Première ligne\nseconde ligne.", repr(donnees[3][8]))
check("horodatage manquant -> 00:00:00", donnees[4][2] == "00:00:00", donnees[4][2])
check("format hh:mm:ss correct", donnees[1][2] == "00:00:03" and donnees[1][3] == "00:00:09",
      f"{donnees[1][2]} / {donnees[1][3]}")
check("durée calculée", donnees[1][6] == "5.75", donnees[1][6])
check("comptage de mots", donnees[0][7] == "6", donnees[0][7])

print("\n== style international (virgule, sans BOM) ==")
dest2 = tmp / "international.csv"
r = subprocess.run([sys.executable, str(HERE / "transcript_to_csv.py"), "--transcript", str(src),
                    "--output", str(dest2), "--style", "international"], capture_output=True, text=True)
check("conversion réussie", r.returncode == 0, r.stderr[-300:])
check("pas de BOM", not dest2.read_bytes().startswith(b"\xef\xbb\xbf"))
with open(dest2, encoding="utf-8", newline="") as f:
    d2 = list(csv.reader(f))[1:]
check("virgule du texte non interprétée comme séparateur",
      d2[5][8] == "Oui, non, peut-être.", d2[5][8])
check("mêmes données que le style excel-fr", [l[8] for l in d2] == [l[8] for l in donnees])

print("\n== traitement d'un dossier entier ==")
sous = tmp / "sortie_autre"; sous.mkdir()
(sous / "autre_transcript.json").write_text(json.dumps(SEGMENTS[:2], ensure_ascii=False), encoding="utf-8")
(sous / "autre_whisper_raw.json").write_text(json.dumps({"segments": []}), encoding="utf-8")
r = subprocess.run([sys.executable, str(HERE / "transcript_to_csv.py"), "--dossier", str(tmp)],
                   capture_output=True, text=True)
print("   " + r.stdout.strip().replace("\n", "\n   "))
check("les deux transcripts sont convertis", r.stdout.count("  ok      ") == 2, r.stdout)
check("le cache whisper_raw est ignoré", "whisper_raw" not in r.stdout)

print("\n== garde-fous ==")
r = subprocess.run([sys.executable, str(HERE / "transcript_to_csv.py")], capture_output=True, text=True)
check("refuse sans argument", r.returncode != 0 and "indiquez" in (r.stdout + r.stderr))
r = subprocess.run([sys.executable, str(HERE / "transcript_to_csv.py"), "--transcript", "/tmp/nexistepas.json"],
                   capture_output=True, text=True)
check("refuse un fichier absent", r.returncode != 0 and "introuvable" in (r.stdout + r.stderr))
casse = tmp / "casse_transcript.json"; casse.write_text("{ pas du json", encoding="utf-8")
r = subprocess.run([sys.executable, str(HERE / "transcript_to_csv.py"), "--transcript", str(casse)],
                   capture_output=True, text=True)
check("signale un JSON corrompu sans planter", "echec" in r.stdout, r.stdout + r.stderr[-200:])

print("\nRÉSULTAT :", "tout est vert" if ok else "DES TESTS ÉCHOUENT")
sys.exit(0 if ok else 1)
