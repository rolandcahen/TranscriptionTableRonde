"""
Tests des parties déterministes de summarize.py — celles qui ne dépendent
d'aucun modèle et qui, si elles se trompaient, le feraient en silence.

Ce qui est vérifié ici porte toute la crédibilité du résumé : la résolution
des citations, qui décide ce qui est affirmé et ce qui est renvoyé en « à
vérifier », et le filtrage des noms de locuteurs inventés, qui sans cela se
propageraient jusqu'au document final avec l'apparence d'un fait.

Lancer depuis le dossier du pipeline : python3 test_summarize.py
"""
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from summarize import (
    GRILLE_ANALYTIQUE, GRILLE_DESCRIPTIVE, chunk_blocks, ecrire_markdown,
    fiabilite, fmt_ts, load_blocks, lire_flux, nettoyer_synthese,
    parse_categories, parse_notes, parse_ts, ranger,
)

ok = True


def check(label, cond, detail=""):
    global ok
    print(("  OK    " if cond else "  ÉCHEC") + f" {label}" + (f"  → {detail}" if detail and not cond else ""))
    if not cond:
        ok = False


CHUNK = [
    {"debut": 0.0, "fin": 12.0, "speaker": "Roland", "text": "Je propose qu'on parte du terrain.",
     "douteux": False, "chevauchement": 0.0},
    {"debut": 12.0, "fin": 30.0, "speaker": "Élodie", "text": "Je ne suis pas d'accord, il faut cadrer avant.",
     "douteux": False, "chevauchement": 0.4},
    {"debut": 30.0, "fin": 44.0, "speaker": "Dominique", "text": "Et le budget, on en parle quand ?",
     "douteux": True, "chevauchement": 0.0},
]

print("== horodatages ==")
check("aller-retour hh:mm:ss", fmt_ts(parse_ts("01:02:03")) == "01:02:03")
check("minutes seules acceptées", abs(parse_ts("02:30") - 150.0) < 1e-9, str(parse_ts("02:30")))
check("valeur illisible → 0", parse_ts("abc") == 0.0)

print("\n== relevé de notes ==")

brut = json.dumps({"notes": [
    {"type": "proposition", "locuteurs": ["Roland"], "t": "00:00:05",
     "enonce": "Roland propose de partir du terrain."},
    {"type": "desaccord", "locuteurs": ["Élodie", "Roland"], "t": "00:00:20",
     "enonce": "Élodie juge qu'il faut cadrer avant."},
]}, ensure_ascii=False)
notes = parse_notes(brut, CHUNK, "t1n")
check("deux notes relevées", len(notes) == 2, str(len(notes)))
check("identifiants préfixés et numérotés", [n["id"] for n in notes] == ["t1n1", "t1n2"],
      str([n["id"] for n in notes]))
check("type conservé", notes[1]["type"] == "desaccord", notes[1]["type"])

brut = json.dumps([{"type": "fait", "locuteurs": ["Roland"], "t": "00:00:03", "enonce": "x"}])
check("une liste nue est acceptée aussi", len(parse_notes(brut, CHUNK, "t1n")) == 1)

check("JSON invalide → aucune note, sans exception", parse_notes("{pas du json", CHUNK, "t1n") == [])

brut = json.dumps({"notes": [{"type": "position", "locuteurs": ["Jean-Michel"],
                              "t": "00:00:05", "enonce": "x"}]})
notes = parse_notes(brut, CHUNK, "t1n")
check("un locuteur inventé est écarté", notes[0]["locuteurs"] == [], str(notes[0]["locuteurs"]))

brut = json.dumps({"notes": [{"type": "position", "locuteurs": [], "t": "02:30:00", "enonce": "x"}]})
notes = parse_notes(brut, CHUNK, "t1n")
check("un horodatage hors tranche est ramené au début", notes[0]["t"] == 0.0, str(notes[0]["t"]))

brut = json.dumps({"notes": [{"type": "truc_inconnu", "locuteurs": [], "t": "00:00:05", "enonce": "x"}]})
check("un type inconnu devient « fait »", parse_notes(brut, CHUNK, "t1n")[0]["type"] == "fait")

brut = json.dumps({"notes": [{"type": "fait", "locuteurs": [], "t": "00:00:05", "enonce": "   "}]})
check("un énoncé vide n'est pas retenu", parse_notes(brut, CHUNK, "t1n") == [])

print("\n== fiabilité héritée de la transcription ==")
check("parole superposée → réserve",
      "en même temps" in (fiabilite({"t": 20.0}, CHUNK) or ""), str(fiabilite({"t": 20.0}, CHUNK)))
check("passage douteux → réserve",
      "douteux" in (fiabilite({"t": 35.0}, CHUNK) or ""), str(fiabilite({"t": 35.0}, CHUNK)))
check("passage sain → aucune réserve", fiabilite({"t": 5.0}, CHUNK) is None)

print("\n== rangement et résolution des citations ==")

NOTES = [
    {"id": "t1n1", "type": "proposition", "locuteurs": ["Roland"], "t": 5.0,
     "enonce": "Roland propose de partir du terrain."},
    {"id": "t1n2", "type": "desaccord", "locuteurs": ["Élodie"], "t": 20.0,
     "enonce": "Élodie veut cadrer avant."},
    {"id": "t1n3", "type": "question", "locuteurs": ["Dominique"], "t": 35.0,
     "enonce": "Dominique demande quand le budget sera abordé."},
]
CATEGORIES = {"positions": "Positions", "desaccords": "Désaccords",
              "questions_ouvertes": "Questions ouvertes"}

brut = json.dumps({
    "positions": [{"texte": "Roland veut partir du terrain.", "notes": ["t1n1"]}],
    "desaccords": [{"texte": "Élodie s'oppose à Roland sur la méthode.",
                    "notes": ["t1n1", "t1n2"]}],
    "questions_ouvertes": [
        {"texte": "Le budget n'a pas été abordé.", "notes": ["t1n3"]},
        {"texte": "Le calendrier a été validé par tous.", "notes": ["t9n9"]},
        {"texte": "Un item sans citation du tout.", "notes": []},
        "une simple chaîne, donc sans citation",
    ],
}, ensure_ascii=False)

resultat, ecartes = ranger(brut, CATEGORIES, NOTES, CHUNK)
check("item correctement cité → retenu", len(resultat["positions"]) == 1)
check("item citant un identifiant inexistant → écarté",
      any("calendrier" in e["texte"] for e in ecartes), str(ecartes))
check("item sans citation → écarté", any("sans citation du tout" in e["texte"] for e in ecartes))
check("chaîne nue → écartée faute de citation",
      any("simple chaîne" in e["texte"] for e in ecartes))
check("trois items écartés en tout", len(ecartes) == 3, str(len(ecartes)))

desaccord = resultat["desaccords"][0]
check("les locuteurs sont résolus depuis les notes citées",
      desaccord["locuteurs"] == ["Roland", "Élodie"] or desaccord["locuteurs"] == ["Élodie", "Roland"],
      str(desaccord["locuteurs"]))
check("les horodatages sont résolus depuis les notes citées",
      desaccord["horodatages"] == ["00:00:05", "00:00:20"], str(desaccord["horodatages"]))
check("la réserve de chevauchement remonte jusqu'à l'item",
      any("en même temps" in r for r in desaccord["reserves"]), str(desaccord["reserves"]))

question = resultat["questions_ouvertes"][0]
check("la réserve « passage douteux » remonte aussi",
      any("douteux" in r for r in question["reserves"]), str(question["reserves"]))
check("un item bien cité n'hérite d'aucune réserve indue",
      resultat["positions"][0]["reserves"] == [], str(resultat["positions"][0]["reserves"]))

brut_remplissage = json.dumps({
    "positions": [
        {"texte": "Cette catégorie n'est pas mentionnée dans l'extrait.", "notes": ["t1n1"]},
        {"texte": "Aucun élément du transcript ne concerne ce point.", "notes": ["t1n1"]},
    ],
})
r2, e2 = ranger(brut_remplissage, CATEGORIES, NOTES, CHUNK)
check("les phrases qui commentent le formulaire sont filtrées",
      r2["positions"] == [], str(r2["positions"]))

# Le piège symétrique, et il est grave : un constat d'absence PORTANT SUR LA
# RÉUNION est souvent l'information la plus utile d'un compte rendu. Un filtre
# qui le confondrait avec une phrase meta supprimerait ce qu'on cherche.
brut_constat = json.dumps({
    "questions_ouvertes": [
        {"texte": "Le budget n'a pas été abordé de toute la séance.", "notes": ["t1n3"]},
        {"texte": "Personne n'a répondu à la question de Dominique.", "notes": ["t1n3"]},
    ],
}, ensure_ascii=False)
r2b, _ = ranger(brut_constat, CATEGORIES, NOTES, CHUNK)
check("un constat d'absence portant sur la réunion est CONSERVÉ",
      len(r2b["questions_ouvertes"]) == 2,
      str([i["texte"] for i in r2b["questions_ouvertes"]]))

check("JSON invalide → rien, sans exception", ranger("pas du json", CATEGORIES, NOTES, CHUNK) == ({}, []))

print("\n== ordre et sortie lisible ==")
brut_ordre = json.dumps({"positions": [
    {"texte": "second dans le temps", "notes": ["t1n3"]},
    {"texte": "premier dans le temps", "notes": ["t1n1"]},
]}, ensure_ascii=False)
r3, _ = ranger(brut_ordre, CATEGORIES, NOTES, CHUNK)
check("les items sont ordonnés chronologiquement",
      r3["positions"][0]["texte"] == "premier dans le temps",
      str([i["texte"] for i in r3["positions"]]))

tmp = Path(tempfile.mkdtemp())
md = tmp / "reunion_resume.md"
ecrire_markdown("reunion", resultat, ecartes, CATEGORIES, NOTES, md)
texte_md = md.read_text(encoding="utf-8")
check("le markdown porte les horodatages", "`00:00:05`" in texte_md)
check("le markdown nomme les locuteurs", "Roland" in texte_md)
check("la section « à vérifier » apparaît", "À vérifier" in texte_md)
check("les réserves sont visibles", "⚠️" in texte_md)
md_vide = tmp / "vide_resume.md"
ecrire_markdown("vide", {"positions": [], "desaccords": [], "questions_ouvertes": []},
                [], CATEGORIES, [], md_vide)
texte_vide = md_vide.read_text(encoding="utf-8")
check("une catégorie vide est annoncée comme telle",
      texte_vide.count("_Aucun élément identifié._") == 3,
      str(texte_vide.count("_Aucun élément identifié._")))
check("sans item écarté, pas de section « à vérifier »", "À vérifier" not in texte_vide)

print("\n== chargement et découpage ==")
src = tmp / "reunion_transcript.json"
src.write_text(json.dumps([
    {"start": 0, "end": 10, "speaker": "Roland", "text": "a", "suspect": True,
     "suspect_reason": "x", "overlap_share": 0.3},
    {"start": 10, "end": 20, "speaker": "Élodie", "text": "b"},
], ensure_ascii=False), encoding="utf-8")
blocks = load_blocks(src)
check("les indicateurs du pipeline sont repris", blocks[0]["douteux"] and blocks[0]["chevauchement"] == 0.3,
      str(blocks[0]))
check("leur absence vaut « rien à signaler »",
      blocks[1]["douteux"] is False and blocks[1]["chevauchement"] == 0.0, str(blocks[1]))

gros = [{"debut": i, "fin": i + 1, "speaker": "X", "text": "mot " * 100,
         "douteux": False, "chevauchement": 0} for i in range(10)]
tranches = chunk_blocks(gros, 250)
check("le découpage respecte la taille demandée",
      all(sum(len(b["text"].split()) for b in t) <= 250 for t in tranches),
      str([sum(len(b["text"].split()) for b in t) for t in tranches]))
check("et ne fabrique pas de tranches inutilement petites",
      len(tranches) == 5, str([len(t) for t in tranches]))
check("aucun bloc n'est perdu au découpage", sum(len(t) for t in tranches) == 10)

print("\n== synthèse d'ouverture ==")

# La synthèse a une règle simple — de la prose, sans horodatage — et le
# modèle la transgresse de trois façons prévisibles. Ces tests fixent le
# rattrapage, parce que redemander coûterait des minutes pour un résultat
# tout aussi incertain.
t = nettoyer_synthese("La séance a porté sur le calendrier [00:12:30] et le budget.")
check("les horodatages entre crochets disparaissent", "00:12:30" not in t and "[" not in t, t)

t = nettoyer_synthese("Roland propose `01:02:03` de partir du terrain.")
check("ceux entre accents graves aussi", "01:02:03" not in t and "`" not in t, t)

t = nettoyer_synthese("Le point a été tranché à 14:05 sans opposition.")
check("et les horodatages nus", "14:05" not in t, t)

t = nettoyer_synthese("- Premier point.\n- Deuxième point.")
check("les puces redeviennent de la prose continue",
      t == "Premier point. Deuxième point.", repr(t))

t = nettoyer_synthese("Voici la synthèse :\nLa séance a été brève.")
check("le préambule est retiré", t == "La séance a été brève.", repr(t))

t = nettoyer_synthese("## Synthèse\nLa séance a été brève.")
check("les titres parasites aussi", t == "Synthèse La séance a été brève.", repr(t))

t = nettoyer_synthese("Une   phrase    espacée.\n\n\nPuis une autre.")
check("les espaces et lignes vides sont normalisés",
      t == "Une phrase espacée. Puis une autre.", repr(t))

check("une réponse vide reste vide", nettoyer_synthese("   \n\n  ") == "")

t = nettoyer_synthese("Le budget de 2026 atteint 12 500 euros pour 3 ateliers.")
check("les nombres ordinaires ne sont pas pris pour des horodatages",
      "12 500" in t and "2026" in t and "3 ateliers" in t, t)

print("\n== le markdown avec et sans synthèse ==")
md_s = tmp / "avec_synthese.md"
ecrire_markdown("reunion", resultat, ecartes, CATEGORIES, NOTES, md_s,
                "La séance a surtout porté sur la méthode.")
texte_s = md_s.read_text(encoding="utf-8")
check("la synthèse ouvre le document",
      texte_s.index("## En bref") < texte_s.index("## Positions"), "ordre des sections")
check("son texte y figure", "surtout porté sur la méthode" in texte_s)

md_ns = tmp / "sans_synthese.md"
ecrire_markdown("reunion", resultat, ecartes, CATEGORIES, NOTES, md_ns)
check("sans synthèse, pas de section « En bref »", "## En bref" not in md_ns.read_text(encoding="utf-8"))

print("\n== lecture du flux Ollama ==")

def _flux(*objets):
    return [json.dumps(o).encode("utf-8") for o in objets]

brut = lire_flux(_flux(
    {"response": '{"notes": ', "done": False},
    {"response": '[]}', "done": False},
    {"response": "", "done": True},
))
check("les fragments sont recollés à l'identique", brut == '{"notes": []}', repr(brut))

brut = lire_flux(_flux({"response": "a"}, {"response": "b"}) + [b"", b"   "]
                 + _flux({"response": "c", "done": True}))
check("les lignes vides sont ignorées", brut == "abc", repr(brut))

brut = lire_flux([b'{"response": "a"}', b'ceci n est pas du json',
                  b'{"response": "b", "done": true}'])
check("une ligne illisible n'interrompt pas la lecture", brut == "ab", repr(brut))

brut = lire_flux(_flux({"response": "avant", "done": True}, {"response": "apres"}))
check("rien n'est lu après la fin annoncée", brut == "avant", repr(brut))

try:
    lire_flux(_flux({"error": "model 'x' not found, try pulling it first"}))
    check("un modèle absent arrête le script", False, "aucune sortie")
except SystemExit as exc:
    check("un modèle absent arrête le script avec un message clair",
          "not found" in str(exc), str(exc))

# L'horloge est injectée : le test vérifie le compte rendu d'attente sans
# attendre, ce qui serait le meilleur moyen de ne jamais le tester.
faux_temps = iter([0.0, 0.0, 6.0, 12.0, 12.0, 18.0, 18.0])
lignes = _flux({"response": "x" * 10}, {"response": "y" * 10}, {"response": "", "done": True})
brut = lire_flux(lignes, etiquette="tranche 1/3", horloge=lambda: next(faux_temps))
check("le flux reste correct même avec compte rendu", brut == "x" * 10 + "y" * 10, repr(brut[:5]))

print("\n== grilles de lecture ==")
check("la grille analytique est le défaut", parse_categories(None, "analytique") is GRILLE_ANALYTIQUE)
check("la grille descriptive reste accessible",
      parse_categories(None, "descriptive") is GRILLE_DESCRIPTIVE)
check("les catégories sur mesure l'emportent",
      parse_categories("a:A;b:B", "analytique") == {"a": "A", "b": "B"})
check("une chaîne de catégories vide retombe sur la grille",
      parse_categories(";;", "descriptive") is GRILLE_DESCRIPTIVE)

print("\nRÉSULTAT :", "tout est vert" if ok else "DES TESTS ÉCHOUENT")
sys.exit(0 if ok else 1)
