# Chiffrement de bout en bout complet — spécification commune (v2)

> Statut : **proposition v0.4.14**, à valider par les sessions iOS, Android et
> serveur (qui porte aussi le web) avant tout développement. Le chantier
> démarre au plan 3. Son **jalon A**, des appels chiffrés de bout en bout sur
> iOS, Android et le web, est la condition de la bêta TestFlight iOS des
> appels chiffrés (décision produit du 30/09, §16) ; une bêta intermédiaire,
> le nouveau chiffrement fermé, la précède (décision du 01/10).
>
> - v0.1 (30/09/2026) : première rédaction (plan 2, Lot 6).
> - v0.2 (30/09/2026) : révisée après une relecture de sécurité indépendante.
>   Ajouts : chaîne de confiance des appareils et des membres, récupération
>   limitée à son propre compte, section « Propriétés de sécurité », franking
>   refait, appels authentifiés et réglages LiveKit figés, surfaces fermées par
>   défaut, annexe « octets sur le fil » conforme au code et aux vecteurs.
> - v0.3 (30/09/2026) : retours des sessions serveur et Android, décisions
>   produit du 30/09.
>   - Décisions produit : clés créées par les appareils, appels, navigateurs
>     sur demande, pas de revue externe, messages programmés (§18).
>   - Serveur :
>     - enveloppes d'époque gardées en ligne témoin au lieu d'être
>       supprimées ;
>     - signalement en deux parties, l'une en clair, l'autre scellée ;
>     - le serveur ne refuse que les capacités qu'il voit ;
>     - `callId` choisi par l'appelant ;
>     - nouvelles clés JSON pour les appels ;
>     - numéro d'époque « +1 strict » ;
>     - manifeste d'époque défini (§3.5) ;
>     - historique d'appartenance ;
>     - purge signée des blobs ;
>     - `serverTag` canonique.
>   - Android :
>     - UIK logicielle ;
>     - rôle de StrongBox ;
>     - Android 11 et moins ;
>     - forme low-S imposée ;
>     - document de capacités signé par l'appareil (§12) ;
>     - réglages LiveKit tous explicites et marqueur « non chiffré » à
>       prouver ;
>     - liste d'emoji figée ;
>     - surfaces Android.
>   - Nouveautés :
>     - jalons A et B (§16) ;
>     - tickets du jalon A (annexe C) ;
>     - estimation mise à jour (annexe B).
> - v0.3.1 (30/09/2026) : questions 6 à 10 du §18 tranchées. Elles portent
>   sur les anciennes conversations, l'app sans v2, l'outil de modération,
>   l'origine statique du web (après la bêta) et la taille des médias.
> - v0.4 (30/09/2026) : tous les formats du jalon A écrits à l'octet
>   (annexe D), préalable aux vecteurs de référence. Ajustements imposés par
>   les SDK LiveKit :
>   - un appel garde son époque ;
>   - aucune piste publiée ni rendue avant la vérification ;
>   - canal de données chiffré obligatoire ;
>   - SIF neutralisé.
>
>   Aussi :
>   - trois vecteurs réémis en forme low-S ;
>   - compatibilité des apps installées (§16) ;
>   - critère d'ouverture des verrous (§17) ;
>   - `e2eeV2.signatureB64` au lieu de `signature`.
> - v0.4.1 (30/09/2026) : routes du jalon A proposées (annexe E), à valider
>   par la session serveur ; empreintes de référence des vecteurs.
> - v0.4.2 (30/09/2026) : preuve de jonction précisée pour l'interopérabilité
>   (renvoi aux nouveaux arrivants, vérifications, preuve invalide, lien entre
>   identité et appareil) ; fin d'un appel au plus tard à l'enregistrement
>   d'une époque plus récente (§10.3, §10.4).
> - v0.4.3 (30/09/2026) : après la relecture du code serveur et du SDK
>   Android.
>   - L'identité LiveKit d'un appel chiffré est celle de l'appareil,
>     `<userId>.<deviceId>`, et non plus celle du compte (§10.4, D.11).
>   - `409 CALL_NONCE_TAKEN` pour un `callNonce` déjà vu (§10.1).
>   - Relais de `e2eeV2` précisé : chaîne JSON dans FCM, flux SSE des appels,
>     notification de transfert (E.4).
>   - Vecteur `call-join-proof-v1` réémis avec une identité d'appareil.
>   - Adressage des preuves : une optimisation seulement, les paquets chiffrés
>     étant diffusés (§10.4).
>   - Limite écrite : l'émetteur d'un paquet chiffré est déclaré par lui-même
>     (§10.4).
>   - Preuve rediffusée à 0, 1, 2, 4 et 7 secondes, et paquet chiffré d'un
>     émetteur pas encore annoncé ignoré, après le banc local (§10.4).
> - v0.4.4 (01/10/2026) : réponses aux seize questions du serveur sur son
>   chiffrage du jalon A (annexe E, §12, §14). Corps des requêtes d'appel,
>   contrôles du descripteur par le serveur, capacités par document signé
>   seulement, jetons push liés à l'appareil, retrait de l'appareil approuvé,
>   liste des messages v2, rapports pour l'outil hors ligne, genèse d'une
>   conversation migrée, apps publiées face à la v2. Proposés, en attente de
>   la décision d'Alexandre : transfert d'un appel chiffré indisponible au
>   jalon A.
> - v0.4.5 (01/10/2026) : la plateforme du nouvel appareil entre dans ce que
>   l'utilisateur compare à l'approbation (QR v3, code SAS), ensemble fermé des
>   plateformes, refus par l'approbateur et par le serveur (§2.3, D.2, D.13,
>   E.0). Accord des sessions serveur, Android et web.
> - v0.4.6 (01/10/2026) : après une relecture de sécurité indépendante du code
>   iOS de la chaîne de confiance. Les navigateurs ne détiennent jamais l'UIK
>   (§2.7, D.1). Code SAS en mise en gage puis révélation (D.13). Code de
>   proximité dérivé de l'empreinte. Chaîne des listes servie depuis la
>   version épinglée (D.3, E.1). Vérification de l'UIK de son propre compte
>   sur un nouvel appareil (§2.3). Bundle de récupération signé par l'UIK
>   (§2.8). Lecture stricte des lignes de liste et du base64 des clés.
>   Appels, après une seconde relecture : jonction tardive bornée à 12 heures,
>   appel terminé jamais rejoint, fin d'un appel chiffré à une reconnexion
>   complète, chiffrement que le serveur ne peut pas retirer, média coupé avant
>   tout aller-retour réseau, pistes publiées muettes jusqu'au chiffreur prêt,
>   pistes distantes reçues seulement d'un participant prouvé, nom affiché
>   d'après l'utilisateur prouvé, marqueur SIF remplacé par 32 octets
>   aléatoires après chaque jonction, états des chiffreurs gardés à une
>   reconnexion rapide (§10.1, §10.3, §10.4). Accord des sessions Android et
>   web ; avis du serveur attendu.
> - v0.4.7 (01/10/2026) : le manifeste d'époque passe au format 2 et engage
>   l'état d'appartenance sur lequel repose sa liste de destinataires (§3.5,
>   D.4, D.6). Il fixe ainsi la fin de la genèse, dont les règles
>   d'autorisation ont besoin. Un seul manifeste d'époque 1 par conversation,
>   synchronisation de la chaîne avant tout refus, numéro qui ne recule pas,
>   destinataires membres de l'état, `409 E2EE_MEMBERSHIP_STALE` pour une
>   époque fondée sur un état dépassé, genèse de migration dans la confiance
>   v1 (§14). Précisions d'Android et du web ; avis du serveur attendu.
>   Vecteurs `epoch-manifest-v2` et `epoch-binding-v1`. Puis, après une
>   relecture indépendante du code iOS : numéros bornés, âge d'une époque
>   compté depuis son acceptation locale, liaison à la longueur de la genèse,
>   genèse revérifiée à chaque relecture, clé vérifiée pour l'envoi et les
>   appels, migration idempotente, réponses en JSON strict, limite du premier
>   contact écrite (§3.1, §3.3, §3.5, §12, §14, E.2). Puis, pour le texte v2 :
>   enveloppe transportée à clés exactes et entiers en chaînes, chiffré sur un
>   palier de bourrage, charge bornée pour que l'enveloppe tienne en 512 Kio,
>   accusé d'envoi, liste et lecture des messages, renvoi à l'identique et
>   rechiffrement sur refus d'époque (D.7, E.0, E.3). Vecteur
>   `message-envelope-v2` complété par l'enveloppe transportée. Après les
>   avis du web et d'Android : corps d'envoi en JCS à l'octet, grammaire des
>   entiers en ASCII, base64 défini par le réencodage, `fk` gardé au
>   rechiffrement, doublon et équivoque définis par le `frankTag`, conflit
>   tenu pour une remise, ordre des contrôles, compteur jamais sous ce que la
>   liste montre, trous évalués une fois la liste rattrapée (D.7, E.3, §18).
>   Puis, après une relecture indépendante du code iOS du lot 5 : instants et
>   séquences bornés à 2⁵³ − 1, rechiffrement local d'un envoi dont l'époque
>   a été remplacée, expiration des éphémères à l'heure signée de l'émetteur,
>   membres partis acceptés seulement en vol, rotation dès un retrait ou un
>   départ connu, identités gardées à vie, époques sautées relues, signature
>   vérifiée avant toute question d'époque, taille du signalement (§3.3, §3.4,
>   D.7, D.8, D.10, E.2, E.3). Puis : miroir de l'extension de notification
>   sans clé privée d'appareil, lecture d'une enveloppe au cookie seul, avec sa
>   conversation (§2.6, E.3). Puis, après deux relectures indépendantes :
>   entrée du miroir liée au compte et à la session, retirée avant toute
>   opération de la messagerie v2 et réécrite après succès dans l'ordre des
>   opérations, inutilisable après 24 heures ; départs vérifiés par
>   l'extension ; un message montré une fois au plus par activation du
>   miroir, retenu d'un seul geste, et, avec l'aperçu complet, jamais signé
>   il y a plus de 48 heures ; aucun texte
>   d'éphémère, d'édition ou de suppression ; aucune clé d'époque en mode
>   « expéditeur seulement », dont les limites sont écrites ; lecture
>   d'enveloppe réservée aux membres, sans effet de bord, jamais mise en
>   cache (§2.6, E.3).
> - v0.4.8 (01/10/2026) : accord du serveur sur la v0.4.6, la v0.4.7 et E.3,
>   avec ses précisions : relais du SAS v3 à usage unique, navigateurs qui ne
>   reçoivent ni n'émettent rien de la chaîne de confiance, bundle de
>   récupération vérifié par le serveur, acceptation d'une époque et
>   changement d'appartenance sérialisés, genèse idempotente à l'octet,
>   portée du compteur et séquences de la liste (§2.7, §2.8, D.13, E.0 à
>   E.3). Aucun vecteur ne change.
> - v0.4.9 (01/10/2026) : changement de numéro de sécurité vu par un contact.
>   Le nouveau numéro est montré sans que la nouvelle UIK soit crue. Tant que
>   l'utilisateur ne l'a pas acceptée, rien n'est envoyé à ce compte et il
>   n'est jamais exclu en silence d'une nouvelle époque ; il en va de même
>   pour tout membre dont le paquet est refusé. Elle n'est épinglée qu'à la
>   demande de l'utilisateur, si c'est encore celle dont le numéro a été
>   montré, après une relecture du paquet sans `sinceVersion`. Force du numéro
>   précisée : environ 100 bits par personne. Le serveur ignore un
>   `sinceVersion` qui dépasse la version courante de la liste (§2.4, E.1).
>   Aucun vecteur ne change.
> - v0.4.10 (01/10/2026), après les retours du web et du serveur :
>   épinglage en comparaison-échange atomique, relu par chaque contexte d'un
>   appareil (onglet, extension, processus) avant d'envoyer, de faire tourner
>   ou de créer une époque ; dans un navigateur, une UIK changée ne s'accepte
>   jamais sans vérification, et un premier contact y reste en confiance au
>   premier usage (limite écrite au §0) ; épingles perdues avec les clés d'un
>   navigateur effacé ; champ facultatif `memberListVersions` à la création et
>   à la rotation d'une époque (§0, §2.4, §2.7, E.0, E.2). Question ouverte :
>   épingles transmises au navigateur à son approbation (§18). Aucun vecteur
>   ne change.
> - v0.4.11 (01/10/2026), après deux relectures indépendantes du
>   signalement iOS : la version affichée de chaque message signalé part
>   toujours, puis son original et ses éditions intermédiaires tant que le
>   rapport tient, pour que la modération lise ce que le signaleur a vu sans
>   qu'un message trop modifié devienne insignalable ; un message supprimé
>   par son auteur ou un éphémère expiré n'est plus signalable et part de
>   l'appareil avec ses éditions, et une édition expirée cesse de compter ;
>   la route d'administration rend les données d'envoi dont l'outil a besoin
>   pour recalculer `frankTag`, et marque `unverifiable` une enveloppe qu'il ne
>   retrouve pas ; quota de signalements sur 24 heures glissantes en 429
>   `E2EE_REPORT_QUOTA`, rapport trop grand en 400 `E2EE_REPORT_TOO_LARGE`
>   (§11, §16, D.8, E.0, E.3), après accord du serveur. Aucun vecteur ne
>   change.
> - v0.4.12 (01/10/2026) : vecteur `capability-intersection-v1`, produit par
>   iOS (§12, §15) : appareils pris en compte, versions, `kind` et fonctions
>   communs, ou capacité indisponible ; dix cas, dont l'exclusion des
>   navigateurs, la mise à l'écart, un membre sans appareil certifié et un
>   membre refusé. Précision : un document de 90 jours pile ne compte plus
>   (« moins de 90 jours »). Aucun autre vecteur ne change.
> - v0.4.13 (01/10/2026), proposition : un appel chiffré se décroche et se
>   rejoint écran verrouillé (décision produit du 01/10). La clé de signature
>   de l'appareil est utilisable dès le premier déverrouillage après le
>   démarrage ; la clé d'accord et l'UIK restent soumises au déverrouillage ;
>   la clé de l'époque courante suit la règle des aperçus (§2.6). Aucun
>   vecteur ne change.
> - v0.4.14 (02/10/2026), proposition : sur iOS, la clé de signature de
>   l'appareil vit dans la Secure Enclave, non extractable comme sur Android
>   et le web (décision produit du 01/10) ; le compromis du §2.6 se réduit à
>   l'usage de la clé par qui tient l'appareil. Précision : la clé d'époque
>   n'est lisible écran verrouillé qu'avec l'aperçu complet. Format des
>   signatures inchangé (DER canonique, low-S, D.0). Aucun vecteur ne change.
>
> Portée : chiffrer de bout en bout, en plus du texte, les photos et fichiers,
> les notes vocales, les sondages, les réactions, les positions et les appels
> audio et vidéo. Une seule génération de protocole, la **v2**, commune aux
> clients iOS, Android et web, et au serveur.
>
> L'inventaire de l'existant et les relectures détaillées, qui décrivent des
> écarts de sécurité, ne sont **pas** publiés dans ce dépôt public.

Les mots **DOIT**, **NE DOIT PAS**, **DEVRAIT** et **PEUT** ont le sens des RFC
2119 et 8174.

---

## 0. Modèle de menace et propriétés de sécurité

**Adversaire principal : le serveur**, qu'il soit malveillant, compromis ou
contraint. Il voit tout le trafic, stocke tout, peut retenir, retarder ou
réordonner des messages, et fournit le code du client web.

**Ce que la v2 garantit** (sous réserve de la chaîne de confiance du §2) :

- **Confidentialité** du contenu (texte, médias, sondages, réactions,
  positions, appels) vis-à-vis du serveur et de quiconque n'est pas un appareil
  certifié d'un membre actuel.
- **Authenticité** : chaque message est signé par un appareil certifié, et
  l'expéditeur affiché est vérifié par le client, non déclaré par le serveur.
- **Intégrité** : altération, troncature et réordonnancement des médias sont
  détectés.

**Ce que la v2 ne garantit pas**, et que le produit DOIT dire :

- **Pas de confidentialité persistante à l'intérieur d'une époque**, ni contre
  la compromission de la clé d'accord d'un appareil : qui obtient cette clé lit
  les époques qui lui ont été envoyées. La guérison ne vient qu'avec la rotation
  qui suit une révocation (§3), et avec la rotation périodique de la clé
  d'appareil (§2.6).
- **Pas de déniabilité** : signatures d'appareil et franking (§11) produisent
  des preuves transférables. C'est un choix assumé, au service de la
  modération.
- **Métadonnées visibles** par le serveur : voir le tableau du §4.4.
- **Disponibilité** : le serveur peut retenir ou retarder. Les compteurs
  signés (§4.3) rendent les trous détectables, pas impossibles.
- **Client web** : le serveur fournit le code qui manipule les clés. D'où
  l'accès des navigateurs sur demande seulement (§2.7). Un navigateur ne
  connaît pas les contacts que les téléphones du compte ont vérifiés : un
  premier contact fait depuis lui repose sur la confiance au premier usage.
  Comparer le numéro de sécurité le détecte (§2.4, v0.4.10).

Un protocole de groupe standard (MLS, RFC 9420) offrirait la confidentialité
persistante par message et la guérison continue. Il est à évaluer pour une v3.

---

## 1. Principes

1. **Les clés naissent sur les appareils.** Aucune clé de contenu (époque,
   média, appel) n'est générée, déchiffrée ou vue en clair par le serveur.
2. **Le serveur ne décide pas des destinataires.** Un client n'envoie une clé
   qu'à un appareil dont il a lui-même vérifié le certificat (§2).
3. **Fermé par défaut.** Dans une conversation chiffrée, un contenu qu'un
   client ne sait pas chiffrer n'est jamais envoyé en clair. L'action est
   désactivée, avec une explication. Le serveur refuse aussi tout contenu en
   clair (§13).
4. **Des états qui ne régressent pas.** « Chiffrée » et « v2 » sont des états
   collants, mémorisés par chaque appareil, qu'aucune réponse du serveur ne peut
   faire régresser (§12).
5. **Une seule vérité par format**, verrouillée à l'octet près par des vecteurs
   de test partagés (annexe A, §15). Toute évolution passe par un nouveau
   numéro de version et de nouveaux vecteurs. On n'ajoute jamais un champ à une
   version existante.
6. **Ce que l'interface affiche est vrai.** Cadenas et mention « chiffré »
   n'apparaissent qu'après vérification de ce contenu précis, appel compris.

---

## 2. Identités et chaîne de confiance

### 2.1 Clé d'identité de compte (UIK)

- Chaque compte a une **clé d'identité de compte** (UIK), une paire P-256
  ECDSA créée sur le premier appareil et gardée seulement par les appareils
  certifiés du compte. Elle circule entre eux, chiffrée de bout en bout, lors
  de l'approbation.
- Puisqu'elle circule, l'UIK est une **clé logicielle** : elle ne peut pas être
  une clé matérielle non exportable. Au repos, elle est chiffrée par une clé
  matérielle de l'appareil (§2.6). Seules les deux clés d'appareil (§2.2) sont
  matérielles, quand la plateforme le permet.
- La **clé publique** de l'UIK est ce que les contacts vérifient et épinglent
  (confiance à la première utilisation, puis vérification explicite).

### 2.2 Appareils et certificats

- Chaque appareil a deux paires P-256 : accord de clé
  (`P256_X963_ECDH_HKDF_SHA256`) et signature (`P256_X963_ECDSA_SHA256_DER`).
  Les clés privées ne quittent jamais l'appareil (§2.6).
- **Certificat d'appareil**, signé par l'UIK :
  `SQ-E2EE-V2-DEVICE-CERT\n1\n<userId>\n<deviceId>\n<keyVersion>\n<identityKeyB64>\n<signingKeyB64>\n<platform>\n<createdAtMs>`.
  - `platform` vaut `ios`, `android` ou `web`.
  - `keyVersion` est un entier décimal qui commence à 1 et croît
    strictement à chaque rotation de la clé d'accord (§2.6). Un appareil
    certifié détient l'UIK : il signe lui-même le certificat de sa nouvelle
    clé.
  - Les capacités ne figurent pas dans le certificat : elles ont leur propre
    document, signé par l'appareil (§12).
- **Liste d'appareils signée** par l'UIK, versionnée et monotone. Le serveur
  n'accepte une nouvelle liste que si sa version vaut la précédente + 1
  (comparaison-échange). Un client refuse une liste plus ancienne que la
  dernière vue.
- **Règle normative** : un client NE DOIT envelopper une clé d'époque, ou
  accepter une signature de message, que pour un appareil dont le certificat se
  vérifie jusqu'à l'UIK épinglée de son propriétaire.

### 2.3 Ajout d'un appareil

- Le premier appareil est amorcé par un code e-mail et une ré-authentification,
  puis crée l'UIK.
- Un appareil suivant est `PENDING` jusqu'à ce qu'un appareil certifié du même
  compte l'approuve et signe son certificat avec l'UIK.
- **Côté serveur**, une approbation n'est enregistrée qu'avec le certificat
  signé et la nouvelle liste d'appareils signée, dans la **même transaction**.
- Le **QR** et le **code de proximité** contiennent l'empreinte complète
  `SHA-256(identityKey ‖ signingKey)` du nouvel appareil, et l'approbateur la
  compare automatiquement.
- La **plateforme** du nouvel appareil fait partie de ce que l'utilisateur
  compare (QR et code SAS, D.13). L'approbateur signe le certificat avec la
  plateforme que l'utilisateur a vue, jamais avec celle que déclare le serveur.
- L'approbation **par notification** exige un code de comparaison (SAS) de six
  chiffres, affiché sur les deux écrans et confirmé par l'utilisateur. Le
  nouvel appareil met d'abord son aléa en gage, l'approbateur répond par le
  sien, puis le premier révèle le sien (D.13) : le serveur ne peut plus
  chercher un code qui coïncide. Une seule tentative par code.
- Le nouvel appareil reçoit l'UIK du compte sans pouvoir la comparer seul. Il
  la marque « clé du compte non vérifiée » jusqu'à ce que l'utilisateur
  compare les 30 chiffres du compte (D.12) avec un autre de ses appareils. Un
  QR montré par l'approbateur et scanné par le nouvel appareil PEUT remplacer
  cette comparaison.
- Tout ajout d'appareil est annoncé aux contacts dans les conversations
  (message système vérifié) ; le numéro de sécurité ne change pas (§2.4).

### 2.4 Numéro de sécurité

- **Par utilisateur**, calculé sur la clé publique de l'UIK : 30 chiffres, soit
  environ 100 bits par personne, comme Signal (v0.4.9). Le numéro d'une paire,
  60 chiffres, s'affiche par groupes de cinq et en QR. La dérivation itérée
  (5 200 itérations de SHA-512) renchérit chaque essai d'une clé qui donnerait
  les mêmes chiffres.
- Il ne change pas à l'ajout d'un appareil certifié. Il change seulement à la
  réinitialisation de l'identité.
- **Réinitialisation d'identité** : les appareils existants du compte en sont
  notifiés et peuvent s'y opposer pendant 72 heures. Les contacts voient
  « X a un nouveau numéro de sécurité ». L'envoi vers X attend que
  l'utilisateur accepte ce nouveau numéro et, si l'ancien était vérifié, qu'il
  le vérifie (ci-dessous).
- **Changement vu par un contact** (v0.4.9) :
  - le client montre le nouveau numéro, calculé sur l'UIK servie, sans la
    croire : aucun appareil de ce compte n'est certifié tant qu'elle n'est pas
    épinglée ;
  - d'ici là, le client NE DOIT rien envoyer à ce compte, ni l'exclure en
    silence d'une nouvelle époque. Dans les conversations dont il est membre,
    l'envoi, la rotation et la création attendent, et un avis y donne accès à
    son numéro. Il en va de même pour tout membre dont le paquet est refusé
    (liste en recul, lacune, signature invalide) ;
  - le client n'épingle la nouvelle UIK qu'à la demande de l'utilisateur,
    « vérifiée » s'il vient de comparer, et seulement si l'UIK servie est
    encore celle dont le numéro a été montré. Il relit alors le paquet **sans**
    `sinceVersion`, puisque la liste de la nouvelle identité repart de 1
    (D.14), et le vérifie comme au premier contact ;
  - une UIK vérifiée ne se remplace qu'avec une nouvelle vérification ; une
    UIK non vérifiée s'accepte d'un geste, sauf dans un navigateur, où toute
    UIK changée demande une vérification (§2.7, v0.4.10) ;
  - l'épinglage est une comparaison-échange atomique (v0.4.10) : le client
    n'écrit une épingle que si elle vaut encore celle qu'il a lue avant la
    lecture réseau ou avant d'afficher le numéro, sans autre opération entre
    la vérification et l'écriture (sur le web, une seule transaction
    IndexedDB en écriture). Chaque contexte d'un même appareil (onglet,
    extension, processus) relit l'épingle avant d'envoyer, de faire tourner
    une époque ou d'en créer une.

### 2.5 Membres des groupes

- Chaque ajout ou retrait de membre est signé par l'appareil d'un
  administrateur, et affiché comme message système vérifié. Un client rejette
  un changement de membre non signé.
- Le serveur conserve l'**historique des appartenances**, en ajout seul :
  ajout, retrait, départ, avec la date et l'auteur. Un retrait n'efface pas
  la ligne d'origine. Cet historique sert à vérifier qu'un signaleur était
  membre au moment des messages signalés (§11).
- Chaque époque porte un **manifeste signé de ses destinataires** (§3.5).
  Chaque destinataire le compare à sa propre vue des membres et des appareils
  certifiés, et signale tout écart.

### 2.6 Stockage et rotation des clés d'appareil

- **iOS** : clés d'appareil en Secure Enclave quand l'algorithme le permet,
  sinon Keychain `ThisDeviceOnly`.
- **Android** : clés d'appareil dans le Keystore, en environnement d'exécution
  sécurisé (TEE). StrongBox est lent et n'offre presque jamais l'accord de
  clé : on ne l'utilise, s'il existe, que pour la clé qui chiffre l'UIK. Avant
  Android 12 (API 30 et moins), l'accord de clé du Keystore
  (`PURPOSE_AGREE_KEY`, API 31) n'existe pas. La clé d'accord est alors
  logicielle, chiffrée par une clé Keystore.
- **Web** : §2.7.
- La **clé d'accord** de chaque appareil tourne tous les 30 jours. La nouvelle
  clé reçoit un nouveau certificat (`keyVersion` + 1).
- **Enveloppes d'époque déjà reçues** : quand l'appareil destinataire accuse
  réception, le serveur efface le contenu chiffré de l'enveloppe (clé
  enveloppée, clé éphémère, nonce, signature). Il ne garde qu'une **ligne
  témoin** (époque, destinataire, date de l'accusé), sur laquelle
  s'appuient la livraison, l'unicité et la révocation.
- **Écran verrouillé** :
  - avec les aperçus, l'extension de notification (iOS) ou le service de
    messagerie (Android) peut utiliser les clés d'époque courantes écran
    verrouillé, jamais les clés d'identité ;
  - **appels** (décision produit du 01/10, v0.4.13) : un appel chiffré se
    décroche et se rejoint écran verrouillé. La **clé de signature** de
    l'appareil est utilisable dès le premier déverrouillage après le
    démarrage (iOS : `AfterFirstUnlockThisDeviceOnly` ; Android : Keystore
    sans `setUnlockedDeviceRequired`), pour la preuve de jonction (§10.4) et
    les requêtes signées (A.2). La **clé d'accord** de l'appareil et l'**UIK**
    restent soumises au déverrouillage. La clé de l'époque courante suit la
    règle des aperçus : avec l'aperçu complet, l'appel se rejoint
    verrouillé ; sinon (« expéditeur seulement » ou « aucun aperçu »), elle
    exige le déverrouillage. Quand rejoindre demande le déverrouillage
    (aperçu qui n'est pas complet, ou époque que l'appareil n'a pas encore
    ouverte), l'écran d'appel le dit et la jonction reprend au
    déverrouillage. Une clé illisible parce que l'appareil est verrouillé
    n'est jamais prise pour une clé perdue : on réessaie après le
    déverrouillage, sans nouvel enrôlement. La clé de signature n'est
    jamais extractable : Secure Enclave sur iOS (v0.4.14), Keystore sur
    Android, clé WebCrypto non exportable sur le web ; ses signatures
    suivent D.0 (DER canonique, low-S, normalisées avant envoi). Compromis
    assumé : un appareil saisi après un premier déverrouillage depuis son
    démarrage permet d'utiliser sa clé de signature tant qu'on le détient,
    jusqu'à sa révocation ;
  - avec « aucun aperçu », ces clés exigent le déverrouillage (iOS : classe
    `WhenUnlocked` ; Android : `setUnlockedDeviceRequired`) ;
  - sur iOS, le miroir de l'extension ne contient que la session,
    l'identifiant de l'appareil, les noms des expéditeurs et, par
    conversation :
    - une entrée écrite par l'app pour ce compte et cette session : les
      époques vérifiées dont l'appareil détient la clé (la courante et
      celles remplacées depuis moins de 24 heures) et leurs membres, les
      clés publiques certifiées de leurs appareils, les membres actuels, les
      départs appris depuis moins de 24 heures et, par appareil émetteur, le
      plus haut compteur reçu par l'app. Les clés d'époque n'y figurent
      qu'avec l'aperçu complet ;
    - ce que l'extension a déjà montré : le plus haut compteur par appareil
      émetteur, lié lui aussi au compte et à la session, sans aucune clé.

    Jamais de clé privée d'appareil, et rien du tout avec « aucun aperçu » ;
  - la messagerie v2 de l'app retire l'entrée avant toute relève, tout envoi
    et tout changement d'appartenance, et ne la réécrit qu'après leur
    succès, jamais par-dessus une opération commencée plus tard. Un échec
    d'écriture, ou un registre de l'app illisible ou repris de zéro depuis
    moins de 48 heures, la retire ; si elle ne part pas, tout le miroir est
    révoqué. Une conversation quittée perd son
    entrée et ce que l'extension en a montré. Une révocation efface tout le
    miroir, ce que l'extension a montré compris : après une réactivation,
    seul le compteur reçu par l'app écarte un message déjà vu. Une
    activation pour un autre compte, une autre session ou un autre mode
    d'aperçu efface d'abord tout, sinon rien ne s'active. Une
    entrée écrite il y a plus de 24 heures ne sert plus et part dès qu'on la
    croise ;
  - l'extension applique les règles de l'app à cet état figé : une
    révocation ou un retrait postérieurs à la dernière écriture ne valent
    qu'à la suivante, donc au plus 24 heures après. Elle vérifie : appareil
    certifié, signature avant tout, époque connue, membre de l'époque,
    membre parti accepté 24 heures (§3.4), aucun blob. Sans le registre de
    l'app (§4.2), elle ne montre un message que si son compteur dépasse à
    la fois celui reçu par l'app et le plus haut qu'elle a déjà montré pour
    cet appareil, ce qu'elle retient d'un seul geste : un message arrivé
    après un plus récent du même appareil reste donc générique. Avec
    l'aperçu complet, elle déchiffre et refuse aussi un message signé il y a
    plus de 48 heures (10 minutes d'avance tolérées). En mode « expéditeur
    seulement », elle ne déchiffre rien : elle n'authentifie que l'appareil
    signataire et son appartenance, ni l'âge ni le contenu du message. Le
    nom affiché vient du serveur, comme dans l'app. Sinon, comme pour tout
    échec, la notification reste générique. Un message éphémère, une
    édition ou une suppression ne montrent jamais leur texte.
- Après une restauration d'appareil, les clés locales ont disparu. Le client le
  détecte au démarrage et demande un nouvel enrôlement, plutôt que de laisser un
  appareil fantôme.

### 2.7 Appareils web (navigateurs)

Une clé WebCrypto non extractible ne protège pas contre un JavaScript
malveillant, qui peut l'**utiliser**. Or le code web est fourni par le même
opérateur que l'API. Décision produit du 30/09 : les navigateurs accèdent aux
conversations chiffrées **sur demande seulement**.

- Un navigateur n'est jamais ajouté d'office. Il devient un appareil à la
  demande de l'utilisateur, approuvé depuis un appareil **mobile** certifié du
  même compte (QR, §2.3).
- Il est marqué « navigateur » dans l'écran des appareils, les listes et les
  manifestes d'époque. Il se révoque depuis le téléphone.
- Chaque conversation offre l'option « exclure les navigateurs ». Dans une
  conversation de groupe, un administrateur la règle ; en tête-à-tête, l'un
  des deux membres. Le réglage est annoncé par un message système vérifié,
  prend effet à l'époque suivante et figure dans son manifeste (§3.5).
- Depuis le web, il est impossible d'approuver un appareil ou d'utiliser la
  récupération.
- Un navigateur ne détient **jamais** l'UIK : aucun `uikWrap` pour
  `platform = web` (D.1). Avec l'UIK, un JavaScript malveillant pourrait
  certifier un faux téléphone et annuler l'exclusion des navigateurs. En
  conséquence :
  - le navigateur crée ses deux clés d'appareil, montre le QR v3 et attend
    qu'un téléphone signe son certificat ;
  - sa page « Appareils » est en lecture seule et renvoie vers le téléphone
    pour révoquer ;
  - après une rotation de l'UIK, un téléphone re-signe son certificat, et le
    web demande « réapprouvez ce navigateur depuis votre téléphone » ;
  - un compte sans téléphone ne peut pas activer la v2 sur le web, puisque le
    premier appareil doit porter l'UIK ;
  - le web ne crée aucun bundle de récupération.
- Le navigateur garde ses épingles de contacts avec ses clés d'appareil : un
  stockage effacé perd les deux. Il redevient alors un nouvel appareil, à
  réapprouver, et ne continue jamais avec des épingles oubliées (v0.4.10).
- Il ne sait pas quels contacts les téléphones du compte ont vérifiés : une
  UIK changée ne s'y accepte jamais sans vérification, même si elle avait été
  épinglée au premier usage (§2.4, v0.4.10).
- Le client web DEVRAIT être servi depuis une origine statique distincte, avec
  une CSP stricte, l'intégrité des sous-ressources (SRI) et des bundles
  reproductibles publiés. C'est un chantier d'infrastructure à part.
  Décision du 30/09 : il suit la bêta du jalon A et n'en est pas un prérequis,
  puisque l'accès des navigateurs reste sur demande.

### 2.8 Récupération

- Bundle chiffré (HKDF-SHA256 puis AES-256-GCM) avec une clé de récupération
  aléatoire de 32 octets, présentée une seule fois à l'utilisateur. Le serveur
  ne détient jamais cette clé.
- **Règle normative** : un appareil N'ENVELOPPE une clé d'époque que vers la
  clé de récupération de **son propre compte**. Il n'utilise jamais une clé de
  récupération d'un autre membre fournie par le serveur.
- Le serveur ne choisit pas non plus la clé de son propre compte : le bundle
  porte une signature de l'UIK sur
  `SQ-E2EE-V2-RECOVERY-BUNDLE\n1\n<userId>\n<bundleHash>\n<recoveryPublicIdentityKeyB64>`.
  Un appareil qui n'a pas créé le bundle vérifie cette signature avant
  d'envelopper. En attendant ce format, seul l'appareil qui a créé le bundle
  sauvegarde l'historique. Le serveur garde le bundle tel quel et vérifie
  aussi cette signature contre l'UIK publique enregistrée, en défense en
  profondeur (`400 E2EE_RECOVERY_SIGNATURE_INVALID`) ; les clients ne s'y
  fient jamais.
- La clé de récupération ouvre tout l'historique **et** permet d'approuver un
  appareil. Son usage déclenche la même alerte qu'un nouvel appareil, puis une
  nouvelle clé de récupération est proposée.

---

## 3. Époques de conversation

Format de l'enveloppe : annexe A.3. Vecteur : `epoch-envelope-v1.json`.

### 3.1 Création

- La clé d'époque (32 octets) est générée par un **appareil certifié d'un
  membre actuel**, jamais par le serveur.
- Le numéro vaut **exactement le précédent + 1**, et la première époque vaut 1.
  Un saut est refusé, sans quoi un numéro démesuré figerait la conversation.
  Numéros d'époque et de changement d'appartenance bornés de 1 à 2³¹ − 2,
  comme les versions de liste (D.3) : `n + 1` ne déborde jamais (v0.4.7).
- Elle est enveloppée pour chaque appareil certifié de chaque membre, y compris
  les autres appareils du créateur. L'engagement de clé (annexe A.3) accompagne
  chaque enveloppe, et chaque enveloppe est signée par l'appareil créateur.
- **Destinataires** : le serveur accepte toute liste qui forme un
  sous-ensemble des appareils non révoqués des membres actuels. Il n'impose
  pas sa propre liste, puisque le client décide (§1.2). Une époque vise au
  plus 500 appareils, ce qui tient avec son manifeste dans la limite de
  512 Kio par requête.
- L'époque est **acceptée** par comparaison-échange sur le numéro courant.
  Le client envoie `previousEpochNumber`. Si une autre époque a été acceptée
  entre-temps, le serveur répond `409 E2EE_EPOCH_STALE` avec l'époque
  acceptée.
  - Un client n'utilise une époque qu'**après** son acceptation.
  - En cas de conflit, il adopte l'époque acceptée et recommence si une
    rotation reste nécessaire.
  - Les exigences de rotation du serveur (§3.3) sont marquées résolues dans
    la transaction qui accepte l'époque.

### 3.2 Nouvelle conversation, nouveaux membres, nouveaux appareils

- Une conversation chiffrée v2 est **créée avec son époque 1** dans la même
  requête : le serveur ne génère aucune clé. La conversation est alors v2 pour
  toujours (§12).
- Dès qu'une conversation est v2, le serveur refuse toute écriture v1 :
  partage de clé v1, demande de resynchronisation v1, message v1.
- Un membre sans appareil certifié est « en attente » : il reçoit l'époque
  courante dès qu'un appareil membre la lui enveloppe. Il ne reçoit jamais une
  clé du serveur.
- Un appareil nouvellement certifié ne reçoit que les époques **créées après
  son approbation**. L'historique antérieur passe par un transfert explicite
  depuis un appareil du même compte, ou par la récupération.

### 3.3 Rotation

- **La décision appartient au client** : si les destinataires de l'époque
  courante diffèrent de l'ensemble actuel des appareils certifiés des membres
  actuels, le client crée une époque avant tout envoi.
- Déclencheurs :
  - appareil certifié ajouté, révoqué ou mis à l'écart (§12) ;
  - membre ajouté ou retiré. Celui qui retire un membre crée l'époque
    suivante aussitôt, sans attendre un envoi ; après un départ, le premier
    membre restant qui l'apprend le fait ;
  - réglage « exclure les navigateurs » modifié ;
  - réinitialisation d'identité, usage de la récupération ;
  - au plus tard, 30 jours ou 10 000 messages par époque. Les 30 jours se
    comptent depuis l'acceptation locale de l'époque, jamais depuis la date
    que son créateur a signée.
- Le serveur publie aussi des exigences de rotation (confort). Leur absence ne
  dispense jamais un client de la règle ci-dessus.
- Un membre sans appareil certifié ne bloque pas une rotation : il est exclu de
  l'époque, et le reçoit dès qu'il a un appareil certifié.

### 3.4 Réception

Un client rejette un message :

- signé par un appareil révoqué, ou dont le certificat ne se vérifie pas ;
- chiffré sous une époque marquée compromise, s'il est postérieur à la date de
  compromission ;
- chiffré sous une époque qui n'est plus la courante depuis plus de 24 heures
  (fenêtre de tolérance pour les messages en vol) ;
- envoyé par un membre parti (retrait ou départ) plus de 24 heures après que
  l'appareil a appris ce départ, même sous l'époque courante.

Les 24 heures se comptent à l'horloge de l'appareil, depuis l'acceptation
locale de l'époque suivante ou du changement d'appartenance.

### 3.5 Manifeste d'époque

Le manifeste permet à chaque destinataire de vérifier qui reçoit l'époque, et
sur quel état d'appartenance repose cette liste. Il permet aussi à un appareil
qui n'a pas reçu l'époque, par exemple un nouvel appareil, de constater qu'une
conversation est v2 (§12).

- Ligne de destinataire : `<userId>\n<deviceId>\n<platform>\n<empreinte>`, où
  `empreinte = b64url(SHA-256(identityKey ‖ signingKey))` (§2.3). Lignes triées
  par `userId` puis `deviceId`, dans l'ordre des octets UTF-8. Lecture
  stricte : quatre champs, plateforme de l'ensemble fermé (D.2), empreinte au
  format d'un condensat, un appareil par ligne, de 1 à 500 lignes.
- `recipientsDigest = b64url(SHA-256("SQ-E2EE-V2-EPOCH-RECIPIENTS\n1" ‖ ("\n" ‖ ligne)*))`.
- Chaîne signée par l'appareil créateur, format 2 (v0.4.7) :
  `SQ-E2EE-V2-EPOCH-MANIFEST\n2\n<conversationId>\n<epochNumber>\n<creatorUserId>\n<creatorDeviceId>\n<keyCommitmentB64>\n<recipientCount>\n<recipientsDigest>\n<excludesWeb>\n<membershipChangeNumber>\n<membershipDigest>\n<createdAtMs>`,
  où `excludesWeb` vaut `0` ou `1`. Le format 1, sans état d'appartenance,
  n'a jamais servi à l'exécution : il est retiré. Toute autre version est
  refusée.
- **État d'appartenance** (D.4) : `membershipChangeNumber` (au moins 1) est
  le dernier changement pris en compte. `membershipDigest` est le
  `previousChangeDigest` qu'aurait le changement suivant :
  `b64url(SHA-256(octets UTF-8 de sa chaîne))`, sans saut de ligne final ni
  remplissage (D.0). Les changements étant chaînés, ce condensat engage tout
  le préfixe.
- **Époque 1** : la genèse est exactement les changements 1 à
  `membershipChangeNumber`, de la forme stricte de D.4. Ils sont tous signés
  par `creatorDeviceId`, et `creatorUserId` fait partie des membres.
  - Un appareil mémorise le premier manifeste d'époque 1 vérifié pour une
    conversation, et refuse tout autre (§12).
  - Sans manifeste d'époque 1, aucun changement n'est traité comme genèse :
    le client échoue fermé. Le serveur sert ce manifeste à tout membre,
    quelle que soit l'époque de son arrivée.
- **Vérification par chaque destinataire** :
  - il relit la chaîne d'appartenance jusqu'à `membershipChangeNumber`, après
    avoir synchronisé une chaîne locale plus courte, puis compare le
    condensat : un écart est refusé ;
  - le numéro ne recule jamais d'une époque acceptée à la suivante ; il peut
    rester égal (rotation d'appareil, 30 jours) ;
  - l'époque 1 repose sur toute la genèse (`membershipChangeNumber` égal à
    sa longueur), et aucune autre sur une genèse partielle ;
  - le créateur et chaque destinataire sont membres à cet état ;
  - la ligne de l'appareil qui lit est exactement son appareil certifié
    (utilisateur, plateforme, empreinte) ;
  - `excludesWeb` égale l'état de la chaîne à ce numéro, et le manifeste n'a
    aucune ligne `web` quand il vaut `1` ;
  - un appareil certifié d'un membre absent de la liste est signalé, pas
    refusé : sa certification a pu suivre la création de l'époque.
- **Genèse gardée** : l'appareil garde la chaîne avant la genèse, et ne garde
  rien tant que toute la chaîne n'est pas relue. À chaque passage, il exige
  que la chaîne gardée reproduise la genèse enregistrée (longueur, condensat
  de son dernier changement, auteur). La partie gardée ne se revérifie pas
  contre l'annuaire du jour : un auteur révoqué depuis ne casse pas la
  relecture.
- **Premier contact** (limite, v0.4.7) : un appareil qui découvre une
  conversation se fie à la première genèse vérifiée que le serveur lui sert.
  Un serveur malveillant peut ainsi présenter une conversation divergente à un
  nouvel arrivant. Parades prévues côté app : genèse (auteur, administrateurs)
  et « qui m'a ajouté » en messages système vérifiés, annuaire limité aux
  membres affichés, numéros de sécurité (§2.4).
- Le serveur stocke le manifeste, sa signature et la liste des lignes. Il les
  sert avec l'époque, y compris à un appareil qui n'en est pas destinataire.
  Dans la transaction qui accepte une époque, il refuse un
  `membershipChangeNumber` qui n'est pas le dernier changement accepté :
  `409 E2EE_MEMBERSHIP_STALE`, avec l'état courant. Sinon, un membre tout
  juste retiré recevrait encore la clé.
- Alphabets : `keyCommitmentB64` en base64 standard avec remplissage,
  `recipientsDigest` et `membershipDigest` en base64url sans remplissage
  (D.0).
- Vecteurs : `epoch-manifest-v2` (format, DER non canonique compris) et
  `epoch-binding-v1` (liaison à la chaîne, cas négatifs compris).

---

## 4. Messages

Format existant, v1 de l'enveloppe : annexe A.4. Vecteur :
`message-envelope-v1.json` (à corriger : sa charge doit être une charge
`signalquest.e2ee-content` valide).

### 4.1 Chiffrement et signature

- Clé de message = HKDF-SHA256 de la clé d'époque, avec un **sel
  déterministe** lié à `(conversation, époque, appareil, clientRequestId)`
  (annexe A.4). Nonce aléatoire de 96 bits.
- L'AAD est une chaîne canonique (annexe A.4). Elle lie l'engagement d'époque,
  le TTL et le condensat des blobs, mais **pas le type de contenu** : le `kind`
  voyage uniquement dans la charge chiffrée.
- **Chiffrer puis signer** : la signature ECDSA de l'appareil couvre l'AAD, le
  nonce et le chiffré, dans leur **forme textuelle base64 exacte**. Le serveur
  stocke et renvoie ces chaînes à l'octet près.
- Signatures en **forme low-S** : le signataire normalise (`s → n − s`), et le
  vérificateur rejette toute signature high-S (§15).
- Le destinataire vérifie la signature et le certificat **avant** de
  déchiffrer.

### 4.2 Identité d'un message

- Identité canonique : `(conversationId, senderDeviceId, clientRequestId)`.
- Référence : `messageRef = b64url(SHA-256("SQ-E2EE-V2-MESSAGE-REF\n1\n<conversationId>\n<senderDeviceId>\n<clientRequestId>"))`.
  C'est elle, et non un identifiant du serveur, que visent réponses, éditions,
  suppressions, réactions et votes (charge v2, §5.2).
- **Déduplication** sur l'identité canonique, conservée à vie : le serveur
  refuse un doublon, et le client garde le premier vu. Deux charges signées
  différentes pour la même identité sont une **équivoque** : elles sont
  signalées à l'utilisateur, et aucune n'est affichée.

### 4.3 Ordre et trous (enveloppe v2)

- La charge v2 porte `sentAtMs` (horloge de l'appareil) et un **compteur
  monotone par appareil et par conversation**. Le compteur figure aussi dans
  l'AAD de l'enveloppe v2.
- Un client qui voit un trou dans le compteur d'un appareil l'affiche (« des
  messages de X n'ont pas été reçus »).

### 4.4 Métadonnées visibles du serveur

| Donnée | Visible | Remarque |
|---|---|---|
| Conversation, membres, appareils | oui | nécessaires au routage |
| Expéditeur (appareil), horodatage serveur | oui | |
| Numéro d'époque, engagement de clé | oui | |
| Taille du chiffré | par paliers | bourrage de l'enveloppe v2 (§4.5) |
| Nombre de blobs, taille des blobs | par paliers | Padmé (§6.4) |
| TTL (messages éphémères) | oui | lié dans l'AAD |
| Type de contenu, réponse citée, mentions | **non** | dans la charge chiffrée |
| Participants d'un appel, durée | oui | le média reste chiffré |

### 4.5 Bourrage (enveloppe v2)

Clair = `charge ‖ 0x80 ‖ 0x00…` jusqu'au palier suivant (256 octets jusqu'à
4 Kio, puis puissances de deux). Le destinataire retire le bourrage et rejette
toute forme invalide. Vecteurs dédiés.

---

## 5. Charge utile (`signalquest.e2ee-content`)

### 5.1 Version 1 (existante)

Schéma exact : annexe A.6. Vecteur : `content-payload-v1.json`. Types :
`TEXT`, `EDIT`, `REACTION`, `DELETE`, `MEDIA`, `AUDIO`, `LOCATION`,
`LIVE_LOCATION`, `CARD` (`SPEEDTEST`, `RADIO`, `DRIVE_TEST`), `POLL`,
`POLL_VOTE`, `TASK`. Clés exactes, tailles bornées, `targetMessageId` au format
d'identifiant opaque.

### 5.2 Version 2 (proposée)

Changements, chacun avec ses vecteurs, dont des vecteurs négatifs :

- cibles et réponses par `messageRef` (§4.2) au lieu d'un identifiant serveur ;
- `sentAtMs` et compteur par appareil (§4.3) ;
- clé de franking en tête du clair (§11) ;
- `AUDIO` : forme d'onde (64 octets en base64) ;
- `MEDIA` et `AUDIO` : miniature en **manifeste imbriqué** `thumbnail`, comptée
  dans la limite de 20 manifestes ;
- `POLL_CLOSE` (cible = `messageRef` du sondage) ;
- réactions : emoji normalisé (§8) ;
- `CARD` : type `SITE` (fiche d'antenne) et `POST` (publication partagée) ;
- longueurs comptées en octets UTF-8 (§15).

Un client qui reçoit une version ou un `kind` inconnu affiche « Contenu non pris
en charge : mets à jour l'app » et n'interprète rien.

### 5.3 Autorisations

Elles sont vérifiées par chaque client, par **utilisateur** certifié (tous ses
appareils), jamais par appareil :

- `EDIT`, `DELETE` et `POLL_CLOSE` : seul l'auteur du message visé ;
- `TASK` : création par tout membre ; changement de statut par l'auteur ou un
  assigné ;
- une action non autorisée est ignorée et journalisée localement, sans contenu.

---

## 6. Photos, vidéos et fichiers (blobs)

Format exact : annexe A.5. Vecteur : `blob-chunks-v1.json`.

### 6.1 Chiffrement

- Une clé de média aléatoire de 32 octets par fichier. La clé de morceau en est
  dérivée par HKDF, liée au `blobId` (annexe A.5).
- `blobId` : 128 bits aléatoires encodés au format opaque. Le serveur refuse un
  doublon.
- Morceaux de 256 Kio. Le nonce est un préfixe aléatoire de 8 octets suivi d'un
  compteur 32 bits big-endian. L'AAD de chaque morceau lie `blobId`,
  l'algorithme, l'index, la longueur claire du morceau et `FINAL` ou `MORE`.
- **Découpage** calculé depuis `plaintextSize` : un fichier vide donne un seul
  morceau `FINAL` de 0 octet ; un multiple exact de 256 Kio ne donne pas de
  morceau vide ; tout octet après le morceau `FINAL` est rejeté.
- Chiffrement en flux, fichier vers fichier.

### 6.2 Manifeste

Clés exactes : annexe A.5 (tailles en chaînes décimales, condensats SHA-256
du clair et du chiffré). Les deux condensats sont **vérifiés avant tout
affichage**, et dans l'outil de modération.

### 6.3 Transport

- Routes :
  1. `POST /api/e2ee/v2/blobs` ;
  2. `PUT /blobs/{id}/parts/{n}`, par parts de 5 à 8 Mio, la dernière pouvant
     être plus petite ;
  3. `POST /blobs/{id}/complete` ;
  4. `GET /blobs/{id}/download`, qui donne une URL signée de courte durée
     pour l'hôte public.
- Les blobs chiffrés sont rangés sous un **préfixe privé**, jamais servi par
  une URL publique non signée.
- Le serveur stocke des octets opaques. Il NE DOIT PAS inspecter, redimensionner
  ni transcoder. Un blob non référencé sous 24 heures est supprimé, sauf s'il
  est gelé par un signalement (§11).
- Un message n'est accepté que si ses blobs sont complets et ont été créés par
  le **même appareil émetteur**.
- **Purge** : la suppression chiffrée (`DELETE`) est invisible du serveur.
  L'émetteur envoie donc aussi une **demande de purge signée** (requête
  signée, annexe A.2) qui cite les `blobId` du message supprimé. Cette
  demande et l'expiration du TTL purgent chiffrés et blobs, sauf gel par un
  signalement.

### 6.4 Côté client

- Tailles publiées par paliers Padmé : bourrage chiffré, retiré à la lecture.
- File d'envoi durable : chiffré sur disque, clé de média dans le trousseau
  jusqu'à l'envoi.
- Déchiffrement vers un fichier temporaire protégé, exclu des sauvegardes
  (iOS : `NSFileProtectionComplete` ; Android : stockage privé de l'app,
  sauvegarde désactivée). Il n'est affiché qu'après vérification des
  condensats. La lecture progressive d'une vidéo est permise morceau par
  morceau, puisque chaque morceau est authentifié. Tout est purgé à la
  déconnexion et à la révocation.
- Transférer un fichier vers une autre conversation le **rechiffre** avec une
  nouvelle clé de média.
- Limites :
  - 100 Mio par fichier et 200 Mio par message, plus un quota par compte fixé
    avec la capacité disque (décision du 30/09). Le format admet jusqu'à
    512 Mio (annexe A.5) ;
  - au-delà de 50 Mio en données mobiles, une confirmation est demandée ;
  - en itinérance, quand la plateforme sait la détecter (Android), le
    téléchargement automatique se fait en Wi-Fi seulement, par défaut ;
    iOS ne sait pas la détecter, il s'en tient à la confirmation et au Mode
    données réduites.

---

## 7. Notes vocales

- `AUDIO` : manifeste du blob audio (AAC-LC en M4A, recommandé partout),
  `durationMs`, forme d'onde (charge v2) et transcription facultative.
- La transcription se fait **uniquement sur l'appareil**. Le serveur NE DOIT PAS
  transcrire une note d'une conversation chiffrée, v1 comprise.

---

## 8. Réactions

- `REACTION` : cible, emoji, `ADD` ou `REMOVE`.
- Emoji : **un seul** emoji RGI, pleinement qualifié (avec `FE0F`), en NFC, de
  32 octets UTF-8 au plus. La référence est la liste `emoji-test.txt`
  d'**Unicode 15.1** (statut `fully-qualified`), embarquée par chaque client,
  puisque Android n'offre pas d'API avant l'API 33. Tout autre emoji est
  rejeté.
- Agrégation par `(utilisateur, cible, emoji)`. `ADD` et `REMOVE` sont
  idempotents, et le dernier événement de cet utilisateur l'emporte.
- Notification : une notification générique, sans emoji, que l'extension
  précise après déchiffrement (§13).

---

## 9. Sondages

- `POLL` : question, 2 à 20 options avec des identifiants aléatoires,
  `multipleChoice`, `closesAt` facultatif.
- `POLL_VOTE` : cible, `optionIds`. Le dernier vote de l'utilisateur l'emporte,
  selon son compteur (§4.3). Un vote vide retire le vote. Un vote qui cite une
  option inconnue, ou plusieurs options quand `multipleChoice` est faux, est
  **ignoré en entier**.
- `POLL_CLOSE` (v2) : seul l'auteur peut clore. `closesAt` se juge sur
  l'horloge du serveur (horodatage de réception des votes).
- Décompte par les clients. Les votes ne sont pas anonymes entre membres.

---

## 10. Appels audio et vidéo

### 10.0 Règles d'usage (décision produit du 30/09)

- **Conversation v2** : un appel est toujours chiffré de bout en bout.
  - Si un appareil certifié d'un membre n'a pas la capacité « appels
    vérifiés » (§12), l'appel est indisponible, avec « Un membre doit mettre à
    jour SignalQuest ». Jamais de repli en transport seul.
  - Un membre sans appareil certifié (app trop ancienne) ne compte pas dans
    l'intersection. Il ne sonne pas et ne peut pas rejoindre.
- **Conversation v1** (ancien chiffrement, clé connue du serveur) : l'appel
  reste possible, protégé pendant le transport seulement.
  - L'appelant voit d'abord la confirmation « Appel non chiffré de bout en
    bout » ; un appel reçu porte la même mention.
  - Le serveur ne marque jamais un appel de conversation v1 comme chiffré.
- **Exigence** : le jalon A (§16) livre les appels chiffrés sur iOS, Android et
  le web avant la prochaine bêta TestFlight iOS.

### 10.1 Descripteur d'appel

- `callId` est **choisi par l'appelant** : 128 bits aléatoires au format
  opaque (annexe A.1). Le serveur refuse un `callId` déjà utilisé
  (`409 CALL_ID_TAKEN`). Le descripteur peut ainsi le contenir dès l'appel
  d'initiation.
- L'appelant crée un **descripteur signé par son appareil** :
  `SQ-E2EE-V2-CALL-DESCRIPTOR\n1\n<conversationId>\n<callId>\n<callerDeviceId>\n<epochId>\n<epochNumber>\n<keyCommitmentB64>\n<callNonceB64>\n<createdAtMs>`,
  où `callNonce` est un aléa de 32 octets.
- Le serveur relaie le descripteur tel quel, dans une **nouvelle clé JSON**
  `e2eeV2` (`descriptor`, `signatureB64`, `callerDeviceId`, annexe D.11) :
  - dans la réponse d'initiation ;
  - dans la notification VoIP ou FCM ;
  - dans `/api/calls/pending`.

  Il ne remplit jamais les anciennes clés `e2ee` et `e2eeRequired`, pour
  rester compatible avec les apps déjà publiées. Il enregistre le
  descripteur, sa signature, l'appareil appelant et le `callNonce` (unique).
- Pour un appel chiffré, le serveur ne fait sonner, et ne délivre de jeton
  LiveKit, qu'aux appareils certifiés dotés de la capacité « appels vérifiés ».
- L'appelé vérifie la signature et le certificat de l'appelant, puis refuse :
  - une époque qui n'est pas la **plus récente active** qu'il connaît ;
  - pour une sonnerie, un descripteur de plus de 60 secondes. Pour une
    jonction tardive ou un transfert, le descripteur est accepté tant que le
    serveur donne l'appel pour actif, sous la même règle d'époque, et au plus
    12 heures après sa création : un ancien appel ne peut pas être rejoué ;
  - un `callId` que l'appareil a déjà vu se terminer : il le garde sur le
    disque avec ses nonces, et ne le rejoint plus jamais ;
  - un `callNonce` déjà vu pour un autre `callId`. Le serveur refuse lui
    aussi un `callNonce` déjà enregistré (`409 CALL_NONCE_TAKEN`).

### 10.2 Clé de trame

- Clé = HKDF-SHA256 de la clé d'époque, avec le sel
  `SHA-256("SQ-E2EE-V2-CALL-FRAME-SALT\n2\n<conversationId>\n<epochNumber>\n<callId>\n<callNonceB64>")`
  et l'info `signalquest-e2ee-v2-call-frame-key-v2` : 32 octets. La version 1
  existante (sans `callNonce`, annexe A.7) est remplacée, avec un nouveau vecteur
  `call-frame-key-v2`.
- Aucune clé ne transite.

### 10.3 Réglages LiveKit figés, sur les trois SDK

SDK de référence : `client-sdk-swift` 2.17.0 (2.15.0 au moins, première
version qui expose `discardFrameWhenCryptorNotReady` et
`keyDerivationAlgorithm`), `livekit-android` 2.27.0, `livekit-client` (JS)
2.18.x. Chaque changement de version refait le vecteur et l'appel croisé.

- **Tous les réglages sont posés explicitement**, jamais laissés aux défauts,
  qui diffèrent d'un SDK à l'autre.
- Mode clé partagée. Passphrase = la **chaîne** UTF-8 base64 standard de 44
  caractères de la clé de trame. Android : `setSharedKey(String)`. Web : une
  chaîne et non un `ArrayBuffer`, sans quoi la dérivation change.
- `keyDerivationAlgorithm = PBKDF2` et `ratchetSalt = "LKFrameEncryptionKey"`,
  explicites. Le nombre d'itérations et la taille effective de la clé AES
  sont établis par le vecteur `livekit-shared-key-v1`. Swift et Android le
  produisent (export de la clé), le web le vérifie par l'appel croisé.
- `ratchetWindowSize = 0`, `keyRingSize = 16`, `encryptionType = gcm`,
  `discardFrameWhenCryptorNotReady = true`, et `failureTolerance` à une même
  valeur explicite partout : 10, proposée par iOS dans le ticket COM-1
  (annexe C) et confirmée par Android (même code natif, même sens), à
  confirmer par le web. Les défauts d'Android diffèrent sur trois points
  (`ratchetWindowSize` 16, `failureTolerance` -1,
  `discardFrameWhenCryptorNotReady` faux) : d'où la règle de tout poser.
- **Marqueur « non chiffré »** (`uncryptedMagicBytes`) et **SIF** :
  - selon l'implémentation, un marqueur vide peut désactiver le passage en
    clair, ou au contraire faire passer toute trame pour non chiffrée ;
  - la valeur n'est figée qu'après un test, sur chaque SDK, prouvant qu'une
    trame non chiffrée injectée n'est **jamais rendue** ;
  - d'ici là, la valeur explicite est `LK-ROCKS`.
- **Un appel garde l'époque de son descripteur.** L'index de clé des médias
  n'est pas pilotable dans tous les SDK : on ne change donc pas de clé
  pendant un appel.
  - Un changement qui imposerait une nouvelle époque met fin à l'appel :
    membre ou appareil retiré, révoqué ou mis à l'écart. L'app affiche
    « L'appel a pris fin : la conversation a changé de clé ». Au plus tard,
    le client y met fin dès qu'il enregistre une époque plus récente pour la
    conversation de l'appel.
  - L'appel peut être relancé sous la nouvelle époque.
  - `ratchetKey` est interdit.
- **SIF** : les trois SDK appliquent d'office celui du serveur, à chaque
  réponse de jonction. Il est neutralisé par **32 octets aléatoires**, inconnus
  du serveur, posés après chaque jonction, ou par un correctif du SDK ; jamais
  par une valeur vide, que les SDK JS (livekit-client 2.18) et Android (2.27)
  ignorent en gardant l'ancien marqueur. Le test négatif de COM-1 le prouve.
  - Le SDK Swift le repose à chaque réponse de jonction, donc à chaque
    **reconnexion complète**, qui réintègre aussi les participants sans
    événement. Un appel chiffré prend donc fin dès le début d'une reconnexion
    complète ; une reconnexion rapide le laisse continuer.
  - Une reconnexion rapide garde les chiffreurs. Ceux-ci ne réannoncent
    « OK » qu'après une erreur (constaté avec Swift 2.17.0) : leurs états
    restent valables et ne sont jamais remis à zéro, sans quoi l'appel ne
    redeviendrait jamais vérifié.
- **Canal de données chiffré** sur les trois SDK. Un paquet non chiffré est
  refusé. La preuve de jonction y passe.
- Un SDK qui ne permet pas ces réglages n'offre pas d'appel chiffré : il est
  monté de version ou corrigé. En Swift, les deux derniers réglages existent
  depuis 2.15.0 ; iOS est passé à 2.17.0, qui corrige aussi le chiffrement du
  canal de données (COM-1). Le marqueur SIF reçu à chaque jonction y est
  remplacé par 32 octets aléatoires dès la jonction terminée.

### 10.4 Vérification et fermeture par défaut

- Un appel dans une conversation v2 **est** chiffré. Le client le vérifie
  localement (§12) : il ne rejoint jamais en clair une conversation qu'il sait
  chiffrée, quoi que dise le serveur. Le serveur peut rendre le chiffrement
  obligatoire, jamais le retirer : une notification qui annonce un appel
  chiffré ne redescend pas en clair sur la foi de `pending`.
- **Fin d'appel** : à la moindre perte de confiance, le média s'arrête avant
  tout aller-retour réseau ; le serveur n'est prévenu qu'ensuite.
- **Ordre de démarrage** :
  - aucune piste locale (micro, caméra) n'est publiée avant que la clé de
    trame soit posée ;
  - elle n'est publiée que chiffrée, avec `encryptionType` = `gcm` vérifié
    sur la publication ;
  - une piste locale que le serveur annonce non chiffrée est retirée
    aussitôt, et l'appel se termine ;
  - le SDK Swift n'attache le chiffreur qu'après la réponse du serveur à la
    publication, alors que la négociation peut partir avant : une piste est
    donc publiée muette, puis réactivée seulement une fois sa publication en
    `gcm` et son chiffreur dans l'état « OK » ;
  - une piste distante n'est jouée qu'une fois son participant prouvé (§10.4,
    preuve de jonction) et son chiffreur dans l'état « OK ». Un participant qui
    part puis revient garde l'heure de sa première arrivée pour le délai de
    10 secondes.
- Toute piste distante non chiffrée est refusée : désabonnement et fin de
  l'appel.
- Une piste n'est rendue que lorsque son cryptor est dans l'état « OK ».
  - Sous Android, l'état `E2EEState` vaut `NEW`, `OK`, `KEY_RATCHETED`,
    `MISSING_KEY`, `ENCRYPTION_FAILED`, `DECRYPTION_FAILED` ou
    `INTERNAL_ERROR`. Swift et JS ont les mêmes états sous d'autres noms.
  - `NEW` attend l'état « OK ».
  - `KEY_RATCHETED` ne doit pas survenir, puisque le ratchet est interdit. Il
    est traité comme une erreur.
- **Identité LiveKit** : dans un appel chiffré, le serveur émet le jeton pour
  un appareil certifié, authentifié par requête signée, jamais pour le compte
  seul. L'identité vaut `<userId>.<deviceId>` ; le « . » est hors de
  l'alphabet opaque (A.1), la découpe est donc sans ambiguïté. Deux appareils
  d'un même compte peuvent ainsi rejoindre le même appel sans s'éjecter. Les
  appels en clair gardent l'identité du compte, pour les apps installées.
- **Preuve de jonction** : à la jonction, chaque participant envoie une
  preuve signée par son appareil, qui lie son identité LiveKit à son appareil
  certifié.
  - Chaîne signée :
    `SQ-E2EE-V2-CALL-JOIN\n1\n<conversationId>\n<callId>\n<callNonceB64>\n<livekitIdentity>\n<userId>\n<deviceId>\n<joinedAtMs>`.
  - Elle est envoyée dès la jonction, sur le canal de données chiffré
    (§10.3), sujet `sq.e2ee.join`, en paquet fiable (annexe D.11). Android :
    `DataPacketCryptorManager`.
  - Un nouvel arrivant n'a pas reçu les preuves déjà envoyées. Chaque
    participant lui adresse donc la sienne : à son arrivée, puis en réponse à
    sa première preuve valide, qui montre que son canal fonctionne. Après une
    reconnexion complète, le participant diffuse de nouveau sa preuve.
    `joinedAtMs` reste celui de sa jonction ; une preuve reçue deux fois est
    sans effet.
  - Le serveur peut perdre un paquet envoyé avant d'avoir annoncé un
    participant, ce qui prend jusqu'à environ 3 secondes (constaté avec
    livekit-server 1.13.7). Chacun diffuse donc sa preuve à sa jonction et à
    chaque arrivée annoncée, puis la rediffuse 1, 2, 4 et 7 secondes plus
    tard. Les doublons sont sans effet.
  - Un paquet chiffré dont le serveur n'a pas encore annoncé l'émetteur est
    ignoré : ni accepté, ni motif de coupure. Un paquet en clair coupe
    l'appel, même d'un émetteur inconnu.
  - L'adressage n'est qu'une optimisation. Chiffré, un paquet porte ses
    destinataires dans sa charge : le SFU ne les voit pas et le diffuse à
    toute la salle (constaté dans Swift 2.17.0 et Android 2.27.0). Chacun
    traite donc toute preuve valide reçue, adressée ou non. On ne répond qu'à
    la première preuve valide d'une identité, ce qui borne les échanges.
  - La preuve passe, comme toute donnée d'un appel chiffré, par le canal de
    données chiffré, jamais en clair. Chaque plateforme active ce chiffrement
    (Android 2.27.0 : `dataChannelEncryptionEnabled = true`) et pose la clé
    avant la jonction : aucun arrivant n'attend la clé.
  - Le destinataire vérifie :
    - l'appel : `conversationId`, `callId` et `callNonceB64` ;
    - `livekitIdentity`, égale à l'identité de l'émetteur du paquet et à
      `<userId>.<deviceId>` de la preuve (une preuve où elle diffère est mal
      formée) ;
    - un appareil certifié d'un membre, doté de la capacité « appels
      vérifiés » (§12), jamais l'appareil local ;
    - la signature, en forme low-S.
  - Une preuve invalide met fin à l'appel aussitôt. L'identité portant
    l'appareil, elle n'en change jamais en cours d'appel.
  - Un participant sans preuve valide 10 secondes après son arrivée met fin
    à l'appel, avec « Appel chiffré impossible ».
  - Tant qu'un participant n'a pas prouvé son appareil, rien de lui n'est
    rendu ni remis à l'app, et le cadenas reste absent.
  - Le nom affiché d'un participant est celui de l'utilisateur prouvé, lu
    sur l'appareil parmi les membres de la conversation, jamais le nom du
    jeton LiveKit, que choisit le serveur. À défaut : « Participant ».
  - Vecteur : `call-join-proof-v1`.
- Les états d'erreur (clé manquante, échec de chiffrement ou de
  déchiffrement, erreur interne) retirent le cadenas et l'annoncent.
- Pas d'enregistrement composite, de transcription ni de résumé par le serveur
  pour un appel chiffré.
- Limite à écrire : avec une clé partagée, tout détenteur de l'époque peut
  écouter, y compris depuis un participant caché (jeton `hidden`). La clé ne
  sort pas du cercle des membres, mais n'authentifie pas l'émetteur d'une
  trame.
- Même limite pour les données : après déchiffrement, les SDK (Swift 2.17.0,
  Android 2.27.0) donnent comme émetteur l'identité écrite par l'émetteur
  lui-même dans le paquet chiffré. Un membre qui détient la clé peut donc
  attribuer un paquet à un autre participant.
  - Il ne peut pas usurper un appareil : la preuve est signée, et l'identité
    porte l'appareil.
  - Il peut faire échouer l'appel, par une preuve invalide attribuée à un
    autre comme par une trame mal chiffrée. La fermeture par défaut est
    gardée : un membre peut de toute façon interrompre un appel.

### 10.5 Discrétion

- Notification VoIP ou FCM d'une conversation v2 **sans nom d'appelant ni
  titre**. L'app retrouve le nom localement, parmi les membres de la
  conversation ; à défaut, elle affiche « Appel SignalQuest ».
- iOS : `includesCallsInRecents = false` pour un appel d'une conversation
  chiffrée, ce qui évite l'historique d'appels synchronisé par iCloud.
- Android : `ConnectionService` autogéré, exclu du journal d'appels
  (`EXTRA_LOG_SELF_MANAGED_CALLS = false`, API 34 et plus).
- Opus à débit constant.

---

## 11. Modération (franking)

But : pouvoir signaler un contenu chiffré sans remettre la clé de la
conversation, et sans permettre un faux signalement ni un message insignalable.

- **Envoi** : le clair de l'enveloppe commence par une clé de franking
  aléatoire `fk` (32 octets), suivie de la charge. L'AAD signée contient
  `frankTag = HMAC-SHA256(fk, "SQ-E2EE-V2-FRANK\n1\n<conversationId>\n<senderDeviceId>\n<clientRequestId>\n" ‖ charge)`.
- **Réception** : le destinataire DOIT recalculer `frankTag` après
  déchiffrement, et rejeter le message en cas d'écart. Il conserve `fk`.
- **Serveur** : pour **chaque message v2, dès le premier**, il calcule
  `serverTag = HMAC-SHA256(Ks, "SQ-E2EE-V2-SERVER-TAG\n1\n<frankTagB64>\n<conversationId>\n<envelopeId>\n<senderUserId>\n<senderDeviceId>\n<serverTimeMs>\n<keyId>")`.
  `serverTimeMs` est un entier décimal en millisecondes et `keyId` un
  identifiant opaque. Il remet `serverTag` avec le message, et le
  destinataire le conserve. Un message sans `serverTag` ne serait jamais
  signalable. `Ks` ne quitte jamais l'API.
- **Signalement** : 50 messages au plus. Le rapport a deux parties liées :
  - **Partie en clair** (JSON canonique, §15) : `reportId`,
    `conversationId`, `reason` et, pour chaque message, `envelopeId`,
    `frankTagB64`, `serverTagB64` et `blobIds`. Elle ne révèle rien que le
    serveur ne connaisse déjà.
  - **Partie scellée** en HPKE (RFC 9180, mode de base : DHKEM(P-256,
    HKDF-SHA256), HKDF-SHA256, AES-256-GCM) pour la clé de modération
    **épinglée dans les apps**.
    - `info = "SQ-E2EE-V2-REPORT\n1\n" ‖ b64url(SHA-256(partie en clair))`.
    - Elle contient, pour chaque message, la charge exacte, `fk` et les
      clés de média des blobs concernés.
    - Aucune clé d'époque n'est transmise.
- **API** : elle vérifie chaque `serverTag` avec `Ks`, et que le signaleur
  était membre au moment des messages (historique, §2.5). Elle gèle les blobs
  cités. La clé privée de modération n'est **jamais** dans son environnement.
- **Outil de modération**, isolé et seul détenteur de la clé privée. Décision
  du 30/09 : c'est un outil en ligne de commande, hors ligne, sur le poste de
  l'administrateur. La clé privée y reste, avec une sauvegarde hors ligne.
  Signalements et blobs gelés sont gardés 90 jours après la décision de
  modération. L'outil :
  - ouvre la partie scellée et vérifie que son `info` correspond à la partie
    en clair ;
  - recalcule chaque `frankTag` à partir de `fk`, de la charge, et de
    `senderDeviceId` et `clientRequestId` rendus par la route
    d'administration (E.3, v0.4.11) ;
  - vérifie les condensats des blobs, puis affiche.
- Les implémentations HPKE, y compris un sous-ensemble maison (Android, qui
  n'a pas d'HPKE public avant son API minimale 29), DOIVENT passer les
  vecteurs de la RFC 9180 pour cette suite.
- Contexte : le signaleur peut joindre des messages voisins, mais seulement
  des messages qu'il a lui-même reçus, chacun franké.
- Un message modifié se signale dans sa version affichée, sa dernière
  édition autorisée (même cible, même auteur), qui part toujours. Suivent,
  tant que le rapport tient (50 éléments, 512 Kio), son original puis ses
  éditions intermédiaires, de la plus récente à la plus ancienne, chacune
  frankée : la modération lit ce que le signaleur a vu, et un message n'est
  jamais insignalable parce qu'il a été trop modifié (v0.4.11).
- Un message supprimé par son auteur, ou un message éphémère expiré, n'est
  plus signalable : sa charge et celles de ses éditions sont effacées des
  appareils. C'est une limite assumée (v0.4.11).
- L'utilisateur est prévenu, avant d'envoyer, que les messages signalés seront
  lisibles par l'équipe de modération.
- Vecteurs : `franking-v1` (`frankTag` et `serverTag`) et `report-v1`.

---

## 12. Capacités et états collants

- **Document de capacités**, signé par la clé de signature de l'appareil (et
  non par l'UIK, qu'il faudrait autrement réutiliser à chaque mise à jour de
  l'app).
  - JSON canonique (§15) :
    - `schema` (`signalquest.e2ee-capabilities`), `version` (`"1"`),
      `userId`, `deviceId` ;
    - `sequence`, strictement croissante, et `issuedAtMs` ;
    - `envelopeVersions`, `payloadVersions`, `kinds` ;
    - `features` (`blobs`, `voice`, `calls`, `liveLocation`…).
  - Chaîne signée :
    `SQ-E2EE-V2-DEVICE-CAPABILITIES\n1\n<b64url(SHA-256(document))>`.
  - Republié à chaque mise à jour de l'app et au moins tous les 30 jours. Un
    client refuse un document de séquence inférieure au dernier vu.
  - Vecteur : `device-capabilities-v1`.
- **Capacité d'une conversation** = intersection des capacités des appareils
  certifiés des membres dont le dernier document a moins de 90 jours.
  - Seul le document signé compte, pour les clients comme pour le serveur.
    L'en-tête `X-SQ-Capabilities` ne compte plus pour la v2.
  - Appareils pris en compte : certifiés, non révoqués et non mis à l'écart,
    des membres actuels. Un navigateur compte seulement s'il est approuvé et
    si `excludesWeb` n'est pas actif. Un membre sans appareil certifié ne
    compte pas (§10.0).
  - L'âge d'un document se compte depuis son `issuedAtMs` : à 90 jours pile,
    il ne compte plus.
  - Un membre dont le paquet de confiance est refusé (§2.4) rend la capacité
    indisponible : ses appareils sont inconnus. Sans aucun appareil pris en
    compte, elle est indisponible aussi.
  - Vecteur : `capability-intersection-v1`.
- Un appareil sans document récent est **mis à l'écart** : il sort de
  l'intersection et des nouvelles époques (§3.3), jusqu'à ce qu'il publie un
  document à jour. Cette mise à l'écart, décidée par les clients, remplace
  une révocation automatique par le serveur, qui ne peut rien signer au nom de
  l'UIK. La révocation proprement dite reste signée par l'UIK.
- Une fonction absente de l'intersection est désactivée, avec « Un membre doit
  mettre à jour SignalQuest pour recevoir les photos chiffrées ». Jamais de
  repli en clair.
- **Le serveur ne refuse que ce qu'il voit**, avec
  `409 E2EE_CAPABILITY_MISSING` : version d'enveloppe, blobs, appels, partage
  de position. Les `kind` chiffrés (sondages, réactions…) sont contrôlés par
  les clients seulement. L'émetteur ne les envoie pas si l'intersection ne les
  contient pas. Un récepteur qui ne les connaît pas affiche « Contenu non pris
  en charge ».
- **États collants** :
  - « chiffrée » et « v2 » dérivent d'éléments signés (le manifeste de
    l'époque 1, signé par le créateur, §3.5), sont mémorisés par l'appareil,
    et aucune réponse serveur ne peut les faire régresser. Un état illisible
    vaut v2 : aucune clé, aucune migration ;
  - pour une conversation v2, l'envoi et les appels prennent la clé de
    l'époque courante vérifiée, lue par son numéro. Les chemins pilotés par le
    serveur (livraison sans manifeste, rotation vers la liste du serveur) ne
    touchent jamais une conversation v2 ;
  - un appareil qui découvre une conversation (nouvel appareil) se fie à ce
    manifeste signé, pas à un booléen du serveur ;
  - tout message v1 postérieur à l'époque 1 v2 est rejeté ;
  - un interrupteur de déploiement peut seulement **désactiver** une fonction,
    jamais repasser en clair ni en v1.

---

## 13. Surfaces fermées par défaut

Chaque surface a un test prouvant que rien ne sort en clair.

| Surface | Règle |
|---|---|
| Composeur (photo, micro, sondage, réaction, position) | désactivé si la conversation ne prend pas la fonction en charge |
| Messages programmés | désactivés dans les conversations v2 (décision du 30/09) ; gardés dans les conversations non chiffrées. Le rechiffrement à l'échéance par l'appareil émetteur pourra venir plus tard |
| Réponses en fil, citations, transferts | chiffrés ; transfert vers une conversation en clair refusé |
| Notifications push | titre et corps génériques, sans titre de conversation, nom ni emoji ; aperçu seulement après déchiffrement par l'extension ; rien si « aucun aperçu » |
| Réponse rapide (notification, réponse directe Android, montre, CarPlay, Android Auto, Siri) | chiffrée comme un message, sinon indisponible |
| Widgets, Live Activities, Spotlight, cibles de partage, Direct Share, tuiles de réglages rapides | aucun contenu déchiffré indexé ni affiché |
| Recherche | uniquement sur l'appareil |
| Rappels, notes privées | chiffrés avec une clé propre à l'utilisateur, ou gardés sur l'appareil |
| Aperçus de liens | générés sur l'appareil, au choix de l'utilisateur ; jamais par le serveur |
| Partage de position (anciennes routes) | refusé dans une conversation chiffrée |
| Export | chiffré, ou averti et confirmé ; jamais d'archive en clair silencieuse |
| Presse-papiers | local seulement, avec expiration (Android 13 et plus : contenu marqué sensible) |
| Sélecteur d'apps | instantané masqué (Android : `FLAG_SECURE` en option) |
| Sauvegardes système | clés et caches déchiffrés exclus, de façon normative |
| Journaux, Crashlytics, analytics | aucun contenu ni identifiant de message ; pas de clé dans `userInfo` |
| Transcription, résumé, enregistrement serveur | indisponibles |

**Côté serveur**, dans une conversation v2, toute route qui accepte du contenu
refuse l'écriture en clair. Sont concernées :

- les réactions, les votes et la clôture de sondage ;
- la transcription, l'enregistrement et le résumé ;
- les mises à jour du partage de position ;
- les pièces jointes, les réponses en fil et leurs métadonnées ;
- la recherche.

La garde porte sur la version de protocole de la conversation (≥ 2), sans
nouveau type de message. La transcription est refusée aussi dans les
conversations v1. Les autres refus y arrivent avec la hausse de version
minimale qui accompagne la bêta du jalon A (décision du 30/09).

---

## 14. Migration depuis la v1

1. Les conversations v1 restent lisibles, avec la mention « ancien chiffrement,
   clé connue du serveur » et sans cadenas.
2. À la première ouverture par un client v2, si tous les membres ont un appareil
   certifié, ce client crée l'époque 1 v2 : la conversation est alors v2 pour
   toujours (§12).
   - **Genèse de l'historique d'appartenance** (D.4) : ce client signe un
     `ADD` par membre actuel, lui compris, dans l'ordre des `userId` (octets
     UTF-8). Dans un groupe, il signe ensuite un `ROLE_ADMIN` pour chaque
     propriétaire ou administrateur v1 : « propriétaire » disparaît en v2.
   - Le serveur refuse une genèse qui ne reproduit pas exactement les membres
     et les administrateurs v1.
   - Un client ne peut pas vérifier les administrateurs v1 : la genèse de
     migration hérite de la confiance v1. L'app l'affiche en message système
     vérifié : « X a migré la conversation ; administrateurs : … ».
   - Une seule genèse est jamais signée par appareil et par conversation : le
     corps signé est gardé avant l'envoi et renvoyé tel quel, octet pour
     octet, à chaque nouvel essai.
3. La recopie de l'historique en v2 est facultative. Elle est faite par un
   appareil (vecteur `history-migration-v1.json`), jamais par le serveur. Les
   messages recopiés portent « importé par <appareil> » et n'héritent d'aucune
   authenticité.
4. Quand la v2 est activée, le serveur cesse toute génération de clé v1.
   Décision du 30/09 : au jalon A, donc avant la prochaine bêta TestFlight.
5. Une app sans v2 face à une conversation v2 ne reçoit pas les messages v2.
   Décision du 30/09 : elle affiche « Cette conversation utilise un
   chiffrement plus récent : mets à jour SignalQuest ».
   - Les apps publiées ne savent pas le faire seules. Le serveur leur sert ce
     texte en message système en clair, en dernier message et dans la liste.
     Il les reconnaît à leur User-Agent et à l'absence d'appareil v2.
   - Créer une conversation chiffrée depuis une telle app, une fois la
     clé v1 arrêtée : `409 E2EE_UPDATE_REQUIRED`, avec `error` =
     « Mets à jour SignalQuest pour créer une conversation chiffrée. ». Les
     builds 159 et 160 affichent ce texte tel quel.
   - Un tête-à-tête v2 déjà existant est renvoyé tel quel, avec ce message
     système.
6. Appels d'une conversation v1 : §10.0.

---

## 15. Encodages, vecteurs et interopérabilité

- Formats **existants** (annexe A) : chaînes canoniques séparées par `\n`,
  identifiants au format opaque (qui empêche d'y injecter `\n`), base64
  standard avec bourrage sauf mention « base64url sans bourrage ».
- Formats **nouveaux** :
  - JSON canonique RFC 8785 et I-JSON (RFC 7493) ;
  - **analyseur strict**, qui rejette clés dupliquées, substituts isolés et
    formes non canoniques (un analyseur permissif, comme `org.json`, ne
    convient pas) ;
  - **entiers en chaînes décimales** canoniques, comme les tailles de
    l'annexe A.5, pour éviter les écarts de sérialisation des nombres ;
  - limites en **octets UTF-8** ;
  - dates RFC 3339 en UTC à la milliseconde (`Z`) ;
  - un tableau « champ → encodage » par format.
- Cryptographie :
  - points P-256 en X9.63 non compressé (65 octets), validés explicitement
    (sur la courbe, pas l'infini) ;
  - Android convertit ses clés SubjectPublicKeyInfo en X9.63 ;
  - signatures ECDSA en DER, **forme low-S obligatoire** : le signataire
    normalise (le Keystore Android produit du high-S une fois sur deux
    environ) et le vérificateur rejette le high-S ;
  - trois vecteurs existants portaient une signature high-S. Ils sont
    réémis en forme low-S, avec le même contenu et `s` remplacé par `n − s` :
    `epoch-envelope-v1`, `recovery-epoch-envelope-v1`, `signed-request-v1` ;
  - conversion depuis `r‖s` pour WebCrypto.
- **Source unique des vecteurs** : `contracts/e2ee-v2/*.json`.
  - Les 13 vecteurs existants, une fois réémis, sont identiques à l'octet
    près dans les dépôts iOS, Android et serveur. Le serveur importe ceux qui
    lui manquent.
  - La CI vérifie les condensats contre `contracts/e2ee-v2/SHA256SUMS`, la
    référence des trois dépôts. Le web consomme les vecteurs du serveur.
- **Vecteurs existants** :
  - `blob-chunks-v1`, `call-frame-key-v1`, `content-payload-v1` (cas
    négatifs à ajouter) ;
  - `device-approval-v1`, `device-bootstrap-v1`, `epoch-envelope-v1` ;
  - `history-migration-v1`, `live-location-payload-v1` ;
  - `message-envelope-v1` (à corriger) ;
  - `recovery-bundle-v1`, `recovery-epoch-envelope-v1`, `recovery-proof-v2`,
    `signed-request-v1`.
- **À créer** :
  - identités : `device-cert-v1` (avec `keyVersion`), `device-list-v1`,
    `device-capabilities-v1`, `uik-wrap-v1`, `device-approval-v2`,
    `safety-number-v1`, `identity-reset-v1` ;
  - groupes et époques : `membership-change-v1`, `epoch-manifest-v2`,
    `epoch-binding-v1`,
    `capability-intersection-v1` ;
  - messages : `message-ref-v1`, `message-envelope-v2` (compteur, bourrage,
    franking), `content-payload-v2` ;
  - modération : `franking-v1` (`frankTag` et `serverTag`), `report-v1` ;
  - appels : `call-descriptor-v1`, `call-frame-key-v2`, `call-join-proof-v1`,
    `livekit-shared-key-v1`.
- Chaque plateforme exécute tous les vecteurs dans les deux sens, plus au moins
  un **vecteur négatif par règle** :
  - signature fausse, signature high-S ;
  - AAD altérée, engagement faux, tag de franking faux ;
  - morceau manquant, octets après `FINAL` ;
  - clé JSON dupliquée ;
  - époque obsolète, numéro d'époque qui saute ;
  - manifeste qui ne correspond pas aux enveloppes ;
  - descripteur d'appel rejoué.

---

## 16. Déploiement, quotas et exploitation

**Jalon A — appels chiffrés partout.** Condition de la prochaine bêta
TestFlight iOS, par décision produit du 30/09. Sur le serveur et les trois
clients :

- chaîne de confiance, récupération et réinitialisation d'identité ;
- identités d'appareil ;
- époques créées par les appareils : création v2, fin de la génération
  serveur des clés, manifestes, lignes témoins ;
- documents de capacités ;
- messages texte v2, avec franking dès le premier message ;
- signalement et outil de modération ;
- surfaces fermées pour le texte et les appels ;
- appels vérifiés ;
- navigateurs sur demande.

Critère de sortie :

- appel chiffré croisé iOS ↔ Android ↔ web, sur deux comptes, à deux puis à
  trois ;
- tests d'attaque du §17 réussis ;
- vecteurs au vert partout.

**Jalon B — médias et le reste.** Blobs (photos, vidéos, fichiers), notes
vocales, réactions et sondages v2, partage de position v2, recopie
d'historique. Tant qu'il n'est pas livré, ces fonctions restent désactivées
dans les conversations v2 par l'intersection des capacités. C'est déjà le cas
aujourd'hui (« texte uniquement »).

Ordre côté serveur, pour le jalon A :

0. Figer formats et vecteurs, et vérifier l'état de la base de production
   avant tout SQL, écrit idempotent.
1. Refuser tout de suite la transcription en conversation chiffrée.
2. Confiance, puis récupération et réinitialisation d'identité.
3. Époques, capacités, création v2, garde des routes v1.
4. Messages v2, avec `serverTag` dès le premier.
5. Refus du §13.
6. Signalement et outil de modération.
7. Appels.
8. Activation, conversation par conversation.

Les blobs et leur purge passent au jalon B.

Activation conversation par conversation, via l'intersection des capacités. Un
interrupteur ne peut que désactiver.

**Compatibilité des apps installées.** Leurs analyseurs des contrats v2 exigent
des clés exactes. À partir de la première version publiée qui ouvre les
verrous, le serveur n'ajoute donc jamais de champ à un contrat v2 publié. Une nouveauté passe par l'un de ces moyens :

- une nouvelle version de contrat ;
- une nouvelle route ;
- une nouvelle clé dans une réponse que les apps lisent de façon tolérante,
  comme `e2eeV2` dans les réponses d'appel.

Quotas (valeurs de départ, à ajuster) : 10 époques par conversation et par
heure ; 5 approbations d'appareil par compte et par jour ; 20 signalements par
compte signaleur, sur une fenêtre glissante de 24 heures, au-delà desquels la
réponse est 429 `E2EE_REPORT_QUOTA` ; `Retry-After` donne les secondes avant
que le plus ancien sorte de la fenêtre (v0.4.11).

Outbox : un message préparé sous une époque qui change avant l'envoi est
rechiffré, sa charge étant gardée dans le trousseau jusqu'à l'envoi. Un message
dont l'émetteur est révoqué est abandonné.

Télémétrie sans contenu : échecs de déchiffrement par type, versions de
protocole, états des cryptors d'appel.

---

## 17. Sécurité et gouvernance

- **Pas de revue externe**, ni générale ni ciblée (décisions produit du 29/09
  et du 30/09). En contrepartie :
  - **relecture indépendante** de cette spécification (faite pour la v0.1),
    puis de chaque implémentation, par un relecteur qui n'a pas écrit le
    code ;
  - vecteurs partagés, dont les vecteurs négatifs (§15) ;
  - fermeture par défaut tant qu'une preuve manque.
- **Ouverture des verrous** du chiffrement v2 dans les apps : seulement quand
  les critères de sortie du jalon A (§16) sont remplis. Ce sont les vecteurs,
  les tests croisés, les tests d'attaque et les relectures indépendantes. Il
  n'y a pas de revue externe.
- **Tests croisés** sur deux comptes et trois plateformes : chaque type de
  contenu, dans les deux sens, en ligne et hors ligne, avec ajout, révocation et
  réinitialisation d'appareil.
- **Tests d'attaque**, où le serveur :
  - ajoute un appareil, ou fournit une ancienne liste ;
  - désigne une ancienne époque pour un appel, ou rejoue un descripteur
    d'appel ;
  - injecte une trame non chiffrée ;
  - renvoie « non chiffrée » à un nouvel appareil ;
  - retire le marqueur « navigateur » d'un appareil ;
  - fait sonner un appareil sans capacité d'appel ;
  - rejoue un message.

  Chacun doit échouer, et le client doit l'annoncer.

---

## 18. Questions ouvertes

- **Époque compromise** (v0.4.7) : le §3.4 rejette un message chiffré sous
  une époque marquée compromise après la date de compromission, mais aucun
  format ne porte encore ce marquage. À définir avec la réinitialisation
  d'identité et la récupération.
- **`moderationKeyId`** (v0.4.7) : il n'est lié ni à la partie en clair ni à
  l'`info` HPKE. Un serveur qui le change ne fait qu'empêcher l'ouverture du
  rapport ; le lier demanderait une version 2 de `report-v1`.

- **Épingles d'un navigateur** (v0.4.10, pour la v0.5) : à l'approbation
  par QR, le téléphone transmettrait au navigateur ses épingles de contacts,
  vérifiées ou non, pour couvrir aussi le premier contact des contacts qu'il
  connaît. Deux exigences du serveur : la signature d'approbation couvre
  l'empreinte du paquet et un drapeau « épingles présentes », pour qu'il ne
  puisse être ni retiré ni rejoué ; le scellement est lié au compte, à
  l'identifiant du navigateur et au nonce du QR. Côté serveur, un champ
  opaque de plus, à taille plafonnée.

- **Pierres tombales des messages expirés** (v0.4.7) : un message éphémère
  purgé par le serveur laisse un trou dans les compteurs (E.3). Une pierre
  tombale (séquence, appareil, compteur, identité) éviterait la fausse
  alerte, mais elle ne se vérifie pas sans la signature : elle laisserait le
  serveur faire passer une rétention pour une expiration. À trancher avec le
  serveur.

Tranchées le 30/09 (décisions produit) :

1. Fin de la génération serveur des clés v1 : avec la v2, au jalon A, donc
   avant la prochaine bêta TestFlight (§14).
2. Appels :
   - dans les conversations v1, autorisés après la confirmation « Appel non
     chiffré de bout en bout » ;
   - dans les conversations v2, toujours chiffrés ;
   - chiffrés sur iOS, Android et le web avant la prochaine bêta (§10.0).
3. Revue externe ciblée : non (§17).
4. Navigateurs : sur demande, approuvés depuis un téléphone (§2.7).
5. Messages programmés : désactivés au départ dans les conversations v2 (§13).
6. Refus du §13 dans les conversations v1 : la transcription tout de suite,
   les autres avec la hausse de version minimale de la bêta du jalon A (§13).
7. App sans v2 face à une conversation v2 : invitation à mettre à jour
   (§14.5).
8. Outil de modération : en ligne de commande, hors ligne, sur le poste de
   l'administrateur, seul détenteur de la clé privée ; 90 jours de
   conservation après la décision (§11).
9. Origine statique du client web : après la bêta du jalon A (§2.7).
10. Médias chiffrés (jalon B) : 100 Mio par fichier, 200 Mio par message,
    quota par compte (§6.4).

Ouverte :

11. Évaluer MLS (RFC 9420, OpenMLS) pour une v3.

---

## Annexe A — Octets sur le fil (formats v1 existants)

Transcrits du code iOS (`SignalQuestApp/Core/Shared/E2EEV2NotificationContracts.swift`,
`SignalQuestApp/Services/E2EEService.swift`), qui reproduit les vecteurs. En cas
d'écart, **les vecteurs font foi**. Notations : `‖` concaténation, `\n` saut de
ligne (0x0A), `b64` base64 standard avec bourrage, `b64url` base64url sans
bourrage.

### A.1 Identifiants

- Identifiant opaque (conversation, appareil, blob, message cible, option,
  appel) : `^[A-Za-z0-9][A-Za-z0-9_-]{15,127}$`.
- `clientRequestId` : `^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$`.
- Nonce de requête : `^[A-Za-z0-9_-]{16,128}$` (24 octets aléatoires en
  b64url).

### A.2 Requête signée

Chaîne signée (ECDSA P-256, DER) :
`SQ-E2EE-V2\n<MÉTHODE>\n<cible>\n<timestampMs>\n<nonce>\n<b64url(SHA-256(corps))>`.

`<cible>` est le chemin plus la requête brute, sans ré-encodage. Elle :

- commence par `/` ;
- fait au plus 512 octets ;
- a au plus un `?` ;
- ne contient ni `#` ni `\n`.

En-têtes : `x-sq-e2ee-device-id`, `x-sq-e2ee-timestamp-ms`,
`x-sq-e2ee-nonce`, `x-sq-e2ee-signature`. Vecteur : `signed-request-v1`.

### A.3 Enveloppe d'époque (`P256_X963_ECDH_HKDF_SHA256_AES_256_GCM`)

- Engagement : `b64(SHA-256("SQ-E2EE-V2-EPOCH-COMMITMENT" ‖ 0x00 ‖ cléÉpoque))`.
- Sel : `SHA-256("SQ-E2EE-V2-EPOCH-SALT\n1\n<conv>\n<epochNumber>\n<senderDeviceId>\n<recipientDeviceId>")`.
- Clé d'enveloppe : HKDF-SHA256(ECDH(éphémère, clé d'accord du destinataire),
  sel, info `signalquest-e2ee-v2-epoch-wrap-v1`, 32 octets).
- AAD : `SQ-E2EE-V2-EPOCH-ENVELOPE\n1\n<conv>\n<epochNumber>\n<senderDeviceId>\n<recipientDeviceId>\n<engagementB64>\n<clePubliqueEphemereB64>`
  (clé publique éphémère X9.63 de 65 octets en b64).
- AES-256-GCM, nonce de 12 octets.
- Signature de l'appareil créateur sur :
  `SQ-E2EE-V2-EPOCH-ENVELOPE-SIGNATURE\n1\n<conv>\n<epochNumber>\n<senderDeviceId>\n<recipientDeviceId>\n<wrapAlgorithm>\n<engagementB64>\n<ephemereB64>\n<nonceB64>\n<aadB64>\n<wrappedEpochKeyB64>`.

### A.4 Enveloppe de message v1 (`AES_256_GCM_HKDF_SHA256`)

- Type : `application/vnd.signalquest.e2ee-envelope+json`, version 1.
- Condensat des blobs : `b64url(SHA-256("SQ-E2EE-V2-MESSAGE-BLOBS\n1" ‖ ("\n" ‖ blobId)*))`,
  20 blobs au plus, sans doublon.
- Sel : `SHA-256("SQ-E2EE-V2-MESSAGE-SALT\n1\n<conv>\n<epochNumber>\n<senderDeviceId>\n<clientRequestId>")`.
- Clé de message : HKDF-SHA256(cléÉpoque, sel, info
  `signalquest-e2ee-v2-message-key-v1`, 32 octets).
- AAD : `SQ-E2EE-V2-MESSAGE-ENVELOPE\n1\n<conv>\n<epochNumber>\n<senderDeviceId>\n<clientRequestId>\nAES_256_GCM_HKDF_SHA256\napplication/vnd.signalquest.e2ee-envelope+json\n<engagementB64>\n<ttlSeconds>\n<condensatBlobs>`.
- Signature de l'appareil sur :
  `SQ-E2EE-V2-MESSAGE-SIGNATURE\n1\n<conv>\n<epochNumber>\n<senderDeviceId>\n<clientRequestId>\nAES_256_GCM_HKDF_SHA256\napplication/vnd.signalquest.e2ee-envelope+json\n<engagementB64>\n<ttlSeconds>\n<condensatBlobs>\n<nonceB64>\n<aadB64>\n<ciphertextB64>`.

### A.5 Blobs (`AES_256_GCM_CHUNKED_HKDF_SHA256`)

- Sel : `SHA-256("SQ-E2EE-V2-BLOB-SALT\n1\n<blobId>")`.
- Clé : HKDF-SHA256(cléMédia de 32 octets, sel, info
  `signalquest-e2ee-v2-blob-key-v1`, 32 octets).
- Nonce du morceau `i` : `préfixe (8 octets) ‖ uint32_be(i)`.
- AAD du morceau : `SQ-E2EE-V2-BLOB-CHUNK\n1\n<blobId>\nAES_256_GCM_CHUNKED_HKDF_SHA256\n<i>\n<longueurClaireDuMorceau>\n<FINAL|MORE>`.
- Morceaux de 262 144 octets, tag de 16 octets, 512 Mio au plus.
- Manifeste, clés exactes :
  - `blobId`, `algorithm`, `mediaKeyB64`, `noncePrefixB64` ;
  - `cryptoChunkSize` (262 144) ;
  - `plaintextSize` et `ciphertextSize`, en chaînes décimales
    `^(0|[1-9][0-9]{0,11})$` ;
  - `plaintextSha256` et `ciphertextSha256`, en hexadécimal minuscule de 64
    caractères ;
  - `fileName` (≤ 512) et `mimeType` (≤ 255) ;
  - `width` et `height` (1 à 100 000, ou null) ;
  - `durationMs` (0 à 86 400 000, ou null).

### A.6 Charge `signalquest.e2ee-content` v1

Racine, clés exactes : `schema` (`signalquest.e2ee-content`), `version` (1),
`kind`, `replyToId` (opaque ou null), `mentions` (≤ 100 identifiants opaques),
`body`. Taille totale de 2 octets à 256 Kio. Encodage JSON à clés triées.

| kind | `body`, clés exactes |
|---|---|
| `TEXT` | `text` |
| `EDIT` | `targetMessageId`, `text` |
| `REACTION` | `targetMessageId`, `emoji` (1 à 32), `action` (`ADD`, `REMOVE`) |
| `DELETE` | `targetMessageId` |
| `MEDIA` | `caption` (≤ 16 Kio ou null), `attachments` (1 à 20 manifestes A.5, `blobId` uniques) |
| `AUDIO` | `caption`, `attachment` (manifeste), `durationMs`, `transcription` (null ou `{status, language, text, confidence}`, `status` ∈ `NONE`, `PENDING`, `COMPLETE`, `FAILED`) |
| `LOCATION` | `latitude`, `longitude`, `accuracyMeters`, `altitudeMeters`, `label` |
| `LIVE_LOCATION` | `sessionId`, `sequence`, `latitude`, `longitude`, `accuracyMeters`, `observedAt`, `expiresAt` (+ `altitudeMeters`, `speedMetersPerSecond`, `headingDegrees`, `radio` dans la forme étendue) |
| `CARD` | `cardType` (`SPEEDTEST`, `RADIO`, `DRIVE_TEST`), `cardVersion`, `payload` |
| `POLL` | `question` (1 à 2 000), `options` (2 à 20 `{id, label}`, `id` uniques), `multipleChoice`, `closesAt` |
| `POLL_VOTE` | `targetMessageId`, `optionIds` (≤ 20) |
| `TASK` | `taskId`, `title`, `status`, `dueAt`, `assigneeIds` (≤ 100) |

Limite connue de la v1 : ses longueurs se comptent en graphèmes, que Kotlin et
JavaScript ne comptent pas de la même façon. La charge v2 passe aux octets
UTF-8 (§15).

### A.7 Clé de trame d'appel v1

- Sel : `SHA-256("SQ-E2EE-V2-CALL-FRAME-SALT\n1\n<conv>\n<epochNumber>\n<callId>")`.
- Clé : HKDF-SHA256(cléÉpoque, sel, info `signalquest-e2ee-v2-call-frame-key-v1`,
  32 octets). Passphrase LiveKit : `b64(clé)`.
- Remplacée par la v2 du §10.2, qui ajoute `callNonce`.

---

## Annexe B — Estimation par plateforme

Ordres de grandeur en jours de développement, relecture et tests compris.
Base : l'existant de chaque plateforme.

- Serveur et Android : réestimés par leurs sessions après la v0.2.
- iOS et web : réestimés pour les ajouts de la v0.3 (document de capacités,
  manifeste, preuve de jonction, rapport en deux parties).

| Plateforme | Total | Jalon A | Détail |
|---|---|---|---|
| Serveur | ~53 | ~47 | voir liste ci-dessous |
| iOS | ~42 | ~35 | voir liste ci-dessous |
| Android | ~65 | ~55 | voir liste ci-dessous |
| Web | ~51 | ~43 | voir liste ci-dessous |

Détail par plateforme :

- **Serveur** :
  - confiance 7 ; récupération et réinitialisation 3 ;
  - époques, capacités et états 7 ; messages v2 6 ; blobs 6 ;
  - appels 4 ; franking et outil de modération 7 ; surfaces fermées 3 ;
  - migration 2 ; vecteurs, CI et tests d'attaque 5 ;
  - préalable production (base, tâches planifiées, secrets) 3.
  - Hors total : recopie d'historique +2, partage de position v2 +3. L'origine
    statique du web est un chantier d'infrastructure à part.
- **iOS** :
  - confiance 6 ; identités 2 ; époques et capacités 6 ; enveloppe et
    charge v2 6 ;
  - blobs 5 ; appels 5 ; franking 3 ; surfaces 3 ;
  - migration 3 ; vecteurs et tests 3.
- **Android** :
  - confiance 7 ; identités et stockage 9 ; époques 7 ; enveloppe et
    charge v2 10 ;
  - blobs 7 ; appels 7 ; franking 3 ; surfaces 6 ;
  - migration 4 ; vecteurs et tests 5.
- **Web** :
  - confiance 6 ; identités 6 ; époques et capacités 7 ; enveloppe et
    charge v2 7 ;
  - blobs 6 ; appels 7 ; franking 3 ; surfaces 3 ;
  - migration 3 ; vecteurs 3.

iOS part du plus d'existant : primitives v2, vecteurs, blobs, clé d'appel,
approbations. Android et le web partent de la v1. Le jalon A retire les blobs
et une partie de la charge v2 (réactions, sondages).

---

## Annexe C — Tickets du jalon A (appels chiffrés partout)

Chaque ticket cite ses sections. L'ordre est celui des dépendances. La session
serveur porte aussi le web.

**Commun**

- **COM-0** Vecteurs du jalon A :
  - formats à publier dans `contracts/e2ee-v2/` : `device-cert-v1`,
    `device-list-v1`, `device-capabilities-v1`, `epoch-manifest-v2`,
    `epoch-binding-v1`,
    `membership-change-v1`, `message-ref-v1`, `message-envelope-v2`,
    `content-payload-v2` (texte), `franking-v1`, `report-v1`,
    `call-descriptor-v1`, `call-frame-key-v2`, `call-join-proof-v1`,
    `uik-wrap-v1`, `device-approval-v2`, `safety-number-v1`,
    `identity-reset-v1`, ainsi que les trois vecteurs réémis en low-S
    (annexe D) ;
  - import des vecteurs existants partout ;
  - CI par condensat (§15).
- **COM-1** Réglages LiveKit, sur Swift 2.14.0, Android 2.27.0 et JS 2.18.x
  (§10.3) :
  - établir la dérivation (PBKDF2, itérations), la taille de clé,
    `failureTolerance`, et l'effet d'un marqueur « non chiffré » vide et du
    SIF ;
  - produire `livekit-shared-key-v1` (Swift, Android) ;
  - test négatif : une trame non chiffrée injectée n'est jamais rendue.

**Serveur**

- **SRV-A1** Confiance (§2) :
  - UIK publique, certificats avec `keyVersion` ;
  - listes signées en comparaison-échange ;
  - approbation acceptée seulement avec certificat et liste, dans la même
    transaction ;
  - historique d'appartenance en ajout seul.
- **SRV-A2** Récupération et réinitialisation d'identité, avec 72 heures
  d'opposition (§2.4, §2.8).
- **SRV-A3** Époques (§3, §14) :
  - création v2 atomique (conversation et époque 1), « +1 strict » en
    comparaison-échange ;
  - destinataires en sous-ensemble ;
  - manifeste stocké et servi ;
  - lignes témoins à l'accusé ;
  - exigences de rotation résolues dans la transaction ;
  - fin de la génération de clé v1 ;
  - refus de toute écriture v1 en conversation v2.
- **SRV-A4** Capacités (§12) : documents signés (dernière séquence), et
  `409 E2EE_CAPABILITY_MISSING` pour ce que le serveur voit.
- **SRV-A5** Messages texte v2 (§4) : enveloppe v2, déduplication à vie,
  `serverTag` dès le premier message.
- **SRV-A6** Signalement (§11) :
  - rapport en deux parties, avec vérification de `serverTag` et de
    l'appartenance ;
  - gel des blobs cités ;
  - nouvelle paire de modération P-256 ;
  - outil de modération en ligne de commande, hors ligne (§11).
- **SRV-A7** Surfaces (§13) :
  - refus en conversation v2 ;
  - transcription refusée aussi en v1 ;
  - notifications sans titre, nom ni emoji.
- **SRV-CALL-1** `callId` choisi par l'appelant, format opaque,
  `409 CALL_ID_TAKEN` (§10.1).
- **SRV-CALL-2** Descripteur relayé tel quel dans la clé `e2eeV2` de
  l'initiation, de la notification VoIP et FCM, et de `/api/calls/pending` ;
  jamais les anciennes clés `e2ee` et `e2eeRequired` (§10.1).
- **SRV-CALL-3** Enregistrement de l'appel chiffré : descripteur, signature,
  appareil appelant, `callNonce` unique (`409 CALL_NONCE_TAKEN`). Statut
  « actif » servi pour la jonction tardive et le transfert (§10.1).
- **SRV-CALL-4** Sonnerie et jeton LiveKit réservés aux appareils certifiés
  qui ont la capacité « appels vérifiés » (§10.1). Identité LiveKit
  `<userId>.<deviceId>` (§10.4).
- **SRV-CALL-5** Notification d'appel d'une conversation v2 sans nom ni titre
  (§10.5).
- **SRV-CALL-6** Ni enregistrement composite, ni transcription, ni résumé pour
  un appel chiffré (§10.4).
- **SRV-CALL-7** Appels de conversation v1 jamais marqués chiffrés (§10.0).
- **SRV-A8** Préalable production : état de la base vérifié avant tout SQL,
  SQL idempotent, tâches planifiées, secrets (dont `Ks`).

**iOS**

- **IOS-A1** Pile v2 existante alignée sur la v0.3 : certificats avec
  `keyVersion`, documents de capacités, manifestes, low-S (§2, §3.5, §12).
- **IOS-A2** Conversations chiffrées créées en v2 par l'appareil, et
  migration à l'ouverture (§3.2, §14).
- **IOS-A3** Messages texte v2, franking, signalement en deux parties (§4,
  §11).
- **IOS-A4** Écran des appareils : navigateurs marqués, approbation par QR,
  révocation, exclusion par conversation (§2.7).
- **IOS-CALL-1** Descripteur signé (`callId`, `callNonce`) ; lecture de
  `e2eeV2` dans l'initiation, la VoIP et `pending` (§10.1).
- **IOS-CALL-2** Clé de trame v2 et réglages LiveKit figés ; piste rendue
  seulement à l'état « OK » (§10.2 à §10.4).
- **IOS-CALL-3** Preuve de jonction : envoi, vérification, fin à 10 secondes
  (§10.4).
- **IOS-CALL-4** Règles d'usage (§10.0) : en v2, chiffré ou indisponible. En
  v1, la confirmation est faite (`05fda8fb`).
- **IOS-CALL-5** Notification VoIP sans nom, nom retrouvé localement ;
  `includesCallsInRecents = false` (§10.5).

**Android**

- **AND-A1** Pile v2 (§2, §15) :
  - identités en TEE, avec repli logiciel sur les API 29 et 30 ;
  - UIK logicielle, chiffrée par le Keystore ;
  - low-S, JSON strict, RFC 8785 ;
  - vecteurs.
- **AND-A2** Époques créées par l'appareil, manifestes, capacités, création
  v2 et migration (§3, §12, §14).
- **AND-A3** Messages texte v2, franking, signalement ; HPKE validé par les
  vecteurs RFC 9180 (§4, §11).
- **AND-A4** Écran des appareils : navigateurs marqués, approbation,
  révocation, exclusion par conversation (§2.7).
- **AND-CALL-1** Descripteur signé ; lecture de `e2eeV2` (§10.1).
- **AND-CALL-2** Clé de trame v2 ; `BaseKeyProvider` avec tous les réglages
  explicites ; piste rendue seulement à `E2EEState.OK` (§10.2 à §10.4).
- **AND-CALL-3** Preuve de jonction, par `DataPacketCryptorManager` ou canal
  non chiffré (§10.4).
- **AND-CALL-4** Règles d'usage (§10.0), dont la confirmation « Appel non
  chiffré de bout en bout » en v1.
- **AND-CALL-5** Notification FCM sans nom ;
  `EXTRA_LOG_SELF_MANAGED_CALLS = false` (§10.5).

**Web**

- **WEB-A1** Pile v2 en WebCrypto : P-256, conversion DER ↔ `r‖s` stricte
  (DER canonique), refus explicite du high-S (`s ≤ n/2`), vecteurs (§15).
- **WEB-A2** Navigateur sur demande : enrôlement par QR approuvé depuis un
  téléphone. Ni approbation ni récupération depuis le web (§2.7).
- **WEB-A3** Messages texte v2, franking, signalement (§4, §11).
- **WEB-CALL-1** Descripteur signé et clé de trame v2 ; `livekit-client`
  2.18.x avec une passphrase en chaîne et tous les réglages explicites ;
  piste rendue seulement à l'état « OK » (§10).
- **WEB-CALL-2** Preuve de jonction (§10.4).
- **WEB-CALL-3** Règles d'usage (§10.0), dont la confirmation en v1.
- **WEB-A4** (après le jalon A) Origine statique (§2.7).

**Croisé**

- **X-1** Appel chiffré croisé sur deux comptes :
  - combinaisons iOS ↔ Android, iOS ↔ web et Android ↔ web, à deux puis à
    trois ;
  - tests d'attaque du §17 : descripteur rejoué, ancienne époque, trame non
    chiffrée injectée, navigateur non approuvé, appareil sans capacité.
- **X-2** Relecture indépendante de chaque implémentation (§17).

---

## Annexe D — Formats du jalon A, à l'octet (v0.4)

Ces formats sont nouveaux : aucune app publiée ne les produit encore. Les
vecteurs de référence (§15, COM-0) les figent. En cas d'écart entre ce texte
et un vecteur publié, on corrige le texte ou le vecteur, jamais une
implémentation seule.

### D.0 Conventions communes

- **Chaîne canonique** :
  - UTF-8, champs séparés par `\n`, sans `\n` final ni espace ajouté ;
  - entiers en décimal, sans signe ni zéro initial (sauf `0`) ;
  - identifiants au format opaque (A.1) ;
  - `…Ms` en millisecondes depuis l'époque Unix.
- **Clés** : clés publiques P-256 en X9.63 non compressé (65 octets), en b64
  standard. Une clé privée transportée est son scalaire de 32 octets,
  big-endian.
- **Empreinte d'appareil** : `b64url(SHA-256(identityKey ‖ signingKey))`, sur
  les deux clés X9.63 brutes.
- **Signature** : ECDSA P-256 avec SHA-256, sur les octets UTF-8 de la chaîne
  canonique, en DER canonique, forme low-S, en b64 standard.
  - DER canonique : entiers minimaux, sans zéro de tête superflu, sans octet
    après la séquence. Le vérificateur refuse tout autre encodage : la
    signature doit se réencoder à l'identique (v0.4.7).
  - Le refus du high-S (`s > n/2`) et d'un DER non canonique est un contrôle
    explicite : WebCrypto (`crypto.subtle.verify`) accepte le high-S.
- **Alphabets** : clés, signatures, nonces et `keyCommitmentB64` en base64
  standard avec remplissage ; empreintes d'appareil et condensats (`…Digest`)
  en base64url sans remplissage. Une même chaîne signée peut mêler les deux.
- **Une chaîne signée voyage telle quelle**, dans un champ JSON texte, avec sa
  signature. Le destinataire la découpe strictement, avec un nombre de champs
  exact et chaque champ validé. Il ne la reconstruit jamais à partir de champs
  séparés.
- **JSON nouveau** : RFC 8785, analyseur strict, entiers en chaînes
  décimales. Un document JSON signé voyage aussi tel quel. Le destinataire le
  recanonicalise et rejette tout écart d'octet.
- **Condensat de liste** : `b64url(SHA-256("<ÉTIQUETTE>\n1" ‖ ("\n" ‖ ligne)*))`.
  Les lignes sont triées dans l'ordre des octets UTF-8, comme en A.4 et au
  §3.5.

### D.1 Transport de l'UIK à l'approbation (`uik-wrap-v1`)

L'appareil approbateur envoie l'UIK au nouvel appareil, pour sa clé d'accord.
Jamais à un navigateur : pour `platform = web`, l'approbation porte le
certificat et la liste, sans `uikWrap` (§2.7).

- Clé éphémère P-256 `e` ; secret = ECDH(`e`, clé d'accord du nouvel appareil).
- Sel : `SHA-256("SQ-E2EE-V2-UIK-WRAP-SALT\n1\n<userId>\n<approverDeviceId>\n<newDeviceId>")`.
- Clé : HKDF-SHA256(secret, sel, info `signalquest-e2ee-v2-uik-wrap-v1`,
  32 octets).
- AAD : `SQ-E2EE-V2-UIK-WRAP\n1\n<userId>\n<approverDeviceId>\n<newDeviceId>\n<uikPublicKeyB64>\n<ephemeralPublicKeyB64>`.
- Chiffrement :
  - clair = scalaire privé de l'UIK (32 octets) ;
  - AES-256-GCM, nonce aléatoire de 12 octets ;
  - `wrappedUikB64` = chiffré ‖ tag.
- Signature de l'approbateur, par sa clé de signature d'appareil, sur :
  `SQ-E2EE-V2-UIK-WRAP-SIGNATURE\n1\n<userId>\n<approverDeviceId>\n<newDeviceId>\n<uikPublicKeyB64>\n<ephemeralPublicKeyB64>\n<nonceB64>\n<aadB64>\n<wrappedUikB64>`.
- Le nouvel appareil vérifie :
  - que la clé publique recalculée depuis le scalaire égale `uikPublicKeyB64` ;
  - que cette clé est l'UIK attendue, épinglée ou comparée par QR (§2.3).

### D.2 Certificat d'appareil (`device-cert-v1`)

- Chaîne du §2.2, en 9 lignes. `keyVersion` vaut au moins 1.
- `platform` appartient à un ensemble fermé, en ASCII minuscule : `ios`,
  `android` ou `web`. Aucune normalisation (casse, espaces) : toute autre
  valeur est refusée, au bootstrap comme à la lecture.
- Les clés publiques sont en base64 **canonique** (ré-encoder les octets
  redonne la chaîne). Une variante aux bits de bourrage non nuls est refusée :
  comparée comme chaîne, elle passerait pour une autre clé.
- Signée par l'UIK.
- JSON : `{"certificate": "<chaîne>", "signatureB64": "…"}`.

### D.3 Liste d'appareils (`device-list-v1`)

- Ligne d'appareil : `<deviceId>\n<keyVersion>\n<platform>\n<empreinte>`.
  Les lignes contiennent des retours à la ligne : chaque ligne est donc lue
  strictement (exactement 4 champs, `deviceId` opaque, `keyVersion` décimal
  de 1 à 2³¹−2, `platform` de D.2, empreinte de 43 caractères en base64url
  canonique), et un même `deviceId` n'apparaît qu'une fois. Sans ce contrôle,
  deux découpages différents donneraient le même condensat.
- `version` est un décimal de 1 à 2³¹−2 ; les comparaisons ne débordent pas.
- `devicesDigest` : condensat de liste d'étiquette
  `SQ-E2EE-V2-DEVICE-LIST-ENTRIES`.
- Chaîne signée par l'UIK :
  `SQ-E2EE-V2-DEVICE-LIST\n1\n<userId>\n<version>\n<previousListDigest>\n<deviceCount>\n<devicesDigest>\n<issuedAtMs>`,
  où `previousListDigest = b64url(SHA-256(chaîne de la liste précédente))`,
  ou `-` pour la version 1.
- JSON : `{"list": "<chaîne>", "signatureB64": "…", "devices": ["<ligne>", …]}`.
- Un appareil révoqué est absent de la liste suivante.
- Le serveur accepte une liste si `version` vaut la courante + 1 et si
  `previousListDigest` est le condensat de la courante.
- Un client ne saute jamais un maillon : depuis sa version épinglée N, il lit
  les listes N+1 à M (E.1) et vérifie chaque signature et chaque condensat
  précédent. Il refuse à la moindre lacune.
- Un `deviceId` certifié par deux comptes n'est cru pour aucun des deux.
- Limite : un appareil révoqué garde l'UIK et pourrait re-signer une liste
  qui le remet. Révoquer un appareil pour la raison `COMPROMISED` propose donc
  une réinitialisation d'identité (D.14).

### D.4 Changement de membre (`membership-change-v1`)

- Chaîne signée par l'appareil de l'auteur :
  `SQ-E2EE-V2-MEMBERSHIP\n1\n<conversationId>\n<changeNumber>\n<action>\n<targetUserId>\n<actorUserId>\n<actorDeviceId>\n<previousChangeDigest>\n<createdAtMs>`.
- **`action`** ∈ `ADD`, `REMOVE`, `LEAVE`, `ROLE_ADMIN`, `ROLE_MEMBER`,
  `EXCLUDE_WEB_ON`, `EXCLUDE_WEB_OFF`. Pour les deux dernières, `targetUserId`
  vaut `-`.
- **Chaînage** :
  - `changeNumber` commence à 1 et croît de 1 ;
  - `previousChangeDigest` = `b64url(SHA-256(chaîne précédente))`, ou `-`
    pour le premier changement.
- **Création** : le créateur signe un `ADD` par membre, lui compris. Dans un
  groupe, il signe ensuite un `ROLE_ADMIN` pour lui.
- **Genèse** (v0.4.7) : les changements 1 à `membershipChangeNumber` du
  manifeste de l'époque 1 (§3.5), signés par un même appareil, dans cet
  ordre :
  - un `ADD` par membre, auteur compris, dans l'ordre des `userId` (octets
    UTF-8) ;
  - dans un groupe, au moins un `ROLE_ADMIN`, dans le même ordre, chacun
    visant un membre ajouté ; aucun en tête-à-tête, qui a exactement deux
    membres ;
  - éventuellement, un `EXCLUDE_WEB_ON` final, qui exclut les navigateurs dès
    l'époque 1.

  La genèse échappe aux règles des administrateurs ; tout changement suivant
  les respecte. Un vérificateur ne distingue pas création et migration : il
  n'impose que cette forme. À la création, le client créateur et le serveur
  imposent en plus que l'auteur figure parmi les `ROLE_ADMIN`.
- **Autorisations**, vérifiées par les clients :
  - dans un groupe, `ADD`, `REMOVE`, `ROLE_*` et `EXCLUDE_WEB_*` sont
    réservés à un administrateur ;
  - en tête-à-tête, `EXCLUDE_WEB_*` est ouvert aux deux membres ;
  - `LEAVE` est fait par la personne elle-même ;
  - l'auteur est membre à l'état précédent, et l'on part par `LEAVE`, jamais
    en se visant par `REMOVE`.
- JSON : `{"change": "<chaîne>", "signatureB64": "…"}`.
- Le serveur garde les changements en ajout seul, en comparaison-échange sur
  `changeNumber`.

### D.5 Document de capacités (`device-capabilities-v1`)

- Clés exactes, en chaînes ou tableaux de chaînes :
  - `schema` = `signalquest.e2ee-capabilities`, `version` = `1` ;
  - `userId`, `deviceId`, `sequence` (≥ 1), `issuedAtMs` ;
  - `envelopeVersions` et `payloadVersions` : décimaux, triés, sans doublon ;
  - `kinds` : noms de `kind`, triés, sans doublon ;
  - `features` : parmi `blobs`, `calls`, `liveLocation`, `polls`,
    `reactions` et `voice`, triés, sans doublon.
- Chaîne signée par la clé de signature de l'appareil :
  `SQ-E2EE-V2-DEVICE-CAPABILITIES\n1\n<b64url(SHA-256(document))>`.
- JSON : `{"document": "<JSON canonique>", "signatureB64": "…"}`.

### D.6 Manifeste d'époque (`epoch-manifest-v2`)

Format 2 au §3.5. JSON :
`{"manifest": "<chaîne>", "signatureB64": "…", "recipients": ["<ligne>", …]}`.
Vecteurs : `epoch-manifest-v2` pour le format, `epoch-binding-v1` pour la
liaison à la chaîne d'appartenance (genèse, condensat, numéro qui recule,
destinataire non membre, `excludesWeb` incohérent).

### D.7 Enveloppe de message v2 (`message-envelope-v2`)

Mêmes routes et même type de contenu que la v1 (A.4), avec
`envelopeVersion` = 2.

- **Clair** : `fk (32 octets) ‖ charge ‖ 0x80 ‖ 0x00…`. La charge est le JSON
  canonique de D.8, de 262 111 octets au plus (256 Kio − 33) : le clair
  bourré tient en 256 Kio, et l'enveloppe transportée sous 512 Kio, limite
  d'un corps JSON. La borne porte sur la charge canonique, échappements
  compris (un caractère de contrôle en vaut six) : l'émetteur refuse avant de
  chiffrer, le destinataire après avoir déchiffré.
- **Bourrage** : soit `L = 32 + longueur(charge) + 1`. Si `L` ≤ 4 096, la
  longueur bourrée est le multiple de 256 supérieur ou égal à `L`. Sinon,
  c'est la puissance de deux supérieure ou égale à `L`.
- **`frankTag`** : §11, calculé sur la charge seule, sans `fk` ni bourrage.
- **Sel** : `SHA-256("SQ-E2EE-V2-MESSAGE-SALT\n2\n<conv>\n<epochNumber>\n<senderDeviceId>\n<clientRequestId>")`.
- **Clé** : HKDF-SHA256(cléÉpoque, sel, info
  `signalquest-e2ee-v2-message-key-v2`, 32 octets).
- **AAD** : `SQ-E2EE-V2-MESSAGE-ENVELOPE\n2\n<conv>\n<epochNumber>\n<senderDeviceId>\n<clientRequestId>\n<counter>\nAES_256_GCM_HKDF_SHA256\napplication/vnd.signalquest.e2ee-envelope+json\n<engagementB64>\n<ttlSeconds>\n<condensatBlobs>\n<frankTagB64>`.
- **Signature de l'appareil** sur :
  `SQ-E2EE-V2-MESSAGE-SIGNATURE\n2\n<conv>\n<epochNumber>\n<senderDeviceId>\n<clientRequestId>\n<counter>\nAES_256_GCM_HKDF_SHA256\napplication/vnd.signalquest.e2ee-envelope+json\n<engagementB64>\n<ttlSeconds>\n<condensatBlobs>\n<frankTagB64>\n<nonceB64>\n<aadB64>\n<ciphertextB64>`.
- **Enveloppe transportée** (corps de l'envoi, `envelope` des lectures) :
  objet JSON à clés exactes, lu par un analyseur strict (D.0). Mêmes noms de
  champs que la v1, plus `counter` et `frankTagB64`. Les entiers voyagent en
  chaînes décimales canoniques, à la différence de la v1 : une enveloppe v2
  se reconnaît à `envelopeVersion` = `"2"`, une chaîne.

  | Champ | Encodage |
  |---|---|
  | `envelopeVersion` | `"2"` |
  | `epochNumber` | décimal, de 1 à 2³¹ − 2 |
  | `clientRequestId` | A.1 |
  | `counter` | décimal, de 1 à 2³¹ − 2 ; égal à celui de la charge |
  | `algorithm`, `contentType` | ceux de l'AAD |
  | `keyCommitmentB64` | b64 de 32 octets |
  | `ttlSeconds` | décimal, de 0 à 2 592 000 |
  | `encryptedBlobIds` | identifiants opaques, 20 au plus, sans doublon ; vide au jalon A |
  | `frankTagB64` | b64 de 32 octets |
  | `nonceB64` | b64 de 12 octets |
  | `aadB64` | b64 de l'AAD ci-dessus |
  | `ciphertextB64` | b64 ; sa longueur moins 16 est un palier de bourrage |
  | `senderSignatureB64` | b64 de la signature, DER canonique et low-S (D.0) |

  - Corps de l'envoi : l'enveloppe en JCS (RFC 8785), à l'octet. Le serveur
    refuse un JSON valide mais non canonique (`\/`, clés non triées,
    espaces) ; c'est ce qui donne un sens à « la même enveloppe, à
    l'octet » (E.3). Imbriquée dans une réponse, elle est relue par
    l'analyseur strict, sans exigence de forme : la signature porte sur la
    chaîne en lignes, pas sur le JSON.
  - En ASCII seul ; un BOM est refusé. Sa taille en octets est donc la
    longueur de son texte.
  - Entiers : `^(0|[1-9][0-9]*)$` en ASCII, contrôlé avant toute conversion
    (une conversion de bibliothèque accepte souvent `+1`, `1e3`, des espaces
    ou des chiffres non ASCII), puis les bornes du tableau.
  - Base64 standard avec remplissage, jamais base64url, défini par le
    réencodage : décodée puis réencodée, la chaîne reste identique (bits de
    fin nuls, ni saut de ligne ni espace). Un décodeur indulgent ne suffit
    pas.
  - Une clé en double est refusée, même si un analyseur courant garde la
    dernière sans erreur.
  - L'appareil émetteur n'est jamais lu dans l'enveloppe. À l'envoi, il vient
    de la requête signée ; à la lecture, du message remis (E.3).
  - Le compteur est tenu par appareil et par conversation (§4.3). Une
    nouvelle identité d'appareil repart de 1.
- **Réception**, dans cet ordre :
  0. structure : analyse stricte, tailles, palier de bourrage, avant tout
     accès à une clé ;
  1. certificat de l'appareil annoncé et signature, avant toute question
     d'époque : un message non signé n'oblige à rien, pas même à une
     synchronisation ; l'AAD décodée est égale, à l'octet, à l'AAD
     reconstruite à partir de la conversation demandée, du `senderDeviceId`
     du message remis et des champs de l'enveloppe ;
  1 bis. époque connue et dans sa fenêtre, émetteur membre de l'époque, et
     parti depuis moins de 24 heures s'il n'est plus membre (§3.4). Une
     époque plus récente que la courante demande une synchronisation ;
  2. déchiffrement ;
  3. bourrage : le dernier `0x80` n'est suivi que de `0x00`, sinon rejet ;
  4. `fk` ;
  5. `frankTag` recalculé ;
  6. charge analysée strictement. Une version ou un `kind` inconnus, dans
     une charge authentique, comptent au registre (identité, compteur) et
     s'affichent « Contenu non pris en charge » (§5.2) ;
  7. `counter` de la charge égal à celui de l'AAD.

### D.8 Charge v2, texte (`content-payload-v2`)

- Racine, clés exactes :
  - `schema` = `signalquest.e2ee-content`, `version` = `2`, `kind` ;
  - `sentAtMs` (de 0 à 2⁵³ − 1), `counter` ;
  - `replyToRef` (`messageRef` ou `null`) ;
  - `mentions` (100 `userId` au plus) ;
  - `body`.
- `kind` du jalon A, et leur `body` :
  - `TEXT` : `text` (1 à 65 536 octets UTF-8) ;
  - `EDIT` : `targetRef`, `text` ;
  - `DELETE` : `targetRef`.
- Les autres `kind` (médias, vocal, réactions, sondages, positions, cartes)
  arrivent au jalon B, chacun avec son vecteur.
- `messageRef` : §4.2.
- **Message éphémère** (`ttlSeconds` > 0 dans l'enveloppe) : il expire à
  `sentAtMs + ttlSeconds × 1 000`, l'heure signée de son émetteur. L'heure du
  serveur n'y entre pas : il ne peut ni prolonger un éphémère, ni l'effacer
  en silence. Un éphémère expiré compte au registre sans s'afficher, et quitte
  l'appareil qui le gardait, avec ses éditions. Une édition expirée cesse de
  compter : le texte affiché redevient celui de la version qui la précède
  (v0.4.11).

### D.9 `serverTag`

Format au §11. Le vecteur `franking-v1` donne `fk`, la charge, `frankTag`,
`Ks`, les champs et `serverTag`.

### D.10 Signalement (`report-v1`)

- **Partie en clair**, JSON canonique, clés exactes :
  - `schema` = `signalquest.e2ee-report`, `version` = `1` ;
  - `reportId`, `conversationId` ;
  - `reason` ∈ `SPAM`, `HARASSMENT`, `HATE`, `VIOLENCE`, `SEXUAL`, `ILLEGAL`,
    `OTHER` ;
  - `items` : 1 à 50, dans l'ordre des messages, chacun avec `envelopeId`,
    `frankTagB64`, `serverTagB64` et `blobIds`.
- **Partie scellée**, clair en JSON canonique :
  - `schema` = `signalquest.e2ee-report-sealed`, `version` = `1` ;
  - `items` dans le même ordre, chacun avec `envelopeId`, `payloadB64`,
    `fkB64` et `mediaKeys` (liste de `{blobId, mediaKeyB64}`).
- **HPKE** (RFC 9180), mode de base :
  - suite `0x0010` (DHKEM P-256, HKDF-SHA256), `0x0001` (HKDF-SHA256),
    `0x0002` (AES-256-GCM) ;
  - `info` = `"SQ-E2EE-V2-REPORT\n1\n" ‖ b64url(SHA-256(partie en clair))` ;
  - AAD vide, un seul `Seal`.
- **JSON transporté** :
  `{"clear": "<JSON canonique>", "encB64": "…", "sealedB64": "…", "moderationKeyId": "…"}`.
  Il tient en 512 Kio, comme tout corps JSON : la charge, déjà en base64
  dans la partie scellée, y est encodée une seconde fois. Au-delà, le client
  réduit la sélection plutôt que d'échouer à l'envoi.
- La clé publique de modération et son `moderationKeyId` sont embarqués dans
  les apps. Changer de clé demande une mise à jour de l'app.

### D.11 Appel

- **`e2eeV2`** :
  `{"descriptor": "<chaîne du §10.1>", "signatureB64": "…", "callerDeviceId": "…"}`.
  `callNonceB64` : 32 octets en b64 standard.
- **Preuve de jonction** : message du canal de données chiffré, de sujet
  `sq.e2ee.join`. Son contenu est le JSON canonique
  `{"proof": "<chaîne du §10.4>", "signatureB64": "…"}`. Dans la chaîne,
  `<livekitIdentity>` vaut exactement `<userId>.<deviceId>`.

### D.12 Numéro de sécurité (`safety-number-v1`)

- **Par utilisateur** :
  - `h = SHA-512("SQ-E2EE-V2-SAFETY\n1\n" ‖ uik ‖ userId)`, puis 5 200 fois
    `h = SHA-512(h ‖ uik)`. `uik` est la clé publique X9.63 brute, `userId`
    est en UTF-8 ;
  - on prend les 30 premiers octets, en 6 blocs de 5 octets ;
  - chaque bloc, lu comme un entier big-endian modulo 100 000, donne 5
    chiffres, avec des zéros à gauche ;
  - soit 30 chiffres.
- **Numéro affiché** pour deux personnes : leurs deux suites de 30 chiffres,
  dans l'ordre des `userId` (octets UTF-8). Soit 60 chiffres en 12 groupes
  de 5.
- **QR** : `SQSN1|` suivi des 60 chiffres.

### D.13 Approbation v2 (`device-approval-v2`)

- **QR**, version 3 :
  `SQE2EE2|3|<approvalId>|<pendingDeviceId>|<platform>|<empreinte>|<challengeB64Url>|<expiresAtMs>`.
  - Exactement 8 champs. Une autre version (2, 4…) est refusée, jamais
    devinée.
  - `<platform>` suit D.2. Elle ne peut contenir ni `|` ni retour à la ligne.
  - L'approbateur compare `<empreinte>` à celle du descripteur en attente, et
    `<platform>` à la plateforme qu'il déclare.
- **Code SAS v3** (approbation par notification), en mise en gage puis
  révélation, pour que le serveur ne puisse pas chercher un code qui coïncide :
  1. l'appareil en attente tire `nP` (32 octets aléatoires) et publie, avec sa
     demande, `commitB64Url = b64url(SHA-256("SQ-E2EE-V2-SAS-COMMIT\n1\n<userId>\n<approvalId>\n<pendingDeviceId>\n<platform>\n<empreinte>\n<nPB64Url>"))` ;
  2. l'approbateur lit la demande et sa mise en gage, puis tire et envoie `nA`
     (32 octets aléatoires) ;
  3. l'appareil en attente révèle `nP`. L'approbateur recalcule la mise en
     gage et abandonne si elle diffère.

  Le code : les 4 premiers octets, en entier big-endian modulo 1 000 000, de
  `SHA-256("SQ-E2EE-V2-APPROVAL-SAS\n3\n<userId>\n<pendingDeviceId>\n<platform>\n<empreinte>\n<approvalId>\n<nPB64Url>\n<nAB64Url>")`.
  Les champs sont séparés par `\n` comme dans toute l'annexe D : leurs formats
  (identifiants opaques, base64url, plateforme) excluent ce caractère, ce qui
  vaut un encodage par longueur. Une seule tentative : écart, révélation
  absente ou demande expirée ⇒ abandon, puis nouvelle demande. L'approbateur
  n'affiche le code qu'après avoir vérifié la mise en gage.

  Relais du serveur (v0.4.8) : la mise en gage est fixée à la création de la
  demande, puis immuable ; `nA` n'est accepté qu'une fois, par une requête
  signée d'un appareil approuvé du même compte, jamais d'un navigateur ;
  `nP` n'est accepté qu'une fois, et seulement après `nA` ; chaque partie
  relit le tout par `GET device-approvals/{id}`. Une demande qui a révélé
  `nP` sans être approuvée est terminale : une nouvelle tentative crée une
  nouvelle demande.
- **Code de proximité v2** : 16 caractères en base32 Crockford (80 bits), tirés
  des 10 premiers octets de
  `SHA-256("SQ-E2EE-V2-PROXIMITY\n1\n<userId>\n<approvalId>\n<pendingDeviceId>\n<platform>\n<empreinte>\n<challengeB64Url>")`.
  L'appareil en attente l'affiche ; l'approbateur le recalcule depuis la demande
  que sert le serveur et le compare à la saisie, normalisée (majuscules,
  espaces et tirets retirés), à temps constant. Substituer d'autres clés
  demanderait une collision sur 80 bits.
- **Plateforme affichée** : un libellé traduit de la plateforme lue dans le
  QR ou couverte par le SAS, jamais de celle du serveur. La comparaison porte
  sur la valeur canonique. Pour un navigateur, l'avertissement sur les
  conversations qui excluent les navigateurs (§2.7) vient avant la
  confirmation.
- **Refus** : si le serveur déclare une autre plateforme, l'approbateur
  refuse sans rien envoyer, avec le message « Plateforme différente de celle
  affichée, approbation refusée. » (code de journal `platformMismatch`). Le
  serveur refuse aussi un certificat dont la plateforme n'est pas celle du
  descripteur en attente (E.0).

### D.14 Réinitialisation d'identité (`identity-reset-v1`)

- Chaîne signée par la **nouvelle** UIK :
  `SQ-E2EE-V2-IDENTITY-RESET\n1\n<userId>\n<newUikB64>\n<previousUikFingerprint>\n<requestedAtMs>\n<effectiveAtMs>`.
  - `effectiveAtMs` = `requestedAtMs` + 72 heures ;
  - `previousUikFingerprint` = `b64url(SHA-256(ancienne UIK))`, ou `-` s'il
    n'y en avait pas.
- **Opposition** : avant `effectiveAtMs`, un appareil certifié de l'ancienne
  identité peut s'y opposer. Il signe, avec sa clé d'appareil :
  `SQ-E2EE-V2-IDENTITY-RESET-OBJECTION\n1\n<userId>\n<newUikB64>\n<objectingDeviceId>\n<objectedAtMs>`.

### D.15 Contenu des vecteurs

Chaque vecteur donne ses entrées, avec les clés et les aléas fixés pour être
reproductible, ses valeurs intermédiaires et ses sorties. Il comporte aussi
une section `negative` : au moins un cas par règle de rejet, avec le motif
attendu. `message-envelope-v2` donne en plus l'enveloppe transportée
(`wireJsonUtf8`) et ce qu'un analyseur strict refuse (`wireNegative`).

Le générateur de référence est côté iOS (COM-0) ; chaque plateforme rejoue les
vecteurs dans les deux sens. L'ECDSA étant aléatoire, une signature produite
par une autre plateforme n'est pas identique à l'octet. On vérifie sa
validité et sa forme low-S, jamais son égalité.

---

## Annexe E — Routes du jalon A (proposition iOS, à valider par le serveur)

Ces routes prolongent celles que le client iOS appelle déjà sous
`/api/e2ee/v2/` : appareils, approbations, amorçage, époques, messages,
enveloppes, récupération. Elles sont fermées en production, et les apps
publiées gardent leurs verrous fermés. Leurs contrats peuvent donc encore
changer ; la règle de compatibilité du §16 s'applique à partir de la première
version publiée qui ouvre les verrous.

### E.0 Conventions

- **Authentification** : cookie de session, plus une requête signée par
  l'appareil (A.2) sur toute écriture.
- **Corps et réponses** : JSON à clés exactes. Les objets signés reprennent
  les formes de l'annexe D (`{"certificate", "signatureB64"}`,
  `{"list", "signatureB64", "devices"}`, etc.).
- **Erreurs** : `{"error": "<message>", "code": "<CODE>"}`, avec le statut
  HTTP qui convient. Les codes propres au jalon A :
  - `E2EE_DEVICE_LIST_STALE` (409) : la version ou le condensat précédent ne
    correspond pas ; ou bien une époque est proposée sur une liste d'appareils
    qui n'est plus la courante (`memberListVersions`, E.2, v0.4.10), et
    `details.userId` (le premier) et `details.userIds` (tous) nomment les
    membres dont il faut relire l'identité ;
  - `E2EE_EPOCH_STALE` (409) : une autre époque a été acceptée, et la réponse
    la donne ;
  - `E2EE_MEMBERSHIP_STALE` (409) : `changeNumber` n'est pas le suivant, ou
    une époque repose sur un état d'appartenance qui n'est plus le dernier
    (§3.5) ; la réponse donne l'état courant ;
  - `E2EE_CAPABILITY_MISSING` (409) : la conversation ne peut pas recevoir ce
    contenu (§12) ;
  - `E2EE_CERTIFICATE_INVALID` (422) : certificat qui ne se vérifie pas
    jusqu'à l'UIK ;
  - `E2EE_CERT_PLATFORM_MISMATCH` (409) : la plateforme du certificat n'est
    pas exactement celle du descripteur en attente (D.13) ;
  - `E2EE_UIK_WRAP_FORBIDDEN_FOR_WEB` (409) : approbation d'un navigateur qui
    porte un `uikWrap` (§2.7) ;
  - `E2EE_WEB_DEVICE_NOT_ALLOWED` (403) : approbation, révocation ou
    recertification émise par un navigateur (§2.7) ;
  - `E2EE_RECOVERY_SIGNATURE_INVALID` (400) : bundle de récupération dont la
    signature ne se vérifie pas contre l'UIK enregistrée (§2.8) ;
  - `CONVERSATION_ID_TAKEN` et `CALL_ID_TAKEN` (409) : identifiant choisi par
    le client déjà utilisé ;
  - `CALL_NONCE_TAKEN` (409) : `callNonce` déjà enregistré (§10.1) ;
  - `E2EE_MESSAGE_CONFLICT` (409) : une autre enveloppe a déjà été acceptée
    pour la même identité de message (§4.2) ;
  - `E2EE_REPORT_QUOTA` (429) : quota de signalements atteint (§16), avec
    `Retry-After` (v0.4.11). Un autre 429 reste un ralentissement passager ;
  - `E2EE_REPORT_TOO_LARGE` (400) : plus de 50 éléments, ou un corps de plus
    de 512 Kio (D.10, v0.4.11). Un client conforme ne le reçoit jamais : il
    réduit la sélection avant d'envoyer (§11) ;
  - `E2EE_UPDATE_REQUIRED` (409) : écriture d'une app sans v2 dans ce qui
    exige la v2 (§14). `error` porte le texte à afficher, que les apps
    publiées montrent tel quel.
- Une erreur peut porter des `details` (objet) ; les clients ignorent les
  clés qu'ils ne connaissent pas.
- **Vérification serveur** : le serveur vérifie ce qu'il peut, c'est-à-dire
  signatures, chaînages, condensats et comparaisons-échanges. Les clients
  revérifient toujours : le serveur n'est jamais une source de confiance
  (§1).

### E.1 Identité et appareils

- **`GET /api/e2ee/v2/users/{userId}/identity?sinceVersion=<N>`**, le paquet de
  confiance d'un compte. `sinceVersion` est la version épinglée du client
  (absente au premier contact). Réponse :
  - `accountIdentityKeyB64` ;
  - `deviceList` : `{list, signatureB64, devices}` ;
  - `deviceListChain` : les listes N+1 à M−1, en `{list, signatureB64}` et dans
    l'ordre, M étant la courante ; pages plafonnées à 50, avec
    `nextSinceVersion` (chaîne décimale, toujours plus grande que la version
    demandée) quand il en reste. Le client redemande à partir de là, vérifie
    chaque maillon (signature de l'UIK, numéro suivant, condensat du
    précédent) et refuse le paquet à la moindre lacune ;
  - `certificates` : liste de `{certificate, signatureB64}`, les appareils de
    la liste courante ;
  - `capabilities` : liste de `{document, signatureB64}`, le dernier document
    de chaque appareil ;
  - `pendingIdentityReset` : `{reset, signatureB64}` ou `null`.

  Un `sinceVersion` plus grand que la version courante de la liste (identité
  réinitialisée depuis, v0.4.9) est ignoré : la réponse porte l'UIK et la
  liste courantes, sans chaîne ni erreur. Le client compare l'UIK avant de
  vérifier la chaîne.
- **`POST /api/e2ee/v2/bootstrap`**, étendu pour le premier appareil. Corps
  existant, plus :
  - `accountIdentityKeyB64` ;
  - `certificate` ;
  - `deviceList` (version 1).
- **`POST /api/e2ee/v2/device-approvals/{id}/approve`**, étendu. Corps :
  - `certificate` du nouvel appareil ;
  - `deviceList` suivante ;
  - `uikWrap` : l'objet de D.1, avec toutes ses clés ; jamais pour un
    navigateur (`platform` `web`), refusé sinon
    (`409 E2EE_UIK_WRAP_FORBIDDEN_FOR_WEB`).

  Le serveur enregistre les trois dans une seule transaction, ou rien. Un
  navigateur n'approuve, ne révoque ni ne recertifie aucun appareil
  (`403 E2EE_WEB_DEVICE_NOT_ALLOWED`).
- **`PUT /api/e2ee/v2/devices/{deviceId}/certificate`**, rotation de la clé
  d'accord (`keyVersion` + 1). Corps : `{certificate, deviceList}`.
- **`POST /api/e2ee/v2/devices/{deviceId}/revoke`**, étendu. Corps :
  `{deviceList}`, la nouvelle liste sans l'appareil, signée par l'UIK.
- **`PUT /api/e2ee/v2/devices/{deviceId}/capabilities`**. Corps :
  `{document, signatureB64}`. Refus si `sequence` n'augmente pas.
- **`GET /api/e2ee/v2/device-approvals/{id}`**, signé par l'appareil en
  attente : une fois l'approbation faite, il y retire `uikWrap`, son
  certificat et la `deviceList`. Idempotent jusqu'à consommation ou
  expiration.
- **`PUT /api/e2ee/v2/devices/{deviceId}/push-tokens`**, signé par
  l'appareil : `{apnsVoipToken?, apnsToken?, fcmToken?, environment}`. Il lie
  les jetons push à l'appareil v2. La sonnerie d'un appel chiffré ne cible
  que ces jetons ; l'enregistrement actuel par installation reste pour le
  reste.
- **`POST /api/e2ee/v2/identity/reset`**, étendu. Corps :
  - `reset` : `{reset, signatureB64}` (D.14) ;
  - `certificate` et `deviceList` (version 1) du nouvel ensemble.
- **`POST /api/e2ee/v2/identity/reset/{resetId}/objection`**. Corps :
  `{objection, signatureB64}`.

### E.2 Conversations, membres et époques

- **`POST /api/e2ee/v2/conversations`**, création d'une conversation v2
  (§3.2). Corps :
  - `conversationId`, choisi par le client : `conv_` suivi de 128 bits
    aléatoires en base64url ;
  - `isGroup` (booléen), `title` (ou `null`) et `participantIds`, les
    membres invités, sans l'auteur, triés ;
  - `membership` : la genèse, liste de `{change, signatureB64}` (D.4) ;
  - `epoch` : `{epochNumber: "1", previousEpochNumber: "0", manifest, envelopes}`,
    où `manifest` est `{manifest, signatureB64, recipients}` (format 2,
    §3.5) et `envelopes` suit la forme A.3 ;
  - `memberListVersions`, facultatif (v0.4.10) : voir la rotation.

  La création est atomique. Réponse proposée par iOS :
  `{conversationId, epoch: {id, epochNumber, status, createdAt}, recipientCount}`.
  Comme pour toutes les réponses proposées ici, JSON strict (clés exactes,
  sans doublon) et entiers en chaînes décimales (D.0).
  Le client ne garde la clé de l'époque 1 et l'état « v2 » qu'à réception
  de ce reçu, exact (§3.1). La genèse est idempotente à l'octet (v0.4.8) :
  le même corps rend le même reçu, à la création comme à la migration, et
  un reçu perdu se relit en renvoyant la même requête. Sur
  `409 CONVERSATION_ID_TAKEN`, pour un autre corps, rien n'est gardé ; une
  nouvelle tentative tire un autre identifiant.
- **`POST /api/e2ee/v2/conversations/{id}/genesis`**, migration d'une
  conversation chiffrée v1 (§14.2), proposée par iOS. Corps :
  `{membership, epoch}`, de même forme qu'à la création. Le serveur refuse
  une genèse qui ne reproduit pas exactement les membres et les
  administrateurs v1 (propriétaire compris), et une conversation déjà v2.
  Même reçu qu'à la création.
- **`POST /api/e2ee/v2/conversations/{id}/epochs`**, étendu. Corps :
  - `previousEpochNumber`, `epochNumber` ;
  - `manifest`, au format 2 (§3.5) ;
  - `envelopes` ;
  - `memberListVersions`, facultatif (v0.4.10) : `{userId: "<version>"}`,
    la version de la liste d'appareils de chaque membre que le client a
    utilisée (entiers en chaînes, D.0 ; au plus une entrée par membre). Le
    client DEVRAIT l'envoyer. Absent, rien ne change ; un membre absent de
    l'objet n'est pas contrôlé. Une version qui n'est plus la courante donne
    409 `E2EE_DEVICE_LIST_STALE`, avec `details.userId` (le premier membre en
    retard) et `details.userIds` (tous) : le client relit leurs paquets
    d'identité. Une clé qui n'est plus membre donne 409
    `E2EE_MEMBERSHIP_STALE`, prioritaire si les deux cas se présentent : le
    client resynchronise l'appartenance, qui peut changer les membres à
    relire. Puis il recommence. Ce contrôle évite une course entre appareils ; il ne protège
    pas contre un serveur malveillant, dont la défense reste le manifeste
    vérifié par chaque destinataire (§3.5).

  Reçu proposé par iOS : `{epoch: {id, epochNumber, status, createdAt}, recipientCount}`.
  En cas de conflit : 409 `E2EE_EPOCH_STALE`, avec
  `details.currentEpoch` au format de `epochs/current`. Le client peut aussi
  relire `epochs/current`, puisqu'un manifeste de 500 lignes dépasse la
  taille d'un corps d'erreur ; il vérifie l'époque acceptée comme un
  destinataire avant de l'adopter. Si le manifeste repose sur un état
  d'appartenance qui n'est plus le dernier : 409 `E2EE_MEMBERSHIP_STALE`,
  avec l'état courant. Le serveur sérialise par conversation l'acceptation
  d'une époque et l'ajout d'un changement d'appartenance (v0.4.8) : aucun
  changement ne passe entre son contrôle et son écriture.
- **`GET /api/e2ee/v2/conversations/{id}/epochs/current`**, étendu.
  Réponse proposée par iOS :
  `{conversationId, epoch: {id, epochNumber, status, createdAt}, manifest: {manifest, signatureB64, recipients}, envelope}`,
  où `envelope` est celle de l'appareil qui lit (A.3). La clé du créateur se
  lit dans l'annuaire des appareils certifiés (§2.2), jamais dans la
  réponse.
- **`POST /api/e2ee/v2/conversations/{id}/epochs/{epochNumber}/ack`**, accusé
  de réception. Le serveur passe l'enveloppe de l'appareil en ligne témoin
  (§2.6).
- **`POST /api/e2ee/v2/conversations/{id}/membership`**. Corps :
  `{change, signatureB64}`, en comparaison-échange sur `changeNumber`.
  Réponse proposée par iOS : `{changeNumber}`, en chaîne ; le même changement
  renvoyé à l'octet rend la même réponse. Le client compose sur la tête de sa
  chaîne gardée, vérifie localement les règles de D.4, garde le changement
  signé avant l'envoi et le renvoie tel quel jusqu'à sa réponse : jamais deux
  signatures pour un même numéro. Sur `409 E2EE_MEMBERSHIP_STALE`, il relit
  la suite de la chaîne, puis recompose.
- **`GET /api/e2ee/v2/conversations/{id}/membership?after=<changeNumber>`** :
  la suite de la chaîne. Réponse proposée par iOS :
  `{changes: [{change, signatureB64}], hasMore}`, 100 changements au plus
  par page ; une page vide n'annonce jamais de suite.
- **`GET /api/e2ee/v2/conversations/{id}/epochs/{epochNumber}`**, proposée
  par iOS : une époque désignée, de même forme que `epochs/current`, avec
  l'enveloppe de l'appareil qui lit. Un appareil resté hors ligne pendant
  plusieurs rotations relit ainsi, dans l'ordre, chaque époque sautée dont il
  est destinataire, avant la courante : leurs messages en vol se lisent
  encore (§3.4). `404 E2EE_EPOCH_ENVELOPE_NOT_FOUND` s'il n'en est pas
  destinataire.
- **`GET /api/e2ee/v2/conversations/{id}/epochs/{epochNumber}/manifest`**,
  proposée par iOS : `{epochNumber, manifest: {manifest, signatureB64, recipients}}`.
  Elle sert le manifeste à tout membre, destinataire ou non : c'est par celui
  de l'époque 1 qu'un nouvel appareil vérifie la genèse et sait la
  conversation v2 (§3.5, §12).
- **Réception par un membre** : il relit la suite de la chaîne, vérifie la
  genèse une fois sur le manifeste de l'époque 1, relit toute la chaîne avant
  de la garder, puis vérifie et garde l'époque courante. Un appareil qui
  n'est pas encore destinataire (`404 E2EE_EPOCH_ENVELOPE_NOT_FOUND`) attend
  la prochaine époque ; la conversation est déjà v2 pour lui.

### E.3 Messages et signalements

- **`POST /api/e2ee/v2/conversations/{id}/messages`**, étendu à
  l'enveloppe v2 :
  - corps : l'enveloppe transportée de D.7 ;
  - le serveur vérifie la requête signée, l'appartenance de l'appareil, la
    forme stricte et la signature de l'enveloppe. L'époque doit être la
    courante, sinon `409 E2EE_EPOCH_STALE`, avec l'époque courante ;
  - identité `(conversationId, appareil, clientRequestId)`, cherchée avant
    tout contrôle d'époque : la même enveloppe, à l'octet, rend le même
    accusé, même si l'époque a tourné depuis ; une autre enveloppe pour une
    identité déjà acceptée est refusée (`409 E2EE_MESSAGE_CONFLICT`). Un
    couple (appareil, compteur) déjà pris par une autre identité est refusé
    de même. Une enveloppe refusée ne compte pas. Le compteur est tenu par
    (conversation, appareil), toutes époques confondues : aucune des deux
    contraintes d'unicité ne porte l'époque (v0.4.8) ;
  - réponse : `{envelopeId, clientRequestId, serverTagB64, serverTimeMs, keyId}`,
    entiers en chaînes (§11) ;
  - **côté client** : l'enveloppe préparée est gardée avant le premier envoi
    et renvoyée telle quelle tant que son époque est la courante vérifiée,
    car son accusé a pu se perdre. Si l'appareil sait cette époque remplacée,
    elle est rechiffrée sous l'époque courante vérifiée avant de partir, avec
    la même identité, le même compteur, la même charge et le même `fk`, donc
    le même `frankTag` : jamais envoyée sous une époque remplacée, qu'un
    membre retiré ou un appareil révoqué pourrait lire ; il part alors vers
    les membres de l'époque courante, y compris ceux arrivés depuis sa
    rédaction. Sur
    `409 E2EE_EPOCH_STALE`, le client se synchronise d'abord. L'accusé reçu
    est gardé : un nouvel essai du même message le rend, sans rien renvoyer.
    Deux essais simultanés ne signent jamais deux enveloppes. Un envoi
    abandonné (refus définitif, départ, plus de 7 jours) efface sa charge en
    clair ;
  - sur `409 E2EE_MESSAGE_CONFLICT` : seul cet appareil signe ses
    identités, donc l'enveloppe acceptée est une version antérieure du même
    message, à charge identique. Le client le tient pour remis, abandonne
    l'enveloppe en attente sans jamais en signer d'autre, et retrouve le
    message dans la liste ;
  - le compteur est réservé et gardé avant l'envoi, sous un verrou commun à
    tout ce qui partage l'appareil (plusieurs onglets d'un navigateur, par
    exemple). Il ne descend jamais sous le plus haut compteur de cet appareil
    vu dans la liste : une sauvegarde restaurée sur le même appareil ne le
    fait pas reculer.
- **`GET /api/e2ee/v2/conversations/{id}/messages?after=<séquence>&limit=<1 à 100>`**,
  la liste des messages v2 : `{messages, hasMore}`.
  - Chaque message :
    `{envelopeId, sequence, senderUserId, senderDeviceId, envelope, serverTagB64, serverTimeMs, keyId}`,
    entiers en chaînes, `envelope` étant l'enveloppe transportée.
  - `after` est la séquence serveur du dernier message lu, `0` pour partir
    du début. Séquences du serveur croissantes, toutes après `after`. Un
    trou est permis (message refusé ou retiré) ; jamais une séquence qui
    deviendrait visible après une plus haute déjà servie, que le curseur
    sauterait : le serveur l'attribue sous un verrou par conversation tenu
    jusqu'à l'écriture (v0.4.8).
  - Une page tient en 512 Kio : le serveur s'arrête avant, avec `hasMore` à
    vrai. `hasMore` peut donc valoir vrai avec moins de `limit` messages ; le
    client continue tant qu'il vaut vrai. Une page vide n'annonce jamais de
    suite.
  - **Registre du destinataire**, rempli seulement après la signature, le
    déchiffrement et l'analyse de la charge :
    - doublon : même identité et même `frankTag`, affiché une fois. Les
      identités vues sont gardées à vie (une empreinte courte suffit) : une
      identité ancienne ne se réaffiche jamais, même sous un compteur neuf ;
    - équivoque : même identité et `frankTag` différent, ou même couple
      (appareil, compteur) sous deux identités. Aucun des deux n'est affiché,
      l'utilisateur est prévenu (§4.2) ;
    - trous : comptés entre les compteurs vus d'un appareil, et évalués
      seulement une fois la liste rattrapée (`hasMore` faux). Un message
      éphémère expiré en laisse un : le message reste neutre (« certains
      messages n'ont pas pu être reçus »).
    - un échec passager (annuaire des appareils en retard, coffre
      verrouillé, stockage) ne fait pas avancer le curseur : le message se
      relira.
- **`GET /api/e2ee/v2/envelopes/{id}/fetch`** d'un message v2 :
  `{"conversationId", "message"}`, `message` étant le même objet que dans la
  liste. Lecture authentifiée par le seul cookie de session, sans signature
  d'appareil (E.0) : l'extension de notification n'a aucune clé privée
  (§2.6). La conversation annoncée n'est qu'un aiguillage, que l'AAD et la
  signature lient. Le serveur ne la sert qu'à la session d'un membre de la
  conversation ; elle n'a aucun effet de bord (ni accusé de réception, ni
  remise) et sa réponse porte `Cache-Control: no-store, private`. La
  réponse pour un message v1 ne change pas (règle de compatibilité, §16).
- **`POST /api/e2ee/v2/reports`**. Corps :
  `{clear, encB64, sealedB64, moderationKeyId}` (D.10).
  - Le serveur vérifie les `serverTag` et l'appartenance du signaleur, puis
    gèle les blobs cités. Au-delà du quota du jour : 429
    `E2EE_REPORT_QUOTA` (v0.4.11). Au jalon A, les messages v2 ne sont que du texte :
    le gel des blobs arrive avec le jalon B.
  - Réponse : `{reportId}`.
- **`GET /api/admin/e2ee/reports?after=<curseur>`**, réservée à
  l'administration : la partie claire et la partie scellée de chaque
  rapport. L'outil de modération, sur le Mac d'Alexandre, les déchiffre
  localement avec la clé de modération (§11). Pour chaque message cité, la
  réponse donne aussi, tirés des enregistrements du serveur, `senderUserId`,
  `senderDeviceId`, `clientRequestId`, `serverTimeMs` et `keyId` : l'outil en
  a besoin pour recalculer `frankTag` (v0.4.11). Ces valeurs viennent de ses
  enregistrements, jamais du rapport. Une enveloppe introuvable, ou qui
  n'appartient pas à la conversation du rapport, est marquée `unverifiable`
  et l'outil ne recalcule rien pour elle ; un rapport ne fait jamais échouer
  toute la liste.

### E.4 Appels

- **`POST /api/calls/initiate`**, en requête signée par l'appareil (A.2).
  Dans une conversation v2, le corps est
  `{conversationId, type, callId, e2eeV2}` (D.11).
- **`POST /api/calls/answer`**, en requête signée : `{callId}`, rien de plus.
- **Contrôles du serveur sur le descripteur** : conversation v2 ; appareil
  appelant certifié, avec la capacité « appels vérifiés » ; signature en
  forme low-S ; époque = l'époque active courante (`epochId`, `epochNumber`,
  `keyCommitmentB64`) ; `callId` et `callNonce` uniques. Pas de fenêtre de
  temps : les 60 secondes d'une sonnerie sont vérifiées par l'appelé contre
  son horloge, et l'unicité empêche le rejeu.
- La réponse peut porter `livekitIdentity`, à titre informatif : aucun
  client ne s'y fie pour vérifier. Le `callNonce` n'existe que dans le
  descripteur signé, jamais en champ séparé.
- **Au jalon A** (proposé, en attente de décision) : une réponse par compte
  suffit, et le transfert d'un appel chiffré est refusé
  (`409 CALL_TRANSFER_E2EE_UNSUPPORTED`), bouton masqué côté clients.
- **Réponses et notifications** : la réponse d'initiation,
  `/api/calls/pending`, l'événement `incoming` du flux SSE
  `/api/calls/stream`, et les notifications VoIP et FCM (appel et transfert)
  relaient `e2eeV2` tel quel.
  - VoIP (APNs) : objet JSON.
  - FCM : les valeurs de `data` sont des chaînes, donc `e2eeV2` y voyage en
    chaîne JSON sérialisée, relue strictement.
  - Les anciennes clés `e2ee` et `e2eeRequired` restent vides (§10.1).
- **Jeton LiveKit d'un appel chiffré** : émis pour l'appareil qui le demande
  par requête signée, sous l'identité `<userId>.<deviceId>` (§10.4).
