# Lexique produit — SignalQuest iOS

Un seul mot par idée, dans toute l'app, en français et en anglais. À relire avant
d'écrire un libellé ; les passes écran par écran (Lot 4) s'y conforment. Les
termes techniques restants s'expliquent par un ⓘ (`SQInfoButton`) et dans
Profil › Aide et glossaire (`SQTerm`).

## Ton

- **Tutoiement partout** : « Autour de toi », « Ta position », « Reconnecte-toi ».
  Jamais « vous », y compris dans les notifications, les erreurs et les pannes.
- Phrases courtes et concrètes. Le terme simple d'abord, le sigle ensuite entre
  parenthèses : « Puissance du signal (RSRP) ».
- Pas de mot technique brut à l'écran : ni `rawValue`, ni « Backend », ni « API »,
  ni nom de bibliothèque (« LiveKit », « BBR/CUBIC », « POP LibreSpeed »). Le détail
  technique va dans le diagnostic, pas dans le message.

## Mesures

| Idée | Français | Anglais | À ne plus écrire |
|---|---|---|---|
| Débit descendant | Réception | Download | Téléchargement, DL, Download (en français) |
| Débit montant | Envoi | Upload | Téléversement, UL, Upload (en français) |
| Aller-retour | Latence | Latency | Ping (sauf entre parenthèses : « Latence (ping) ») |
| Variation de latence | Gigue | Jitter | Jitter (en français) |
| Données perdues | Perte de paquets | Packet loss | Loss |
| Serveur du speedtest | Serveur de mesure | Test server | POP, nœud |
| Un test de débit | Mesure, speedtest | Measurement, speedtest | Speed Test, test de vitesse |

Unités (`SQUnits`) : « 64,3 Mbit/s », « 1,2 Gbit/s », « 18 ms » en français ;
« 64.3 Mbps », « 1.2 Gbps » en anglais. Une décimale sous 100 Mbit/s, aucune
au-delà. Bandes : « n78 » en 5G, « B20 » en 4G.

## Parcours et contributions

| Idée | Français | Anglais | Remarque |
|---|---|---|---|
| Speedtests automatiques pendant un trajet (iOS) | Drive Test | Drive Test | « Trajet » désigne le parcours suivi, pas la fonction |
| Relevé radio continu (Android) | Session de couverture | Coverage session | Toujours préciser qu'elle vient de l'app Android |
| Liste des sessions | Mes enregistrements de trajet | My trip recordings | |
| Journal radio synchronisé (Android) | Logs antennes | Antenna logs | |
| Relier une cellule à une antenne | Identification | Identification | |
| Confirmer une identification | Validation | Validation | |
| Récompense du jeu | points | points | Réservé au jeu : jamais « pts » pour autre chose |
| Zone jamais mesurée (Territoires) | Zone inexplorée | Unexplored area | « Zone blanche » = sans couverture mobile |

## Qualité

Paliers (`SQQualityScale`) : Exceptionnel, Excellent, Très bon, Bon, Moyen, Lent,
Très lent pour le débit ; Excellent, Bon, Moyen, Faible, Très faible, Inconnu pour
le signal. Mêmes seuils et mêmes couleurs que la carte, le web et Android.
