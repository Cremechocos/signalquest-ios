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
