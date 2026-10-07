"""
Tests du nettoyage et du diagnostic des défauts de Whisper.

L'enjeu de ces tests est un équilibre, pas une exactitude : un repliage trop
zélé falsifie la parole (quelqu'un a vraiment pu dire « non non non non »),
un repliage trop timide laisse passer les boucles de cent mots. Les cas
ci-dessous bornent les deux côtés.

Lancer depuis le dossier du pipeline : python3 test_qualite_transcription.py
"""
import sys

from qualite_transcription import (
    diagnostiquer, nettoyer_segments, replier_repetitions, taux_compression,
)

ok = True


def check(label, cond, detail=""):
    global ok
    print(("  OK    " if cond else "  ÉCHEC") + f" {label}" + (f"  → {detail}" if detail and not cond else ""))
    if not cond:
        ok = False


print("== repliage des boucles ==")

texte, retires = replier_repetitions("merci " * 40)
check("une boucle de 40 mots est repliée", texte.strip() == "merci merci" and retires == 38,
      f"{texte!r} / {retires}")

texte, retires = replier_repetitions("Bonjour à toutes et à tous.")
check("une phrase ordinaire est intacte", texte == "Bonjour à toutes et à tous." and retires == 0,
      f"{texte!r}")

texte, retires = replier_repetitions("non non non non")
check("« non non non non » n'est pas touché (parole réelle)", retires == 0, f"{texte!r}")

texte, retires = replier_repetitions("je ne sais pas " * 5)
check("une formule répétée 5 fois est repliée",
      texte.strip() == "je ne sais pas je ne sais pas" and retires == 12, f"{texte!r} / {retires}")

texte, retires = replier_repetitions("oui, oui. Oui oui OUI oui, oui.")
check("ponctuation et casse n'empêchent pas la détection", retires > 0, f"{texte!r}")

texte, retires = replier_repetitions("Merci. " * 12)
check("la forme la plus courante d'une boucle Whisper est repliée",
      retires == 10, f"{texte!r} / {retires}")

# Limite assumée, documentée dans _cle : un signe isolé coupe la suite en
# deux moitiés trop courtes. Le segment reste signalé par ailleurs.
texte, retires = replier_repetitions("oui oui oui ! oui oui oui")
check("une boucle coupée par un signe isolé n'est pas repliée (limite connue)",
      retires == 0, f"{texte!r}")

texte, retires = replier_repetitions("Le budget est voté. " + "voilà " * 30 + "Merci à tous.")
check("le texte utile autour d'une boucle est préservé",
      texte.startswith("Le budget est voté.") and texte.endswith("Merci à tous."), f"{texte!r}")

texte, retires = replier_repetitions("")
check("texte vide : rien ne casse", texte == "" and retires == 0)

texte, retires = replier_repetitions("... ... ... ... ... ... ...")
check("une suite de ponctuation seule ne fait pas planter", isinstance(texte, str))

print("\n== taux de compression ==")
check("un texte répétitif se comprime beaucoup", taux_compression("ah " * 200) > 2.4,
      f"{taux_compression('ah ' * 200):.2f}")
check("une phrase ordinaire se comprime peu",
      taux_compression("Nous avons discuté du calendrier et des moyens disponibles.") < 2.4,
      f"{taux_compression('Nous avons discuté du calendrier et des moyens disponibles.'):.2f}")

print("\n== diagnostic d'hallucination ==")

suspect, raison, codes = diagnostiquer(
    {"text": "Merci d'avoir regardé cette vidéo.", "no_speech_prob": 0.92, "avg_logprob": -0.4})
check("texte écrit alors que Whisper ne détecte pas de parole → suspect", suspect, raison)
check("la raison est lisible et chiffrée", "92%" in raison, raison)
check("le code de cause est stable, lui", codes == ["non_parle"], str(codes))

suspect, _, _ = diagnostiquer(
    {"text": "Je reprends le point précédent.", "no_speech_prob": 0.02, "avg_logprob": -0.25})
check("un segment normal n'est pas suspect", not suspect)

suspect, raison, _ = diagnostiquer(
    {"text": "oui", "no_speech_prob": 0.1, "avg_logprob": -1.6})
check("confiance très basse → suspect", suspect, raison)

suspect, _, _ = diagnostiquer({"text": "", "no_speech_prob": 0.99, "avg_logprob": -0.3})
check("un segment vide n'est pas accusé d'halluciner", not suspect)

suspect, raison, _ = diagnostiquer({"text": "ok", "repeats_removed": 57})
check("un repliage important vaut signalement", suspect and "57" in raison, raison)

suspect, raison, codes = diagnostiquer(
    {"text": "Merci d'avoir regardé.", "speech_share": 0.0,
     "no_speech_prob": 0.1, "avg_logprob": -0.3})
check("du texte là où la diarisation n'entend aucune parole → suspect",
      suspect and codes == ["sans_parole"], f"{codes} / {raison}")

suspect, _, _ = diagnostiquer(
    {"text": "D'accord.", "speech_share": 0.12, "no_speech_prob": 0.1, "avg_logprob": -0.3})
check("une courte réplique dans du silence n'est PAS suspecte", not suspect)

print("\n== repliage resserré sur les sorties dégénérées ==")

segments = [{"text": "C'est bon. C'est bon. C'est bon. Oui. Oui. Oui. Oui.",
             "compression_ratio": 3.1, "avg_logprob": -0.5}]
nettoyer_segments(segments)
check("Whisper signale la dégénérescence : les seuils se resserrent",
      segments[0].get("repeats_removed", 0) > 0, segments[0]["text"])

segments = [{"text": "Oui. Oui. Oui. Oui.", "compression_ratio": 1.4, "avg_logprob": -0.3}]
nettoyer_segments(segments)
check("sur un segment sain, une insistance réelle reste intacte",
      "repeats_removed" not in segments[0], segments[0]["text"])

print("\n== traitement d'une liste de segments ==")

segments = [
    {"text": "Bonjour à toutes et à tous.", "no_speech_prob": 0.01, "avg_logprob": -0.2},
    {"text": "voilà " * 25, "no_speech_prob": 0.3, "avg_logprob": -0.9},
    {"text": "Sous-titres réalisés par la communauté.", "no_speech_prob": 0.88, "avg_logprob": -0.5},
]
bilan = nettoyer_segments(segments)
check("un seul segment replié", bilan["segments_replies"] == 1, str(bilan))
check("deux segments suspects", bilan["segments_suspects"] == 2, str(bilan))
check("le premier segment est intact et non marqué",
      segments[0]["text"] == "Bonjour à toutes et à tous." and "suspect" not in segments[0])
check("le segment replié garde le compte", segments[1]["repeats_removed"] == 23,
      str(segments[1].get("repeats_removed")))
check("le segment halluciné porte sa raison", segments[2]["suspect"] is True
      and "pas de parole" in segments[2]["suspect_reason"], segments[2].get("suspect_reason"))
check("et ses codes de cause", segments[2]["suspect_causes"] == ["non_parle"],
      str(segments[2].get("suspect_causes")))

print("\nRÉSULTAT :", "tout est vert" if ok else "DES TESTS ÉCHOUENT")
sys.exit(0 if ok else 1)
