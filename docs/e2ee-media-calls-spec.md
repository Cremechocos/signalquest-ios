# Chiffrement de bout en bout complet — spécification commune (v2)

> Statut : **proposition v0.2**, à valider par les sessions iOS, Android,
> serveur et web avant tout développement. Le chantier démarre après la bêta
> iOS 160.
>
> - v0.1 (30/09/2026) : première rédaction (plan 2, Lot 6).
> - v0.2 (30/09/2026) : révisée après une relecture de sécurité indépendante.
>   Ajouts : chaîne de confiance des appareils et des membres, récupération
>   limitée à son propre compte, section « Propriétés de sécurité », franking
>   refait, appels authentifiés et réglages LiveKit figés, surfaces fermées par
>   défaut, annexe « octets sur le fil » conforme au code et aux vecteurs.
>
> Portée : chiffrer de bout en bout, en plus du texte, les photos et fichiers,
> les notes vocales, les sondages, les réactions, les positions et les appels
> audio et vidéo. Une seule génération de protocole, la **v2**, commune aux
> quatre clients (iOS, Android, web) et au serveur.
>
> L'inventaire de l'existant et la relecture détaillée, qui décrivent des
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
- **Client web** : le serveur fournit le code qui manipule les clés (§2.7).

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
- La **clé publique** de l'UIK est ce que les contacts vérifient et épinglent
  (confiance à la première utilisation, puis vérification explicite).

### 2.2 Appareils et certificats

- Chaque appareil a deux paires P-256 : accord de clé
  (`P256_X963_ECDH_HKDF_SHA256`) et signature (`P256_X963_ECDSA_SHA256_DER`).
  Les clés privées ne quittent jamais l'appareil (§2.6).
- **Certificat d'appareil**, signé par l'UIK :
  `SQ-E2EE-V2-DEVICE-CERT\n1\n<userId>\n<deviceId>\n<identityKeyB64>\n<signingKeyB64>\n<platform>\n<createdAtMs>`,
  où `platform` vaut `ios`, `android` ou `web`.
- **Liste d'appareils signée** par l'UIK, versionnée et monotone (un numéro de
  version qui ne fait que croître) : un client refuse une liste plus ancienne
  que la dernière vue.
- **Règle normative** : un client NE DOIT envelopper une clé d'époque, ou
  accepter une signature de message, que pour un appareil dont le certificat se
  vérifie jusqu'à l'UIK épinglée de son propriétaire.

### 2.3 Ajout d'un appareil

- Le premier appareil est amorcé par un code e-mail et une ré-authentification,
  puis crée l'UIK.
- Un appareil suivant est `PENDING` jusqu'à ce qu'un appareil certifié du même
  compte l'approuve et signe son certificat avec l'UIK.
- Le **QR** et le **code de proximité** contiennent l'empreinte complète
  `SHA-256(identityKey ‖ signingKey)` du nouvel appareil, et l'approbateur la
  compare automatiquement.
- L'approbation **par notification** exige un code de comparaison (SAS) de six
  chiffres, affiché sur les deux écrans et confirmé par l'utilisateur.
- Tout ajout d'appareil est annoncé aux contacts dans les conversations
  (message système vérifié) ; le numéro de sécurité ne change pas (§2.4).

### 2.4 Numéro de sécurité

- **Par utilisateur**, calculé sur la clé publique de l'UIK : au moins 128 bits,
  affichés en 60 chiffres par groupes de cinq et en QR, avec une dérivation
  itérée (5 200 itérations de SHA-512, comme Signal).
- Il ne change pas à l'ajout d'un appareil certifié. Il change seulement à la
  réinitialisation de l'identité.
- **Réinitialisation d'identité** : les appareils existants du compte en sont
  notifiés et peuvent s'y opposer pendant 72 heures. Les contacts voient
  « Le numéro de sécurité de X a changé ». Si l'UIK était vérifiée, l'envoi est
  bloqué jusqu'à nouvelle vérification.

### 2.5 Membres des groupes

- Chaque ajout ou retrait de membre est signé par l'appareil d'un
  administrateur, et affiché comme message système vérifié. Un client rejette
  un changement de membre non signé.
- Chaque époque porte un **manifeste signé de ses destinataires** (`userId`,
  `deviceId`, empreinte). Chaque destinataire le compare à sa propre vue des
  membres et des appareils certifiés, et signale tout écart.

### 2.6 Stockage et rotation des clés d'appareil

- iOS : clés en Secure Enclave quand l'algorithme le permet, sinon Keychain
  `WhenUnlockedThisDeviceOnly`. Android : Keystore (StrongBox si disponible).
  Sous Android 12 (API 31), l'accord de clé Keystore n'existe pas : la clé est
  alors logicielle, chiffrée par une clé Keystore. Web : §2.7.
- La **clé d'accord** de chaque appareil tourne tous les 30 jours. La nouvelle
  clé reçoit un nouveau certificat.
- Le serveur **supprime une enveloppe d'époque** dès que l'appareil
  destinataire en a accusé réception.
- L'extension de notification (iOS) et le service de messagerie (Android)
  n'accèdent qu'aux époques courantes, jamais aux clés d'identité. Le réglage
  « aucun aperçu » supprime toute copie de clé accessible écran verrouillé.
- Après une restauration d'appareil, les clés locales ont disparu. Le client le
  détecte au démarrage et demande un nouvel enrôlement, plutôt que de laisser un
  appareil fantôme.

### 2.7 Appareils web

Une clé WebCrypto non extractible ne protège pas contre un JavaScript
malveillant, qui peut l'**utiliser**. Or le code web est fourni par le même
opérateur que l'API. En conséquence :

- les appareils web sont marqués « navigateur » dans les listes et les
  manifestes d'époque ;
- chaque conversation offre l'option « exclure les appareils web » ;
- le client web est servi depuis une origine statique distincte, avec une CSP
  stricte, l'intégrité des sous-ressources (SRI) et des bundles reproductibles
  publiés ;
- depuis le web, il est impossible d'approuver un appareil ou de restaurer par
  la récupération.

### 2.8 Récupération

- Bundle chiffré (HKDF-SHA256 puis AES-256-GCM) avec une clé de récupération
  aléatoire de 32 octets, présentée une seule fois à l'utilisateur. Le serveur
  ne détient jamais cette clé.
- **Règle normative** : un appareil N'ENVELOPPE une clé d'époque que vers la
  clé de récupération de **son propre compte**. Il n'utilise jamais une clé de
  récupération d'un autre membre fournie par le serveur.
- La clé de récupération ouvre tout l'historique **et** permet d'approuver un
  appareil. Son usage déclenche la même alerte qu'un nouvel appareil, puis une
  nouvelle clé de récupération est proposée.

---

## 3. Époques de conversation

Format de l'enveloppe : annexe A.3. Vecteur : `epoch-envelope-v1.json`.

### 3.1 Création

- La clé d'époque (32 octets) est générée par un **appareil certifié d'un
  membre actuel**, jamais par le serveur. Numéro croissant par conversation.
- Elle est enveloppée pour chaque appareil certifié de chaque membre, y compris
  les autres appareils du créateur. L'engagement de clé (annexe A.3) accompagne
  chaque enveloppe, et chaque enveloppe est signée par l'appareil créateur.
- L'époque est **acceptée** par comparaison-échange : le client envoie
  `previousEpochNumber`, et le serveur répond `409 E2EE_EPOCH_STALE` si une autre
  époque a été acceptée entre-temps. Un client n'utilise une époque qu'**après**
  son acceptation. En cas de conflit, il adopte l'époque acceptée et
  recommence si une rotation reste nécessaire.

### 3.2 Nouvelle conversation, nouveaux membres, nouveaux appareils

- Le créateur crée l'époque 1. La conversation est alors v2 pour toujours
  (§12).
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
- Déclencheurs : appareil certifié ajouté ou révoqué, membre ajouté ou retiré,
  réinitialisation d'identité, usage de la récupération, et au plus tard 30 jours
  ou 10 000 messages par époque.
- Le serveur publie aussi des exigences de rotation (confort) et les marque
  résolues quand une époque plus récente est acceptée. Leur absence ne dispense
  jamais un client de la règle ci-dessus.
- Un membre sans appareil certifié ne bloque pas une rotation : il est exclu de
  l'époque, et le reçoit dès qu'il a un appareil certifié.

### 3.4 Réception

Un client rejette un message :

- signé par un appareil révoqué, ou dont le certificat ne se vérifie pas ;
- chiffré sous une époque marquée compromise, s'il est postérieur à la date de
  compromission ;
- chiffré sous une époque qui n'est plus la courante depuis plus de 24 heures
  (fenêtre de tolérance pour les messages en vol).

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
- `CARD` : type `SITE` (fiche d'antenne) et `POST` (publication partagée).

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

- `POST /api/e2ee/v2/blobs`, puis `PUT /blobs/{id}/parts/{n}` (parts de 5 Mio),
  puis `POST /blobs/{id}/complete`, puis `GET /blobs/{id}/download` (URL signée,
  courte durée).
- Le serveur stocke des octets opaques. Il NE DOIT PAS inspecter, redimensionner
  ni transcoder. Un blob non référencé sous 24 heures est supprimé, sauf s'il
  fait l'objet d'un signalement (§11).
- Un message n'est accepté que si ses blobs sont complets et appartiennent à
  l'émetteur. `DELETE` et l'expiration du TTL purgent chiffrés et blobs, sauf en
  cas de signalement.

### 6.4 Côté client

- Tailles publiées par paliers Padmé : bourrage chiffré, retiré à la lecture.
- File d'envoi durable : chiffré sur disque, clé de média dans le trousseau
  jusqu'à l'envoi.
- Déchiffrement vers un fichier temporaire protégé (iOS
  `NSFileProtectionComplete`), exclu des sauvegardes. Il n'est affiché qu'après
  vérification des condensats. La lecture progressive d'une vidéo est permise
  morceau par morceau, puisque chaque morceau est authentifié. Tout est purgé à
  la déconnexion et à la révocation.
- Transférer un fichier vers une autre conversation le **rechiffre** avec une
  nouvelle clé de média.
- Limites : 512 Mio par blob, 1 Gio par message. Au-delà de 50 Mio en données
  mobiles, une confirmation est demandée.

---

## 7. Notes vocales

- `AUDIO` : manifeste du blob audio (AAC-LC en M4A, recommandé partout),
  `durationMs`, forme d'onde (charge v2) et transcription facultative.
- La transcription se fait **uniquement sur l'appareil**. Le serveur NE DOIT PAS
  transcrire une note d'une conversation chiffrée.

---

## 8. Réactions

- `REACTION` : cible, emoji, `ADD` ou `REMOVE`.
- Emoji : **un seul** emoji RGI, pleinement qualifié (avec `FE0F`), en NFC, de
  32 octets UTF-8 au plus. Tout autre emoji est rejeté.
- Agrégation par `(utilisateur, cible, emoji)`. `ADD` et `REMOVE` sont
  idempotents, et le dernier événement de cet utilisateur l'emporte.
- Notification : une notification générique, que l'extension précise après
  déchiffrement (§13).

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

### 10.1 Descripteur d'appel

- L'appelant crée un **descripteur signé par son appareil** :
  `SQ-E2EE-V2-CALL-DESCRIPTOR\n1\n<conversationId>\n<callId>\n<epochId>\n<epochNumber>\n<keyCommitmentB64>\n<callNonceB64>\n<createdAtMs>`,
  où `callNonce` est un aléa de 32 octets.
- Le serveur le relaie tel quel (réponse d'initiation, notification VoIP,
  `/api/calls/pending`) et enregistre `Call.e2eeRequired`, `e2eeEpochId` et
  `e2eeKeyId`.
- L'appelé vérifie la signature et le certificat de l'appelant, puis refuse :
  une époque qui n'est pas la **plus récente active** qu'il connaît, un
  descripteur de plus de 60 secondes, un `callNonce` déjà vu.

### 10.2 Clé de trame

- Clé = HKDF-SHA256 de la clé d'époque, avec le sel
  `SHA-256("SQ-E2EE-V2-CALL-FRAME-SALT\n2\n<conversationId>\n<epochNumber>\n<callId>\n<callNonceB64>")`
  et l'info `signalquest-e2ee-v2-call-frame-key-v2` : 32 octets. La version 1
  existante (sans `callNonce`, annexe A.7) est remplacée, avec un nouveau vecteur
  `call-frame-key-v2`.
- Aucune clé ne transite.

### 10.3 Réglages LiveKit figés, sur les trois SDK

- Mode clé partagée. Passphrase = la **chaîne** UTF-8 base64 standard de 44
  caractères de la clé de trame. Côté web, une chaîne et non un `ArrayBuffer`,
  sans quoi la dérivation change.
- La dérivation interne de LiveKit (PBKDF2, 100 000 itérations, sel
  `LKFrameEncryptionKey`) et la taille effective de la clé AES sont à établir
  avant tout code, par un vecteur `livekit-shared-key-v1` sur les SDK qui
  exportent la clé (Swift, Android), puis par un appel croisé à trois
  plateformes.
- `ratchetWindowSize = 0`, `keyRingSize = 16`, `encryptionType = gcm`,
  `discardFrameWhenCryptorNotReady = true`, marqueur « non chiffré » vide. Le
  SIF fourni par le serveur est **ignoré**.
- Nouvelle époque pendant l'appel : `setKey` à l'index
  `epochNumber mod keyRingSize` ; l'émission bascule une fois la nouvelle époque
  reçue par tous. `ratchetKey` est interdit.
- Un SDK qui ne permet pas ces réglages n'offre pas d'appel chiffré.

### 10.4 Vérification et fermeture par défaut

- Un appel dans une conversation chiffrée **est** chiffré. Le client le vérifie
  localement (§12) : il ne rejoint jamais en clair une conversation qu'il sait
  chiffrée, quoi que dise le serveur.
- Toute piste distante non chiffrée est refusée : désabonnement et fin de
  l'appel. Une piste n'est rendue qu'une fois son cryptor `ok`.
- À la jonction, chaque participant envoie sur le canal de données chiffré une
  **preuve signée** qui lie son identité LiveKit à son appareil certifié. Un
  participant sans preuve après 10 secondes met fin à l'appel, avec « Appel
  chiffré impossible ».
- `missing_key`, `encryption_failed`, `decryption_failed` ou `internal_error`
  retirent le cadenas et l'annoncent.
- Pas d'enregistrement composite ni de transcription serveur pour un appel
  chiffré.
- Limite à écrire : avec une clé partagée, tout détenteur de l'époque peut
  écouter, y compris depuis un participant caché (jeton `hidden`). La clé ne
  sort pas du cercle des membres, mais n'authentifie pas l'émetteur d'une
  trame.

### 10.5 Discrétion

- Notification VoIP sans nom d'appelant : l'extension le déchiffre.
- `includesCallsInRecents = false` pour un appel d'une conversation chiffrée, ce
  qui évite l'historique d'appels synchronisé par iCloud.
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
- **Serveur** : à la réception, il calcule
  `serverTag = HMAC-SHA256(Ks, frankTag ‖ conversationId ‖ envelopeId ‖ senderUserId ‖ senderDeviceId ‖ serverTimeMs ‖ keyId)`
  et le remet avec le message. Le destinataire le conserve.
- **Signalement** : pour chaque message (50 au plus), le client envoie la charge
  exacte, `fk`, `frankTag`, `serverTag` et `envelopeId`, plus les clés de média
  des blobs concernés. Le tout est chiffré en **HPKE** (RFC 9180 : DHKEM P-256,
  HKDF-SHA256, AES-256-GCM) pour une clé de modération **épinglée dans les
  apps**. Aucune clé d'époque n'est transmise.
- Le serveur vérifie seulement que le signaleur était membre au moment des
  messages, et conserve les blobs signalés. **L'outil de modération**, isolé et
  seul détenteur de la clé privée, vérifie tags et condensats et déchiffre.
- Contexte : le signaleur peut joindre des messages voisins, mais seulement
  des messages qu'il a lui-même reçus, chacun franké.
- L'utilisateur est prévenu, avant d'envoyer, que les messages signalés seront
  lisibles par l'équipe de modération.

---

## 12. Capacités et états collants

- Chaque appareil déclare ses capacités dans son certificat et à chaque mise à
  jour : versions d'enveloppe et de charge, `kind` pris en charge, médias,
  appels vérifiés.
- **Capacité d'une conversation** = intersection des capacités des appareils
  certifiés des membres. Un appareil inactif depuis 90 jours est révoqué
  automatiquement, pour ne pas tirer l'intersection vers le bas.
- Une fonction absente de l'intersection est désactivée, avec « Un membre doit
  mettre à jour SignalQuest pour recevoir les photos chiffrées ». Jamais de
  repli en clair. Le serveur refuse (`409 E2EE_CAPABILITY_MISSING`) un contenu
  que la conversation ne peut pas recevoir.
- **États collants** :
  - « chiffrée » et « v2 » dérivent d'éléments signés (l'époque 1 signée par le
    créateur), sont mémorisés par l'appareil, et aucune réponse serveur ne peut
    les faire régresser ;
  - un appareil qui découvre une conversation (nouvel appareil) se fie à
    l'époque 1 signée, pas à un booléen du serveur ;
  - tout message v1 postérieur à l'époque 1 v2 est rejeté ;
  - un interrupteur de déploiement peut seulement **désactiver** une fonction,
    jamais repasser en clair ni en v1.

---

## 13. Surfaces fermées par défaut

Chaque surface a un test prouvant que rien ne sort en clair.

| Surface | Règle |
|---|---|
| Composeur (photo, micro, sondage, réaction, position) | désactivé si la conversation ne prend pas la fonction en charge |
| Messages programmés | refusés en v2, ou rechiffrés à l'échéance par l'appareil émetteur |
| Réponses en fil, citations, transferts | chiffrés ; transfert vers une conversation en clair refusé |
| Notifications push | titre et corps génériques ; aperçu seulement après déchiffrement par l'extension ; rien si « aucun aperçu » |
| Réponse rapide (notification, montre, CarPlay, Android Auto, Siri) | chiffrée comme un message, sinon indisponible |
| Widgets, Live Activities, Spotlight, cibles de partage | aucun contenu déchiffré indexé ni affiché |
| Recherche | uniquement sur l'appareil |
| Rappels, notes privées | chiffrés avec une clé propre à l'utilisateur, ou gardés sur l'appareil |
| Aperçus de liens | générés sur l'appareil, au choix de l'utilisateur ; jamais par le serveur |
| Partage de position (anciennes routes) | refusé dans une conversation chiffrée |
| Export | chiffré, ou averti et confirmé ; jamais d'archive en clair silencieuse |
| Presse-papiers | local seulement, avec expiration (Android : contenu marqué sensible) |
| Sélecteur d'apps | instantané masqué (Android : `FLAG_SECURE` en option) |
| Sauvegardes système | clés et caches déchiffrés exclus, de façon normative |
| Journaux, Crashlytics, analytics | aucun contenu ni identifiant de message ; pas de clé dans `userInfo` |
| Transcription, résumé, enregistrement serveur | indisponibles |

---

## 14. Migration depuis la v1

1. Les conversations v1 restent lisibles, avec la mention « ancien chiffrement,
   clé connue du serveur » et sans cadenas.
2. À la première ouverture par un client v2, si tous les membres ont un appareil
   certifié, ce client crée l'époque 1 v2 : la conversation est alors v2 pour
   toujours (§12).
3. La recopie de l'historique en v2 est facultative. Elle est faite par un
   appareil (vecteur `history-migration-v1.json`), jamais par le serveur. Les
   messages recopiés portent « importé par <appareil> » et n'héritent d'aucune
   authenticité.
4. Quand la v2 est activée, le serveur cesse toute génération de clé v1.

---

## 15. Encodages, vecteurs et interopérabilité

- Formats **existants** (annexe A) : chaînes canoniques séparées par `\n`,
  identifiants au format opaque (qui empêche d'y injecter `\n`), base64
  standard avec bourrage sauf mention « base64url sans bourrage ».
- Formats **nouveaux** : JSON canonique RFC 8785 et I-JSON (RFC 7493), avec
  rejet des clés dupliquées et des substituts isolés ; limites en **octets
  UTF-8** ; dates RFC 3339 en UTC à la milliseconde (`Z`) ; un tableau
  « champ → encodage » par format ; décodage strict qui rejette les formes non
  canoniques.
- Cryptographie : points P-256 en X9.63 non compressé (65 octets), validés
  (sur la courbe, pas l'infini). Signatures ECDSA en DER, forme low-S, avec
  conversion depuis `r‖s` pour WebCrypto. Android convertit ses clés
  SubjectPublicKeyInfo en X9.63.
- Source unique des vecteurs : `contracts/e2ee-v2/*.json`, identiques à
  l'octet près dans les dépôts iOS, Android et serveur, et vérifiés par
  condensat en CI. Le web consomme ceux du serveur.
- Vecteurs existants : `blob-chunks-v1`, `call-frame-key-v1`,
  `content-payload-v1`, `device-approval-v1`, `device-bootstrap-v1`,
  `epoch-envelope-v1`, `history-migration-v1`, `live-location-payload-v1`,
  `message-envelope-v1` (à corriger), `recovery-bundle-v1`,
  `recovery-epoch-envelope-v1`, `recovery-proof-v2`, `signed-request-v1`.
- À créer : `device-cert-v1`, `device-list-v1`, `safety-number-v1`,
  `message-ref-v1`, `message-envelope-v2` (compteur, bourrage, franking),
  `content-payload-v2`, `franking-v1`, `call-descriptor-v1`,
  `call-frame-key-v2`, `livekit-shared-key-v1`, `capability-intersection-v1`.
- Chaque plateforme exécute tous les vecteurs dans les deux sens, plus au moins
  un **vecteur négatif par règle** (signature fausse, AAD altérée, morceau
  manquant, octets après `FINAL`, engagement faux, clé JSON dupliquée, tag de
  franking faux, époque obsolète).

---

## 16. Déploiement, quotas et exploitation

Étapes, chacune derrière une capacité serveur et la revue de sécurité :

1. **Serveur** : routes v2 (certificats et listes signées, époques, enveloppes,
   messages, blobs, franking), refus du §13, capacité de conversation.
2. **iOS** : chaîne de confiance, envoi et réception v2 du texte, puis médias,
   vocal, réactions, sondages, puis appels vérifiés.
3. **Android** : pile v2 complète et parité.
4. **Web** : pile v2 en WebCrypto, avec les limites du §2.7.
5. **Activation** conversation par conversation, via l'intersection des
   capacités.

Quotas (valeurs de départ, à ajuster) : 10 époques par conversation et par
heure ; 5 approbations d'appareil par compte et par jour ; 20 signalements par
compte et par jour ; 1 Gio de blobs par message.

Outbox : un message préparé sous une époque qui change avant l'envoi est
rechiffré, sa charge étant gardée dans le trousseau jusqu'à l'envoi. Un message
dont l'émetteur est révoqué est abandonné.

Télémétrie sans contenu : échecs de déchiffrement par type, versions de
protocole, états des cryptors d'appel.

---

## 17. Sécurité et gouvernance

- **Relecture indépendante** de cette spécification (faite pour la v0.1, dont
  les conclusions sont intégrées ici), puis de chaque implémentation, par un
  relecteur qui n'a pas écrit le code. Pas de revue externe générale, par
  décision produit.
- **Tests croisés** sur deux comptes et trois plateformes : chaque type de
  contenu, dans les deux sens, en ligne et hors ligne, avec ajout, révocation et
  réinitialisation d'appareil.
- **Tests d'attaque** : un serveur qui ajoute un appareil, fournit une ancienne
  liste, désigne une ancienne époque pour un appel, injecte une trame non
  chiffrée, renvoie « non chiffrée » à un nouvel appareil ou rejoue un message.
  Chacun doit échouer, et le client doit l'annoncer.

---

## 18. Questions ouvertes

1. Calendrier de la fin de la génération serveur des clés v1 : avant la
   prochaine bêta publique, ou avec la v2 ?
2. Appels dans les conversations chiffrées tant que les appels vérifiés ne sont
   pas disponibles partout : refuser des deux côtés, ou autoriser après une
   confirmation explicite « appel non chiffré » ?
3. Revue externe ciblée sur la chaîne de confiance, la récupération et les
   appels, avant la mise en service générale ? C'est la recommandation de la
   relecture ; aujourd'hui, la décision produit est « pas de revue externe ».
4. Appareils web : les inclure par défaut dans les conversations chiffrées, ou
   seulement sur demande ?
5. Évaluer MLS (RFC 9420, OpenMLS) pour une v3.

---

## Annexe A — Octets sur le fil (formats v1 existants)

Transcrits du code iOS (`SignalQuestApp/Core/Shared/E2EEV2NotificationContracts.swift`,
`SignalQuestApp/Services/E2EEService.swift`), qui reproduit les vecteurs. En cas
d'écart, **les vecteurs font foi**. Notations : `‖` concaténation, `\n` saut de
ligne (0x0A), `b64` base64 standard avec bourrage, `b64url` base64url sans
bourrage.

### A.1 Identifiants

- Identifiant opaque (conversation, appareil, blob, message cible, option) :
  `^[A-Za-z0-9][A-Za-z0-9_-]{15,127}$`.
- `clientRequestId` : `^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$`.
- Nonce de requête : `^[A-Za-z0-9_-]{16,128}$` (24 octets aléatoires en
  b64url).

### A.2 Requête signée

Chaîne signée (ECDSA P-256, DER) :
`SQ-E2EE-V2\n<MÉTHODE>\n<cible>\n<timestampMs>\n<nonce>\n<b64url(SHA-256(corps))>`.
`<cible>` est le chemin plus la requête brute, sans ré-encodage, qui commence
par `/`, fait au plus 512 octets, a au plus un `?` et aucun `#` ni `\n`.
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
- Manifeste, clés exactes : `blobId`, `algorithm`, `mediaKeyB64`,
  `noncePrefixB64`, `cryptoChunkSize` (262 144), `plaintextSize` et
  `ciphertextSize` (chaînes décimales `^(0|[1-9][0-9]{0,11})$`),
  `plaintextSha256` et `ciphertextSha256` (hexadécimal minuscule, 64
  caractères), `fileName` (≤ 512), `mimeType` (≤ 255), `width` et `height`
  (1 à 100 000 ou null), `durationMs` (0 à 86 400 000 ou null).

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

| Bloc | Serveur | iOS | Android | Web |
|---|---|---|---|---|
| Chaîne de confiance (UIK, certificats, listes signées, numéro de sécurité) | 5 | 6 | 7 | 6 |
| Identités d'appareil, requêtes signées, stockage matériel | 1 | 2 | 8 | 6 |
| Époques, rotation décidée par le client, capacités, états collants | 6 | 5 | 7 | 6 |
| Enveloppe et charge v2 (texte, édition, suppression, réactions, sondages) | 5 | 6 | 8 | 7 |
| Blobs (photos, fichiers, vocal) | 5 | 5 | 7 | 6 |
| Appels vérifiés (descripteur, réglages LiveKit, preuve de jonction) | 3 | 4 | 6 | 6 |
| Franking et outil de modération | 5 | 2 | 2 | 2 |
| Surfaces fermées par défaut | 2 | 3 | 4 | 3 |
| Migration v1 → v2 | 2 | 3 | 4 | 3 |
| Vecteurs (dont négatifs), CI, tests croisés et d'attaque | 4 | 4 | 5 | 4 |
| **Total indicatif** | **~38** | **~40** | **~58** | **~49** |

iOS part du plus d'existant : primitives v2, vecteurs, blobs, clé d'appel,
approbations. Android et le web partent de la v1.
