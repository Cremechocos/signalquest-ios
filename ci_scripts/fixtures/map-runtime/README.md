# Recette HTTP de la carte native

Ce serveur Python standard sert uniquement des mesures et sites synthétiques. Il écoute sur `127.0.0.1`, ne proxyfie aucun service et n'enregistre ni cookie, ni jeton, ni corps de requête. Il n'implémente pas l'authentification ou les détails complets des mesures.

Depuis la racine du dépôt :

```sh
python3 ci_scripts/fixtures/map-runtime/map_fixture_server.py --check
python3 ci_scripts/fixtures/map-runtime/map_fixture_server.py --set-scenario baseline
python3 ci_scripts/fixtures/map-runtime/map_fixture_server.py --port 8769
```

Le contrôle vérifie les payloads Python, pas le décodage Swift ou le rendu. Initialiser le scénario avant de démarrer le serveur. L'état et le journal de requêtes restent ignorés par Git. Réserver ce serveur à une campagne à la fois : son scénario est commun aux requêtes.

La grille v2 est centrée sur 45.188 / 5.7129. Pour SFR et les tuiles z12 à z14, `error-one` garde deux mesures dans la tuile réussie et en retire trois dans la tuile centrale en panne. La recette vérifie aussi l'opérateur, le marché, les codes HTTP et les identifiants reçus.

Les tests `MapHTTPRuntimeQATests` exigent `TEST_RUNNER_SQ_MAP_HTTP_QA=1` dans l'environnement de `xcodebuild`, et **les deux réglages de compilation** `SQ_API_BASE_URL=http://127.0.0.1:8769` et `SQ_APP_BASE_URL=http://127.0.0.1:8769`. Des variables de lancement seules ne remplacent pas les URLs compilées. Employer un simulateur réservé et vérifier son identifiant ; aucun compte réel n'est nécessaire.

Avant la recette de panne, démarrer ce simulateur et attendre sa disponibilité. Avec l'app arrêtée, supprimer seulement `Library/Caches/SignalQuestMapCache` et `Library/Caches/SignalQuestTileCache` dans son conteneur. Vérifier le succès de ce prérequis avant le lancement : un cache chaud peut empêcher la panne attendue. Ne pas effacer les données d'un appareil personnel.

Le test utilise les commandes locales `/__qa/scenario` et `/__qa/state`, qui refusent les écritures avec un Origin navigateur ou sans l'en-tête de contrôle. Il lance la carte invitée, sélectionne les couches et SFR, vérifie le maintien partiel, Réessayer, les éléments accessibles et les gestes. Les captures jointes doivent être inspectées pour vérifier le dessin ; un élément d'accessibilité seul ne prouve pas les pixels. Le test d'ouverture de fiche vérifie la sélection locale, pas la disponibilité de l'API de détail absente de cette fixture.

`SQ_MAP_VIEWPORT_QA=1` active un diagnostic local en Debug, borné à 512 événements par instance. Il contient des coordonnées de caméra : conserver seulement des scénarios synthétiques et sélectionner les preuves avant partage. Il est exclu des compilations Release. Le fond Apple Plans reste fourni par MapKit.

La classe couvre aussi le pays initial depuis le GPS, le choix manuel en brouillon, les filtres experts FR/EN et la légende à la taille de texte d’accessibilité maximale. Le cas GPS exige `TEST_RUNNER_SQ_MAP_LOCATION_QA=1`, une localisation simulée Montréal et la permission déjà accordée. Les autres cas cadrent la grille Grenoble. `TEST_RUNNER_SQ_MAP_LANDSCAPE_QA=1` demande le paysage et vérifie les dimensions effectives de l’app ; réserver ce mode à la campagne iPad.

Le scénario de panne sélectionne explicitement les speedtests et désactive les autres couches principales, y compris la couverture. Il contrôle le déplacement sans inertie avant de comparer les distances entre deux mesures encore visibles pendant le pincement. Les helpers font défiler le contenu des filtres et les menus natifs : une option chargée hors écran n’est pas considérée comme une action déjà accessible.

## Profil antenne et origine sélectionnée — recette dédiée

Le mode **opt-in** `--profile-qa` ajoute `profile-origin` sur le port **8770 uniquement**, avec un répertoire d'état séparé obligatoire. Les scénarios existants et le serveur 8769 conservent leur protocole et leurs données. Le serveur ne proxyfie aucune recherche, aucun terrain ni bâtiment. Les coordonnées sont des repères publics de centre-ville ; les sites, altitudes et hauteurs de bâtiments sont entièrement synthétiques.

Préparer puis lancer ce serveur dans une campagne distincte, sans redémarrer celui de 8769 :

```sh
python3 ci_scripts/fixtures/map-runtime/map_fixture_server.py \
  --profile-qa --port 8770 --state-dir /tmp/sq-map-profile-qa \
  --set-scenario profile-origin
python3 ci_scripts/fixtures/map-runtime/map_fixture_server.py \
  --profile-qa --port 8770 --state-dir /tmp/sq-map-profile-qa
```

Le lancement est à effectuer par le responsable de la recette ; la préparation de ces fichiers n'a lancé aucun serveur ni test natif. Le contrôle `--check` comprend maintenant des assertions pures sur les réponses de profils, mais ne prouve ni le décodage Swift ni le rendu.

### Contrat des routes

| Route | Réponse synthétique |
| --- | --- |
| GET `/__qa/profile/places?q=QA%20Grenoble` | `{places:[{id:"qa-place-grenoble",name:"QA Grenoble — Place Grenette",subtitle,latitude:45.1915,longitude:5.7278}]}` |
| GET `/__qa/profile/places?q=QA%20Paris` | `qa-place-paris`, « QA Paris — Champ-de-Mars », 48.85837 / 2.29448 |
| GET `/__qa/profile/places?q=…` avec toute autre valeur | `{places:[]}`, notamment `QA unresolved` ; aucun fallback externe |
| GET `/api/antennas/quick-search?q=QA%20ANTENNE` | Antenne `qa-profile-official-grenoble`, site `QA-OFFICIAL-GRENOBLE`, Orange/4G, 45.188 / 5.7129 |
| GET quick-search avec `QA custom` | Site synthétique `qa-profile-custom-grenoble`, 45.189 / 5.715 ; une suggestion n'est pas une preuve du parcours du marqueur custom |
| GET `/api/android/map/antenna/{id synthétique}` | Détail borné, hauteur 32 m, pas de photo ni mesure ; données inventées de recette |
| POST `/api/rf/terrain` | `{points:[{lat,lon}]}` → `{results:[{elevation}]}` ; 1 à 512 valeurs synthétiques alignées |
| POST `/api/rf/clutter` | Même corps → `{results:[{buildingHeightM,buildingCount}]}` |
| GET `/__qa/profile/state` avec `X-SQ-QA: map-runtime-v1` | Version de protocole 1, compteurs et événements limités à la révision du scénario courant |

Les tuiles/bbox du scénario exposent uniquement ce site officiel et le site custom. Les autres couches sont vides. Les échantillons terrain/clutter doivent rester dans la petite emprise synthétique Grenoble ; une requête Paris→Grenoble est comptée puis rejetée 422. Cela empêche de présenter un résultat fictif plausible si le garde-fou de 30 km laisse passer un appel interdit.

Le géocodage de l'app utilise un **point d'injection DEBUG**, conditionné par `SQ_MAP_PROFILE_QA=1` et les deux URLs compilées exactement égales à `http://127.0.0.1:8770`. Il lit la route `places` ci-dessus et ne se replie pas sur Apple en cas d'échec. **Cette recette vérifie le parcours natif avec recherche synthétique, pas MKLocalSearch.** Le fond MapKit peut continuer à provenir d'Apple.

Les événements de ce mode ne contiennent ni recherches libres, ni corps POST, ni coordonnées soumises, ni cookies/jetons. Ils gardent seulement les noms de cas connus, nombres de points et tags d'origine (`grenoble-address`, `grenoble-device`, etc.). Les bornes de caméra sont retirées des traces de ce mode. Une soumission hors emprise reste visible dans les compteurs avec `accepted:false` ; aucune position réelle n'est archivée.

### Deux recettes natives FR/EN

Nouveau fichier : `SignalQuestUITests/MapAntennaProfileQATests.swift`. Le responsable doit régénérer XcodeGen après son ajout. Les méthodes sont à exécuter **séparément**, avec leur GPS explicite sur un simulateur dédié ; l'absence du flag global ou du GPS attendu provoque un skip avant le réseau de contrôle.

Prérequis communs :

- API **et** app compilées vers `http://127.0.0.1:8770`, pas seulement des variables de lancement.
- `TEST_RUNNER_SQ_MAP_PROFILE_QA=1` côté runner ; le test transmet `SQ_MAP_PROFILE_QA=1` à l'app.
- Localisation autorisée pour `fr.signalquest.ios` sur ce simulateur. Position simulée configurée par `simctl` avant l'ouverture de l'app, jamais sur un appareil personnel.
- App arrêtée, vider uniquement `Library/Caches/SignalQuestTerrainCache` dans son conteneur de recette avant chaque méthode. Les caches carte peuvent également être vidés selon le protocole général. Ne pas effacer le conteneur complet ni des données personnelles.
- Pour obtenir un nouveau relevé après chaque demande, renouveler les mêmes coordonnées synthétiques avec `simctl location <simulateur réservé> set <lat>,<lon>` toutes les deux secondes pendant la campagne, puis arrêter ce pilote. Une unique position système ancienne peut provoquer un timeout normal de la demande fraîche. Les tests utilisent ensuite le véritable bouton « Actualiser ma position » / « Refresh my location » et attendent sa réactivation pour les étapes GPS. Un flag ou une caméra déplacée ne fournit pas à lui seul un relevé admis par `LocationService`.

**Français :** méthode `testFrenchAddressOverridesDistantGPSAndClearRestoresTheDistanceLimit`, avec `TEST_RUNNER_SQ_MAP_PROFILE_GPS_QA=paris` et GPS **48.8566 / 2.3522**. Choisir QA Grenoble depuis la recherche, ouvrir QA ANTENNE, vérifier le profil depuis l'adresse et sa stabilité après présentation modale. Fermer puis effacer l'adresse ; la distance réellement affichée depuis le GPS Paris doit dépasser 30 km, et les compteurs terrain/clutter doivent rester inchangés malgré le profil antérieur en cache.

**Anglais :** méthode `testEnglishDistantAddressSuppressesNearbyGPSUntilSearchIsCleared`, avec `TEST_RUNNER_SQ_MAP_PROFILE_GPS_QA=grenoble` et GPS **45.1877 / 5.7243**. Choisir QA Paris puis QA ANTENNE : distance >30 km, aucun profil ni appel terrain/clutter. Effacer la recherche, actualiser réellement la position, puis vérifier le profil depuis le GPS Grenoble et sa stabilité. Le premier point reçu par TerrainService doit être tagué `grenoble-device`.

Les tests contrôlent les identifiants d'accessibilité publics du parcours, la distance localisée, les routes effectivement reçues, l'origine annoncée et la présence/stabilité du Canvas. Ils joignent les captures **réelles** de l'écran, l'arbre AX et les compteurs expurgés. Il faut encore examiner ces captures : la seule présence AX du Canvas ne prouve pas la qualité des pixels.

Les variantes « recherche non résolue avec tap sur marqueur » et « ouverture depuis marqueur custom » ne sont pas revendiquées par ces deux méthodes. La sélection d'une suggestion d'antenne efface la saisie, donc elle ne peut pas prouver le maintien d'une recherche non résolue. Ces variantes restent couvertes par leurs tests de modèle ou à recetter avec un marqueur natif réellement accessible. Le serveur fournit le cas vide et les données custom pour une campagne ultérieure.
