# Nouveautés — version TestFlight

Ce qui a changé, côté utilisateur. Les points marqués **à vérifier** sont ceux qui
n'ont pas pu être mesurés sur un vrai réseau : c'est là que vos retours comptent le plus.

---

## Speedtest

**Le ping est enfin juste.** Il était systématiquement surévalué : la mesure incluait
des étapes qui n'ont rien à voir avec le temps d'aller-retour réel (résolution du nom
du serveur, mise en route de la connexion). Elle a été refaite pour ne chronométrer que
l'aller-retour lui-même.
→ **À vérifier** : comparez la valeur affichée avec un autre outil de mesure. Elles
doivent maintenant coïncider.

**Le débit montant est mesuré plus finement**, donc potentiellement plus élevé qu'avant
sur les bonnes connexions. L'application se rabat automatiquement sur une mesure plus
prudente si le serveur refuse.
→ **À vérifier** : en 5G ou en fibre, comparez avec vos mesures habituelles.

**L'écran affiche désormais quelle méthode a servi** à mesurer la latence : deux
mesures obtenues différemment ne portent plus le même libellé.

**Nouveaux réglages** : distance entre deux tests d'un Drive Test, et plafond de données
d'une session.

---

## Drive Test

**La session ne s'arrête plus quand vous changez d'onglet.** Aller regarder la carte
pendant un trajet mettait fin à l'enregistrement — vous pouvez maintenant revenir et
reprendre là où vous en étiez.

**La consommation de données s'affiche en direct**, avec un plafond (5 Go par défaut)
qui arrête la session proprement et vous le dit. Un Drive Test pouvait consommer
plusieurs dizaines de gigaoctets sans le moindre indicateur.

**Les tests s'espacent tous les 500 m parcourus** au lieu de s'enchaîner en continu.
Les mesures se répartissent le long du trajet au lieu de s'entasser dans les bouchons.
Un bouton **« Tester maintenant »** force une mesure à l'arrêt.

**La distance parcourue s'affiche**, et un résumé apparaît à la fin de la session :
ce qui a été enregistré, ce qui a été envoyé, et le cas échéant ce qui ne l'a pas été.

**Sur les très longs trajets, l'application prévient** au lieu de perdre silencieusement
le début du parcours. La limite est passée d'environ 60 km à environ 1 000 km.

**Un écran d'information apparaît une fois**, avant votre premier trajet : ce qui est
enregistré, à quelle précision c'est publié sur la carte communautaire, et le fait que
rien ne part sous VPN.

**L'opérateur ne reste plus bloqué sur « Détection en cours… »** indéfiniment. Quand il
ne peut pas être identifié — à l'étranger, en WiFi, sous VPN — l'application le dit et
explique ce que cela implique.

**Plus de faux succès** : l'application n'annonce plus « Couverture envoyée » quand le
trajet n'a pas pu être rattaché à un pays et n'apparaîtra donc pas sur la carte.

**Les couleurs de la carte** sont harmonisées avec le reste de l'application, et chaque
niveau porte un symbole : l'échelle reste lisible sans distinguer les couleurs.

---

## Communauté

**Six onglets dans le fil** : Pour toi, Récent, Abonnements, Amis, et le reste. Le fil
« Pour toi » s'adapte à ce que vous consultez réellement.

**Sondages** : créez-en dans vos publications, et votez dans celles des autres.

**Ma semaine** : un bilan hebdomadaire de votre activité, partageable en image.

**Territoires** : une carte de progression qui montre les zones couvertes, observées,
fiables — et les zones blanches.

**Préférences du fil** : suivez ou masquez des hashtags, masquez des mots. Les
publications qui les contiennent n'apparaissent plus.

**Mentions et hashtags** se complètent automatiquement pendant la saisie.

**Notes vocales** dans la messagerie : enregistrement, forme d'onde et lecture. Elles
étaient jusqu'ici seulement transcrites, sans pouvoir être écoutées.

**Modification et épinglage** de vos publications, et stories typées.

---

## Langue

**L'application s'affichait en anglais pour des utilisateurs français** dans certains
cas. La cause était une déclaration manquante ; c'est corrigé.

**Une quarantaine de textes restaient en français** dans la version anglaise — filtres
de la carte, libellés d'état, messages du Drive Test. Traduits.

---

## Accessibilité

Libellés VoiceOver ajoutés sur la carte et ses annotations, qui n'exposaient rien
jusqu'ici. Contrastes revus, tailles de texte respectées sur les écrans concernés, et
la légende de la carte Drive Test est maintenant lisible au lecteur d'écran.

---

## Abonnements

Le paiement par l'App Store est en place côté serveur : vérification des achats,
renouvellements et annulations. **Pas encore activé dans l'application** — il le sera
quand les produits seront validés par Apple.

---

## Corrections diverses

- Le titre « Communauté » se coupait en deux sur l'écran du fil.
- Le signalement d'une photo ne fonctionnait pas.
- Impossible de débloquer quelqu'un qu'on avait bloqué.
- Les demandes d'amis envoyées n'apparaissaient nulle part.
- Correctifs de stabilité : plusieurs situations pouvaient faire fermer l'application.
- Autonomie : les relevés réseau continuaient de tourner écran verrouillé.
- Fluidité générale de la carte et du fil.

---

## Ce qui n'est pas encore vérifié

- **Le gain réel sur le ping** n'a pas été mesuré sur un vrai réseau, seulement établi
  en principe.
- **Le débit montant à pleine capacité** n'a pas été validé sur tous les serveurs.
- **L'iPad** n'a pas encore été traité : l'application y fonctionne mais n'exploite pas
  l'écran.
