#!/usr/bin/env python3
"""
Résumé structuré d'un transcript (table ronde / atelier) via un LLM local
(Ollama, aucune donnée envoyée en ligne).

Entrée : un fichier *_final.txt (transcript renommé) ou *_transcript.json
(produit par transcribe_diarize.py, éventuellement corrigé dans la fenêtre
de vérification).

POURQUOI CETTE VERSION DIFFÈRE DE LA PRÉCÉDENTE
-----------------------------------------------
L'ancienne chaîne résumait chaque tranche en prose, puis comprimait
l'ensemble à une à trois phrases par catégorie. Un résumé de résumé, puis
une compression : tout ce qui était nuancé disparaissait en route, et le
résultat ne pouvait pas être vérifié puisque rien ne pointait vers
l'enregistrement. Trois changements répondent à cela.

1. DES NOTES PLUTÔT QUE DE LA PROSE. La première passe ne rédige pas, elle
   relève : une liste de notes typées (position défendue, désaccord,
   question restée ouverte, décision, action…), chacune avec son
   horodatage et le ou les locuteurs concernés. Un petit modèle s'en sort
   bien mieux à relever qu'à résumer, et la seconde passe a dès lors des
   prises pour ranger plutôt qu'à reparaphraser un texte déjà appauvri.

2. CHAQUE ITEM CITE SES SOURCES, ET LA VÉRIFICATION EST MÉCANIQUE. La
   seconde passe doit citer, pour chaque item produit, les identifiants des
   notes dont il découle. Ces citations sont résolues par le programme, pas
   par le modèle : un item qui ne cite rien, ou qui cite un identifiant
   inexistant, est écarté vers une section « à vérifier » au lieu d'être
   affirmé. C'est ce qui attrape les contresens — un modèle qui invente
   cite mal — sans coûter un seul appel supplémentaire.

3. L'INCERTITUDE DE LA TRANSCRIPTION REMONTE JUSQU'AU RÉSUMÉ. Les segments
   signalés par le pipeline (parole superposée, passage douteux) sont
   connus ; un item qui s'appuie dessus le dit, au lieu de présenter comme
   acquis ce qui repose sur un passage où deux personnes parlaient en même
   temps.

Sorties, dans le même dossier que l'entrée :
    <basename>_resume.json  — structuré, avec horodatages et citations
    <basename>_resume.md    — lisible, une section par catégorie

Utilisation :
    python3 summarize.py --input sortie/reunion_transcript.json
    python3 summarize.py --input sortie/reunion_final.txt --model mistral
    python3 summarize.py --input sortie/reunion_final.txt --grille descriptive
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# Grille analytique par défaut. Les catégories descriptives classiques
# demandent « ce qui a été dit » ; celles-ci demandent ce qui ne se lit pas
# directement dans le transcript — les désaccords laissés ouverts, les
# questions sans réponse, les mots que chacun emploie dans son propre sens.
# C'est là que se trouve la profondeur qui manquait, et ce n'est pas une
# affaire de modèle : l'ancienne grille ne la demandait pas.
GRILLE_ANALYTIQUE = {
    "positions": "Positions défendues, et par qui",
    "desaccords": "Désaccords et tensions non résolus",
    "questions_ouvertes": "Questions restées sans réponse",
    "decisions": "Décisions prises",
    "actions": "Actions à mener",
    "difficultes": "Difficultés mises en avant",
    "propositions": "Propositions de développement",
    "implications": "Implications techniques et financières",
    "termes": "Termes employés dans des sens différents selon les participants",
    "bascules": "Moments où la discussion change de nature",
}

# L'ancienne grille, conservée telle quelle : les résumés déjà produits
# restent comparables, et elle reste pertinente pour un compte rendu
# strictement factuel.
GRILLE_DESCRIPTIVE = {
    "etat_de_la_recherche": "État de la recherche",
    "questions": "Questions posées",
    "reponses": "Réponses apportées",
    "difficultes": "Difficultés mises en avant",
    "propositions_developpement": "Propositions de développement",
    "implications_techniques": "Implications techniques",
    "implications_financieres": "Implications financières",
    "autres_elements": "Autres éléments pertinents",
}

GRILLES = {"analytique": GRILLE_ANALYTIQUE, "descriptive": GRILLE_DESCRIPTIVE}

TYPES_DE_NOTE = [
    "position", "desaccord", "question", "reponse", "decision",
    "action", "difficulte", "proposition", "terme", "bascule", "fait",
]

TIMESTAMP_HEADER_RE = re.compile(r"^\[(\d{2}:\d{2}:\d{2}) - (\d{2}:\d{2}:\d{2})\] (.+)$")


def fmt_ts(seconds: float) -> str:
    seconds = max(0.0, float(seconds))
    return f"{int(seconds // 3600):02d}:{int((seconds % 3600) // 60):02d}:{int(seconds % 60):02d}"


def parse_ts(texte: str) -> float:
    parties = str(texte).strip().split(":")
    try:
        valeurs = [float(p) for p in parties]
    except ValueError:
        return 0.0
    total = 0.0
    for valeur in valeurs:
        total = total * 60 + valeur
    return total


def parse_categories(arg: str | None, grille: str) -> dict[str, str]:
    if not arg:
        return GRILLES.get(grille, GRILLE_ANALYTIQUE)
    result: dict[str, str] = {}
    for part in arg.split(";"):
        part = part.strip()
        if not part or ":" not in part:
            continue
        slug, title = part.split(":", 1)
        slug, title = slug.strip(), title.strip()
        if slug and title:
            result[slug] = title
    return result or GRILLES.get(grille, GRILLE_ANALYTIQUE)


def load_blocks(input_path: Path) -> list[dict]:
    """Charge le transcript en blocs uniformes.

    Les indicateurs de fiabilité produits par le pipeline sont conservés
    quand ils existent : c'est eux qui permettront de dire qu'un point du
    résumé repose sur un passage douteux.
    """
    if input_path.suffix == ".json":
        donnees = json.loads(input_path.read_text(encoding="utf-8"))
        if isinstance(donnees, dict):
            donnees = donnees.get("segments") or donnees.get("transcript") or []
        return [
            {
                "debut": float(seg.get("start") or 0),
                "fin": float(seg.get("end") or 0),
                "speaker": seg.get("speaker") or "INCONNU",
                "text": (seg.get("text") or "").strip(),
                "douteux": bool(seg.get("suspect")),
                "chevauchement": float(seg.get("overlap_share") or 0),
            }
            for seg in donnees
        ]

    blocks = []
    for raw_block in input_path.read_text(encoding="utf-8").strip().split("\n\n"):
        lignes = raw_block.strip().split("\n", 1)
        if len(lignes) != 2:
            continue
        entete, texte = lignes
        match = TIMESTAMP_HEADER_RE.match(entete.strip())
        if not match:
            continue
        debut, fin, speaker = match.groups()
        blocks.append({
            "debut": parse_ts(debut), "fin": parse_ts(fin),
            "speaker": speaker, "text": texte.strip(),
            "douteux": False, "chevauchement": 0.0,
        })
    return blocks


def chunk_blocks(blocks: list[dict], chunk_words: int) -> list[list[dict]]:
    """Regroupe les blocs consécutifs en tranches, sans jamais couper un bloc."""
    chunks: list[list[dict]] = []
    current: list[dict] = []
    mots = 0
    for block in blocks:
        n = len(block["text"].split())
        if current and mots + n > chunk_words:
            chunks.append(current)
            current, mots = [], 0
        current.append(block)
        mots += n
    if current:
        chunks.append(current)
    return chunks


def lire_flux(lignes, etiquette: str | None = None, intervalle: float = 5.0,
              horloge=time.time) -> str:
    """Assemble une réponse Ollama reçue en flux, en rendant compte de l'attente.

    Un modèle de 24 milliards de paramètres met plusieurs minutes par tranche.
    Sans retour pendant ce temps, la console paraît figée et on ne sait pas
    s'il faut attendre ou interrompre — c'est exactement ce que produisait la
    version précédente, qui n'imprimait qu'une fois l'appel terminé. On lit
    donc la réponse au fil de l'eau et on signe de vie au plus toutes les
    `intervalle` secondes.

    `horloge` est injectable pour que les tests n'aient pas à attendre.
    """
    morceaux: list[str] = []
    debut = horloge()
    dernier = debut
    for ligne in lignes:
        if isinstance(ligne, bytes):
            ligne = ligne.decode("utf-8", errors="replace")
        ligne = ligne.strip()
        if not ligne:
            continue
        try:
            donnees = json.loads(ligne)
        except json.JSONDecodeError:
            continue
        if not isinstance(donnees, dict):
            continue
        # Ollama signale ainsi un modèle absent ou un paramètre refusé. Sans
        # ce test, l'erreur ressortait plus loin sous la forme trompeuse
        # d'une réponse vide, donc d'un « aucune note relevée ».
        if donnees.get("error"):
            sys.exit(f"Erreur renvoyée par Ollama : {donnees['error']}")
        morceau = donnees.get("response")
        if morceau:
            morceaux.append(morceau)
        maintenant = horloge()
        if etiquette and (maintenant - dernier) >= intervalle and not donnees.get("done"):
            dernier = maintenant
            caracteres = sum(len(m) for m in morceaux)
            print(f"      {etiquette} — {caracteres} caractères écrits "
                  f"en {maintenant - debut:.0f}s", flush=True)
        if donnees.get("done"):
            break
    return "".join(morceaux)


def call_ollama(prompt: str, model: str, ollama_url: str, json_mode: bool,
                num_ctx: int, temperature: float, etiquette: str | None = None) -> str:
    payload = json.dumps({
        "model": model,
        "prompt": prompt,
        **({"format": "json"} if json_mode else {}),
        # En flux : c'est ce qui permet de rendre compte de l'attente. La
        # réponse est rassemblée à l'identique par lire_flux.
        "stream": True,
        "options": {"num_ctx": num_ctx, "temperature": temperature},
    }).encode("utf-8")
    request = urllib.request.Request(
        f"{ollama_url}/api/generate", data=payload,
        headers={"Content-Type": "application/json"}, method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=1800) as response:
            return lire_flux(response, etiquette)
    except urllib.error.URLError as exc:
        sys.exit(
            f"Erreur : impossible de contacter Ollama sur {ollama_url} ({exc}).\n"
            "Vérifiez qu'Ollama est lancé (ouvrez l'app Ollama, ou lancez "
            "'ollama serve' dans un terminal) et que le modèle est bien "
            f"téléchargé ('ollama pull {model}')."
        )


# --- Passe 1 : relevé de notes -------------------------------------------

def _bloc_en_ligne(block: dict) -> str:
    return f"[{fmt_ts(block['debut'])}] {block['speaker']} : {block['text']}"


def _contexte(context: str | None) -> str:
    if not context:
        return ""
    return (
        "Contexte de cette réunion (sujet, participants, organismes, termes "
        "techniques) — sers-t'en pour interpréter correctement les noms propres "
        "et les termes spécifiques, y compris quand ils semblent mal "
        f"transcrits :\n{context}\n\n"
    )


def prompt_notes(chunk_text: str, context: str | None) -> str:
    types = ", ".join(TYPES_DE_NOTE)
    return f"""{_contexte(context)}Voici un extrait de la transcription d'une réunion ou d'une table ronde. Chaque ligne commence par un horodatage et le nom du locuteur.

---
{chunk_text}
---

Relève les éléments saillants de cet extrait sous forme de notes. Ne rédige pas de résumé continu : produis une liste de notes indépendantes.

Pour chaque note :
- "type" : un seul mot parmi {types}
- "locuteurs" : la liste des noms de locuteurs concernés, exactement tels qu'ils apparaissent dans l'extrait
- "t" : l'horodatage hh:mm:ss de la ligne d'où provient la note
- "enonce" : une phrase complète en français, avec tes propres mots, disant ce qui a été dit ou décidé

Consignes importantes :
- Attribue : « Untel soutient que… », « Untel objecte que… ». Ne fonds pas les participants dans un « on » ou un « les participants » collectif, c'est précisément ce qui fait perdre la substance d'une table ronde.
- Relève les désaccords et les questions laissées sans réponse : ce sont des notes à part entière, pas des imperfections à lisser.
- N'invente rien. Si l'extrait est confus ou inaudible, ne produis pas de note plutôt que de deviner.
- Entre 5 et 20 notes selon la densité de l'extrait.

Réponds UNIQUEMENT avec un objet JSON de la forme :
{{"notes": [{{"type": "...", "locuteurs": ["..."], "t": "hh:mm:ss", "enonce": "..."}}]}}"""


def _bornes(chunk: list[dict]) -> tuple[float, float]:
    return chunk[0]["debut"], chunk[-1]["fin"]


def parse_notes(brut: str, chunk: list[dict], prefixe: str) -> list[dict]:
    """Valide et normalise les notes d'une tranche.

    Trois nettoyages qui comptent : l'horodatage est ramené dans les bornes
    de la tranche (un modèle en invente volontiers un hors sujet), le type
    est ramené dans la liste connue, et les locuteurs sont confrontés à ceux
    qui parlent réellement dans la tranche. Un nom inventé est écarté : s'il
    passait, il se propagerait jusqu'au résumé final avec l'apparence d'un
    fait.
    """
    try:
        donnees = json.loads(brut)
    except json.JSONDecodeError:
        return []
    if isinstance(donnees, list):
        brutes = donnees
    elif isinstance(donnees, dict):
        brutes = donnees.get("notes")
        if not isinstance(brutes, list):
            brutes = next((v for v in donnees.values() if isinstance(v, list)), [])
    else:
        return []

    debut_chunk, fin_chunk = _bornes(chunk)
    locuteurs_reels = {b["speaker"] for b in chunk}
    notes = []
    for brute in brutes:
        if not isinstance(brute, dict):
            continue
        enonce = str(brute.get("enonce") or "").strip()
        if not enonce:
            continue
        t = parse_ts(brute.get("t") or "")
        if not (debut_chunk <= t <= fin_chunk):
            t = debut_chunk
        type_ = str(brute.get("type") or "fait").strip().lower()
        if type_ not in TYPES_DE_NOTE:
            type_ = "fait"
        bruts_locuteurs = brute.get("locuteurs")
        if isinstance(bruts_locuteurs, str):
            bruts_locuteurs = [bruts_locuteurs]
        locuteurs = [str(n).strip() for n in (bruts_locuteurs or []) if str(n).strip()]
        locuteurs = [n for n in locuteurs if n in locuteurs_reels]
        notes.append({
            "id": f"{prefixe}{len(notes) + 1}",
            "type": type_,
            "locuteurs": locuteurs,
            "t": round(t, 1),
            "enonce": enonce,
        })
    return notes


def fiabilite(note: dict, blocks: list[dict]) -> str | None:
    """Dit si la note repose sur un passage que le pipeline a signalé.

    La note porte un horodatage ; on retrouve le bloc qui le contient et on
    regarde ce qu'on sait de lui. Faire remonter cette incertitude jusqu'au
    résumé est le seul moyen d'éviter qu'un point affirmé noir sur blanc
    repose en réalité sur un passage où deux personnes parlaient ensemble.
    """
    for block in blocks:
        if block["debut"] <= note["t"] <= block["fin"]:
            if block.get("chevauchement", 0) > 0.15:
                return "repose sur un passage où plusieurs personnes parlent en même temps"
            if block.get("douteux"):
                return "repose sur un passage que la transcription signale comme douteux"
            return None
    return None


# --- Passe 2 : rangement dans les catégories ------------------------------

def prompt_rangement(notes: list[dict], categories: dict[str, str],
                     context: str | None) -> str:
    lignes = "\n".join(
        f"{n['id']} [{fmt_ts(n['t'])}] ({n['type']}"
        + (f", {', '.join(n['locuteurs'])}" if n["locuteurs"] else "")
        + f") {n['enonce']}"
        for n in notes
    )
    description = "\n".join(f"- {slug} : {titre}" for slug, titre in categories.items())
    cles = ", ".join(f'"{slug}"' for slug in categories)
    return f"""{_contexte(context)}Voici les notes relevées sur l'intégralité d'un enregistrement de réunion. Chaque note commence par son identifiant, son horodatage, son type et les locuteurs concernés.

---
{lignes}
---

Range ce contenu dans les catégories suivantes :
{description}

Pour chaque catégorie concernée, écris de 1 à 6 items. Chaque item est un objet :
- "texte" : une à trois phrases complètes en français, synthétisant les notes concernées avec tes propres mots. Nomme les personnes quand la note les nomme.
- "notes" : la liste des identifiants de notes (par exemple "t1n4") dont cet item découle. Au moins un, et uniquement des identifiants présents ci-dessus.

Consignes importantes :
- Chaque item DOIT citer les identifiants dont il découle. Un item sans citation valable sera écarté : ces identifiants sont vérifiés par un programme, pas relus par un humain.
- N'invente aucun identifiant et n'en déduis aucun : recopie ceux de la liste.
- Laisse une catégorie vide si rien ne la concerne. N'écris jamais de phrase expliquant qu'une catégorie est vide.
- Un désaccord doit rester un désaccord : ne le résous pas en une position commune que personne n'a défendue.

Réponds UNIQUEMENT avec un objet JSON ayant exactement ces clés : {cles}. Chaque valeur est une liste d'items de la forme {{"texte": "...", "notes": ["..."]}}."""


# Repérer une phrase de remplissage suppose de distinguer deux négations qui
# se ressemblent. « Cette catégorie n'est pas mentionnée dans l'extrait » parle
# du formulaire ; « Le budget n'a pas été abordé » parle de la réunion, et
# c'est un constat de premier intérêt dans un compte rendu — l'écarter serait
# supprimer précisément ce qu'on cherche. Un simple filtre sur les tournures
# négatives jetait les deux (attrapé par les tests).
#
# D'où la double condition : la phrase doit à la fois nier quelque chose ET
# désigner l'un des objets du dispositif — la catégorie, l'extrait, le
# transcript. Une phrase qui ne parle que du contenu de la réunion passe.
_META = (
    "catégorie", "cette rubrique", "cette section", "dans l'extrait",
    "dans cet extrait", "transcript", "les notes fournies", "ce champ",
)
_NEGATIONS = ("pas ", "aucun", "aucune", "rien ", "non concern", "sans objet", "n'y a")


def _est_remplissage(texte: str) -> bool:
    """Filet de sécurité : malgré la consigne, un modèle commente parfois
    l'absence au lieu de laisser une liste vide."""
    bas = texte.lower()
    return (any(m in bas for m in _META) and any(n in bas for n in _NEGATIONS))


def ranger(brut: str, categories: dict[str, str], notes: list[dict],
           blocks: list[dict]) -> tuple[dict, list[dict]]:
    """Résout les citations et sépare le solide de l'invérifiable.

    Retourne (résultat par catégorie, items écartés). Un item est écarté
    quand il ne cite aucune note existante : c'est la signature d'une
    affirmation fabriquée, et la vérification est ici mécanique — aucun
    jugement de modèle n'intervient.
    """
    try:
        donnees = json.loads(brut)
    except json.JSONDecodeError:
        return {}, []
    if not isinstance(donnees, dict):
        return {}, []

    index = {n["id"]: n for n in notes}
    resultat: dict[str, list[dict]] = {slug: [] for slug in categories}
    ecartes: list[dict] = []

    for slug in categories:
        valeurs = donnees.get(slug)
        if not isinstance(valeurs, list):
            continue
        for valeur in valeurs:
            # Tolérance de forme : un modèle renvoie parfois une simple
            # chaîne au lieu de l'objet attendu. On ne la jette pas, on la
            # traite comme un item sans citation — donc à vérifier.
            if isinstance(valeur, str):
                item = {"texte": valeur.strip(), "notes": []}
            elif isinstance(valeur, dict):
                item = {
                    "texte": str(valeur.get("texte") or "").strip(),
                    "notes": [str(x).strip() for x in (valeur.get("notes") or [])
                              if str(x).strip()],
                }
            else:
                continue
            if not item["texte"] or _est_remplissage(item["texte"]):
                continue

            citees = [index[i] for i in item["notes"] if i in index]
            if not citees:
                ecartes.append({"categorie": slug, "texte": item["texte"]})
                continue

            reserves = sorted({r for r in (fiabilite(n, blocks) for n in citees) if r})
            resultat[slug].append({
                "texte": item["texte"],
                "notes": [n["id"] for n in citees],
                "debut": min(n["t"] for n in citees),
                "horodatages": sorted({fmt_ts(n["t"]) for n in citees}),
                "locuteurs": sorted({l for n in citees for l in n["locuteurs"]}),
                "reserves": reserves,
            })

    for items in resultat.values():
        items.sort(key=lambda i: i["debut"])
    return resultat, ecartes


# --- Passe 3 : synthèse d'ouverture ---------------------------------------

# Horodatages sous toutes les formes que le modèle peut produire malgré la
# consigne : entre crochets, entre accents graves, ou nus au fil du texte.
_HORODATAGE = re.compile(r"[`\[(]?\b\d{1,2}:\d{2}(?::\d{2})?\b[`\])]?")


def prompt_synthese(resultat: dict, categories: dict[str, str], context: str | None) -> str:
    lignes = []
    for slug, titre in categories.items():
        items = resultat.get(slug, [])
        if not items:
            continue
        lignes.append(f"{titre} :")
        for item in items:
            qui = f" ({', '.join(item['locuteurs'])})" if item["locuteurs"] else ""
            lignes.append(f"  - {item['texte']}{qui}")
    corps = "\n".join(lignes)

    return f"""{_contexte(context)}Voici le compte rendu structuré d'une réunion, rangé par catégories.

---
{corps}
---

Rédige une synthèse d'ouverture de 2 à 10 lignes, destinée à quelqu'un qui n'a pas assisté à la séance et qui veut savoir en trente secondes ce qui s'y est joué.

Consignes :
- En prose continue. Pas de liste, pas de puces, pas de titres.
- Aucun horodatage, aucune référence à des numéros de notes ou de parties.
- Dis ce qui s'est décidé, ce qui reste ouvert, et où se situent les désaccords s'il y en a. Nomme les personnes quand une position leur revient nettement.
- Ne va pas au-delà de ce que contient le compte rendu ci-dessus : il a déjà été vérifié, tout ajout ne le serait pas.

Réponds uniquement par le texte de la synthèse, sans préambule ni commentaire."""


def nettoyer_synthese(brut: str) -> str:
    """Ramène la réponse à de la prose, quoi qu'ait fait le modèle.

    Trois nettoyages, chacun pour une désobéissance observée : les
    horodatages reviennent par habitude alors qu'ils n'ont pas leur place
    ici, les puces resurgissent parce que tout le reste du document en
    comporte, et un préambule du genre « Voici la synthèse : » s'ajoute
    volontiers. Mieux vaut le corriger que le redemander : une seconde passe
    coûterait des minutes pour un résultat tout aussi incertain.
    """
    texte = _HORODATAGE.sub("", brut)
    lignes = []
    for ligne in texte.splitlines():
        ligne = ligne.strip()
        if not ligne:
            continue
        ligne = re.sub(r"^[-\u2013\u2014*\u2022]\s*", "", ligne)
        ligne = re.sub(r"^#{1,6}\s*", "", ligne)
        if re.fullmatch(r"(voici|voilà)\s+la\s+synthèse\s*:?", ligne, flags=re.IGNORECASE):
            continue
        lignes.append(ligne)
    texte = " ".join(lignes)
    texte = re.sub(r"\s{2,}", " ", texte)
    return texte.strip()


# --- Sorties ---------------------------------------------------------------

def ecrire_markdown(basename: str, resultat: dict, ecartes: list[dict],
                    categories: dict[str, str], notes: list[dict],
                    md_path: Path, synthese: str | None = None) -> None:
    lignes = [f"# Résumé structuré — {basename}", ""]

    # La synthèse ouvre le document, avant toute mécanique de sources : elle
    # s'adresse à qui veut savoir en trente secondes ce qui s'est joué, et
    # cette personne-là ne lira pas la suite.
    if synthese:
        lignes.append("## En bref")
        lignes.append("")
        lignes.append(synthese)
        lignes.append("")
        lignes.append("---")
        lignes.append("")

    lignes.append(
        "Chaque point ci-dessous porte l'horodatage des passages dont il "
        "découle : ouvrez la session dans l'application et écoutez-les pour "
        "vérifier, corriger ou préciser."
    )
    lignes.append("")

    for slug, titre in categories.items():
        lignes.append(f"## {titre}")
        items = resultat.get(slug, [])
        if not items:
            lignes.append("_Aucun élément identifié._")
            lignes.append("")
            continue
        for item in items:
            horodatages = " ".join(f"`{h}`" for h in item["horodatages"])
            qui = f" — {', '.join(item['locuteurs'])}" if item["locuteurs"] else ""
            lignes.append(f"- {item['texte']}{qui}  \n  {horodatages}")
            for reserve in item["reserves"]:
                lignes.append(f"  ⚠️ {reserve}")
        lignes.append("")

    if ecartes:
        lignes.append("## À vérifier — points sans source identifiable")
        lignes.append("")
        lignes.append(
            "Ces affirmations ont été produites par le modèle sans qu'il ait pu "
            "citer de passage précis de l'enregistrement. Elles ne sont pas "
            "forcément fausses, mais rien ne les étaye : à confirmer à l'écoute "
            "avant d'en faire état."
        )
        lignes.append("")
        for item in ecartes:
            lignes.append(f"- ({categories.get(item['categorie'], item['categorie'])}) {item['texte']}")
        lignes.append("")

    lignes.append("---")
    lignes.append("")
    lignes.append(f"_{len(notes)} notes relevées sur l'enregistrement._")
    md_path.write_text("\n".join(lignes), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Résumé structuré d'un transcript via Ollama (local)")
    parser.add_argument("--input", required=True, help="Fichier *_final.txt ou *_transcript.json")
    parser.add_argument("--output", default=None, help="Dossier de sortie (défaut : celui de --input)")
    parser.add_argument(
        "--model", default="mistral-small3.2",
        help="Modèle Ollama (défaut : mistral-small3.2, sans numéro de version : "
        "Ollama résout alors vers l'étiquette « latest » réellement installée, au lieu "
        "d'exiger une étiquette précise qui peut manquer sur la machine). Un modèle de "
        "24 à 32 milliards de paramètres lit le français avec beaucoup plus de finesse "
        "qu'un 7B ; repliez-vous sur « mistral » si la mémoire manque.",
    )
    parser.add_argument("--ollama-url", default="http://localhost:11434")
    parser.add_argument(
        "--num-ctx", type=int, default=16384,
        help="Taille de contexte du modèle (défaut : 16384). Plus large = moins de "
        "tranches, donc moins de perte aux jointures.",
    )
    parser.add_argument(
        "--chunk-words", type=int, default=4000,
        help="Taille approximative des tranches, en mots (défaut : 4000)",
    )
    parser.add_argument(
        "--grille", default="analytique", choices=list(GRILLES.keys()),
        help="Grille de lecture (défaut : analytique). « descriptive » reprend les "
        "huit catégories factuelles d'origine.",
    )
    parser.add_argument("--categories", default=None,
                        help='Catégories sur mesure : "slug1:Titre 1;slug2:Titre 2;..."')
    parser.add_argument(
        "--sans-synthese", action="store_true",
        help="Ne pas rédiger la synthèse d'ouverture. Elle coûte un appel au modèle de plus, "
        "soit quelques minutes ; c'est le seul motif de s'en passer.",
    )
    parser.add_argument(
        "--context", default=None,
        help="Contexte de la réunion. Si absent, cherché dans <dossier>/*_contexte.txt.",
    )
    args = parser.parse_args()

    input_path = Path(args.input)
    if not input_path.exists():
        sys.exit(f"Erreur : fichier introuvable : {input_path}")
    if input_path.suffix not in (".txt", ".json"):
        sys.exit("Erreur : --input doit être un fichier *_final.txt ou *_transcript.json")

    categories = parse_categories(args.categories, args.grille)

    context = args.context
    if not context:
        fichiers = list(input_path.parent.glob("*_contexte.txt"))
        if fichiers:
            context = fichiers[0].read_text(encoding="utf-8").strip()
            print(f"Contexte trouvé : {fichiers[0].name}")

    out_dir = Path(args.output) if args.output else input_path.parent
    out_dir.mkdir(parents=True, exist_ok=True)

    basename = input_path.stem
    for suffixe in ("_final", "_transcript"):
        if basename.endswith(suffixe):
            basename = basename[: -len(suffixe)]
            break

    blocks = load_blocks(input_path)
    if not blocks:
        sys.exit(f"Erreur : aucun contenu exploitable trouvé dans {input_path}")

    chunks = chunk_blocks(blocks, args.chunk_words)
    print(f"[1/3] Relevé de notes sur {len(chunks)} tranche(s) avec {args.model}...",
          flush=True)
    print(f"      (comptez plusieurs minutes par tranche avec un modèle de cette "
          f"taille ; l'avancement s'affiche au fil de l'eau)", flush=True)
    notes: list[dict] = []
    for i, chunk in enumerate(chunks, start=1):
        texte = "\n".join(_bloc_en_ligne(b) for b in chunk)
        mots = sum(len(b["text"].split()) for b in chunk)
        print(f"      tranche {i}/{len(chunks)} — {mots} mots, "
              f"{fmt_ts(chunk[0]['debut'])} à {fmt_ts(chunk[-1]['fin'])}…", flush=True)
        t0 = time.time()
        brut = call_ollama(prompt_notes(texte, context), args.model, args.ollama_url,
                           json_mode=True, num_ctx=args.num_ctx, temperature=0.2,
                           etiquette=f"tranche {i}/{len(chunks)}")
        lot = parse_notes(brut, chunk, prefixe=f"t{i}n")
        notes.extend(lot)
        print(f"      tranche {i}/{len(chunks)} — {len(lot)} note(s) "
              f"en {time.time() - t0:.0f}s", flush=True)

    if not notes:
        sys.exit("Erreur : aucune note exploitable n'a pu être relevée. Vérifiez le "
                 "modèle choisi et la taille de contexte (--num-ctx).")

    print(f"[2/3] Rangement de {len(notes)} notes dans {len(categories)} catégories...",
          flush=True)
    brut = call_ollama(prompt_rangement(notes, categories, context), args.model,
                       args.ollama_url, json_mode=True, num_ctx=args.num_ctx,
                       temperature=0.2, etiquette="rangement")
    resultat, ecartes = ranger(brut, categories, notes, blocks)
    if not any(resultat.values()):
        print("      avertissement : rangement inexploitable, nouvelle tentative...")
        brut = call_ollama(
            prompt_rangement(notes, categories, context)
            + "\n\nRappel : réponds uniquement avec le JSON, sans aucun texte autour, "
              "et cite pour chaque item les identifiants de notes dont il découle.",
            args.model, args.ollama_url, json_mode=True, num_ctx=args.num_ctx,
            temperature=0.1)
        resultat, ecartes = ranger(brut, categories, notes, blocks)

    retenus = sum(len(v) for v in resultat.values())
    avec_reserve = sum(1 for v in resultat.values() for i in v if i["reserves"])
    print(f"      {retenus} item(s) retenu(s), {len(ecartes)} écarté(s) faute de source, "
          f"{avec_reserve} assorti(s) d'une réserve sur la transcription")

    synthese = None
    if not args.sans_synthese and retenus:
        print("[3/3] Rédaction de la synthèse d'ouverture...", flush=True)
        # La synthèse part du compte rendu retenu, et non des notes brutes :
        # ce qui a été écarté faute de source ne doit pas revenir par la
        # porte de derrière, sous une forme encore plus affirmative.
        brut_synthese = call_ollama(
            prompt_synthese(resultat, categories, context), args.model, args.ollama_url,
            json_mode=False, num_ctx=args.num_ctx, temperature=0.3, etiquette="synthèse")
        synthese = nettoyer_synthese(brut_synthese) or None
        if synthese:
            print(f"      {len(synthese.split())} mots")
        else:
            print("      avertissement : synthèse vide, le document s'en passera")

    json_path = out_dir / f"{basename}_resume.json"
    json_path.write_text(json.dumps({
        "synthese": synthese,
        "categories": categories,
        "resultat": resultat,
        "a_verifier": ecartes,
        "notes": notes,
    }, ensure_ascii=False, indent=2), encoding="utf-8")

    md_path = out_dir / f"{basename}_resume.md"
    ecrire_markdown(basename, resultat, ecartes, categories, notes, md_path, synthese)

    print("\nTerminé. Fichiers générés :")
    print(f"  - {md_path}   (résumé lisible)")
    print(f"  - {json_path}  (données structurées, notes et citations)")
    print(f"RESUME_MD:{md_path}")
    print(f"RESUME_JSON:{json_path}")


if __name__ == "__main__":
    main()
