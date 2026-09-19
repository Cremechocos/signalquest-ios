# Recette du fil avec HTTP et SSE

Lancer `python3 ci_scripts/fixtures/feed-runtime/server.py` après la recette
isolée disponible sur `127.0.0.1:49141`. Le serveur écoute uniquement
`127.0.0.1:8772` et ne relaie aucune requête vers la production.

Compiler l'application de test avec `SQ_API_BASE_URL` et `SQ_APP_BASE_URL`
à `http://127.0.0.1:8772`, sans configuration Firebase de production.
Vérifier les deux valeurs dans le produit compilé avant de lancer le test.
Exécuter `SignalQuestUITests/FeedHTTPQATests` sur un simulateur dédié avec
`SQ_FEED_HTTP_QA=loopback-8772-verified` et `SQ_FEED_UI_TOKEN` contenant une
session du compte synthétique de la recette. Ne jamais enregistrer ce jeton
dans Git ou les rapports.

Le test vérifie les changements d'onglet et de hashtag pendant une réponse
retardée, le retour d'une fiche et une reconnexion SSE réelle. Les snapshots
SSE sont volontairement globaux ; le client doit relire son filtre courant.
Les nouvelles publications restent annoncées jusqu'à l'action de l'utilisateur.

Ces preuves couvrent le transport local et l'interface native avec des données
synthétiques. Elles ne qualifient pas les requêtes SQL du fil de production,
la distribution TestFlight ou un appareil physique.
