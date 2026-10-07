# Logos d'origine

Fichiers sources des signatures institutionnelles, à pleine résolution.
Ils ne sont **pas** compilés dans l'application : celle-ci n'utilise que les
versions rééchantillonnées du catalogue `app/TranscriptionTableRonde/Assets.xcassets/`.

Ils sont conservés ici pour pouvoir régénérer ces versions si une hauteur
d'affichage change, ou si un écran de densité supérieure l'exige — un
rééchantillonnage reparti de la pleine résolution donne un résultat net,
là où agrandir une vignette déjà réduite ne donnerait que du flou.

| Fichier               | Composition                        | Usage dans l'app        |
|-----------------------|------------------------------------|-------------------------|
| `ENSCI_bleu.png`      | ENSCi / LES ATELIERS, bleu         | mode clair              |
| `ENSCI_blanc.png`     | idem, blanc                        | mode sombre             |
| `CRD_noir.png`        | Centre de Recherche en Design, 3 lignes, noir  | mode clair  |
| `CRD_blanc.png`       | idem, blanc                        | mode sombre             |

Les deux versions du CRD ont la même composition et les mêmes dimensions
(779 × 398 pixels d'encre) : silhouettes identiques, seule la couleur change.

Hauteurs d'affichage retenues, calibrées à l'œil et non géométriquement
(voir `SignaturesView` dans `AboutView.swift`) : ENSCi 40 pt, CRD 44 pt,
ENS Paris-Saclay 32 pt, Sepsis Center 44 pt.
