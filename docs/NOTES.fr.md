# CopyBar

App macOS de barre de menus qui suit les copies du Finder : pourcentage dans la barre
pendant une copie, notification à la fin, menu listant les copies en cours avec une action
qui ramène la fenêtre de progression du Finder au premier plan, et **historique des copies**
(élément, provenance, destination, taille, durée, débit) avec **marche arrière**.

Écrite le 16 novembre 2026, testée uniquement sur **macOS 27.0.1 (Apple Silicon), Finder en
français**. Swift + AppKit, un seul fichier source, pas de projet Xcode.

## État au 18/11/2026

| Quoi | Où |
|---|---|
| Sources de référence | ce dossier (`CopyBar.swift`, `build.sh`) |
| App installée et en service | `~/bin/CopyBar/CopyBar.app` — **version antérieure, sans historique** (pas encore mise à jour) |
| Historique | `~/Library/Application Support/<identifiant de bundle>/history.json` (50 entrées max) |
| Lancement au login | enregistré via `SMAppService` sur le chemin `~/bin/CopyBar/CopyBar.app` |
| Journal de l'app | `~/Library/Logs/CopyBar.log` |
| Identifiant de bundle | `local.copybar` |
| Autorisations accordées | Accessibilité et Notifications, pour le build installé |

Ce dossier est en avance sur `~/bin/CopyBar`. Pour mettre l'app installée à jour : quitter
CopyBar, copier `CopyBar.app` d'ici vers `~/bin/CopyBar/`, relancer, puis réaccorder
l'Accessibilité (signature ad hoc : voir « Pièges »).

### Depuis le 18/11/2026 : signature et publication

- Identifiant de bundle définitif : `io.github.alnilam-404.copybar` (les mentions de
  `local.copybar` plus bas décrivent l'état antérieur). L'historique suit l'identifiant :
  `~/Library/Application Support/io.github.alnilam-404.copybar/history.json`.
- `./build.sh` reste un build local signé ad hoc. Avec
  `COPYBAR_SIGN_IDENTITY="Developer ID Application"`, il signe avec le certificat du
  trousseau (runtime renforcé, horodatage) et l'autorisation Accessibilité survit aux mises à jour.
- `./release.sh` : build universel signé, notarisation (`notarytool`, profil de trousseau
  `copybar`), agrafage, zip `CopyBar-<version>.zip`. Exécuté avec succès le 18/11/2026
  (« Notarized Developer ID »).
- Le bundle est assemblé et signé dans un dossier temporaire : ce dossier-ci est synchronisé
  par iCloud, qui ajoute des attributs étendus refusés par `codesign` (« detritus not
  allowed ») et invalide la vérification stricte de la copie déposée ici.

## Contenu

```
CopyBar.swift        toute l'app (~1 230 lignes)
build.sh             compile, crée CopyBar.app, signe ad hoc, purge l'entrée TCC Accessibilité
outils/axdump.swift  sonde : dumpe l'arbre AX des fenêtres du Finder
outils/cbprobe.swift test : lit l'élément de barre de menus de CopyBar, ouvre son menu, clique un élément
outils/cbmenu.swift  test : liste le menu avec ses sous-menus (historique), clique un élément par chemin, lit et valide une alerte
outils/axwin.swift   test : état de la fenêtre de progression (minimisée, principale) et app au premier plan
```

## Construire et lancer

```sh
./build.sh             # produit ./CopyBar.app et purge l'autorisation Accessibilité (voir ci-dessous)
./build.sh --keep-tcc  # compile sans toucher aux autorisations de l'app installée
open CopyBar.app
```

Prérequis : les outils en ligne de commande Xcode (`swiftc`). Cible macOS 13 minimum
(à cause de `SMAppService`), jamais essayée en dessous de 27.

Au premier lancement, deux autorisations à donner :

1. **Accessibilité** — Réglages Système › Confidentialité et sécurité › Accessibilité.
   Sans elle l'app ne voit rien : icône ⚠ et entrée « Autoriser l'accès Accessibilité… ».
2. **Notifications** — une bannière de demande s'affiche ; sinon Réglages Système ›
   Notifications › CopyBar. Tant que ce n'est pas autorisé, le menu propose
   « Activer les notifications… ».

**Attention, `build.sh` agit sur l'app installée** : il exécute
`tccutil reset Accessibility local.copybar`, et l'identifiant de bundle est le même quel que
soit le dossier. Reconstruire ici retire donc l'autorisation Accessibilité de l'app en
service jusqu'à ce qu'on la réaccorde. Voir « Pièges ».

## Comment ça marche

### La source de données : la fenêtre de progression du Finder

Le Finder n'expose aucune API de progression. L'app lit sa fenêtre de progression par l'API
d'accessibilité (`AXUIElement`). Structure relevée par la sonde :

```
AXWindow  AXIdentifier=Progress  AXTitle=Copie  actions=[AXRaise]
  AXScrollArea
    AXImage             "Élément du Finder"                              ┐
    AXStaticText        "Copie de « x.bin » dans « Volume »"             │ une ligne
    AXProgressIndicator AXValue=0.709  AXMinValue=0  AXMaxValue=1        │ par copie
    AXButton            "arrêter la progression"  [AXPress]              │
    AXStaticText        "8,93 Go sur 12,58 Go – Environ 5 secondes"      ┘
    AXImage … (ligne suivante)
  AXButton AXCloseButton / AXZoomButton / AXMinimizeButton
```

Faits observés, sur lesquels le code repose :

- **Une seule fenêtre** pour toutes les copies, une ligne par copie dans la zone de défilement.
- La fenêtre **n'apparaît que 2 à 3 s après le début** d'une copie et disparaît à la fin.
  Une copie très courte n'est donc jamais vue, ni notifiée.
- Les lignes **n'ont aucun identifiant stable** (`_NS:59`, `_NS:81`… sont les mêmes pour
  toutes les lignes).
- Le **titre change pendant la copie** quand il y a plusieurs éléments : « Copie de 21 699
  éléments dans « b » » devient « Copie de 895 éléments… » (c'est le reste à copier).
- Quand une ligne disparaît, **rien ne dit pourquoi** : fin normale, annulation, erreur.
- La reconnaissance ne dépend pas de la langue : elle utilise `AXIdentifier=Progress` et
  les rôles AX. Les textes sont affichés tels quels.

### Architecture de `CopyBar.swift`

| Bloc | Rôle |
|---|---|
| `log()` | écrit dans `NSLog` et dans `~/Library/Logs/CopyBar.log` |
| `FinderProbe` | lecture AX : `read()` renvoie un `Reading` (`untrusted`, `noFinder`, `failed`, `ok(lignes, fenêtre)`), `raise()` ramène la fenêtre devant |
| `Tracker` | fait le lien entre les lignes d'un relevé et celles du précédent, renvoie les copies disparues |
| `Copy` | une copie suivie : premier titre, heure de début, dernière ligne lue, vitesse, `wasInterrupted` |
| `Title` | analyse des textes du Finder : noms entre guillemets, taille totale |
| `OriginProbe` | retrouve sur disque les éléments en cours de copie et leurs sources possibles |
| `Entry`, `History` | une copie finie (chemins vérifiés, issue, taille) et la liste enregistrée en JSON |
| `AppDelegate` | élément de barre de menus, menu, timer, notifications, élément de login, historique et marche arrière |

Déroulement : un `DispatchSourceTimer` lit le Finder **toutes les secondes sur une file de
fond** (un appel AX peut bloquer si le Finder ne répond pas), puis `apply()` met à jour
l'état sur le fil principal et `render()` rafraîchit l'affichage.

**Appariement des lignes** (`Tracker.update`) :

1. même titre → même copie ;
2. sinon, appariement dans l'ordre avec les anciennes copies restantes, à condition que la
   progression n'ait pas reculé de plus de 2 points (sinon c'est une nouvelle copie qui
   prend la place d'une copie finie) ;
3. anciennes copies non appariées → terminées ; nouvelles lignes non appariées → nouvelles copies.

**Terminée ou interrompue** (`Copy.wasInterrupted`) : on extrapole la progression au moment
de la disparition, `dernière valeur + vitesse × temps écoulé × 1,5`. En dessous de 85 %, la
notification dit « Copie interrompue — arrêtée vers N % ». Sans mesure de vitesse (copie vue
un seul relevé) ou sans valeur de progression, on la suppose terminée. C'est une
**heuristique**, pas une information du Finder.

**Affichage** :

- repos : icône `doc.on.doc` seule ; copie : `doc.on.doc.fill` + « 42 % » ; plusieurs
  copies : moyenne des progressions + nombre, « 42 % (3) » ; indicateur indéterminé : « … ».
- Le menu n'est reconstruit que si sa structure change (nombre de copies, autorisations) ;
  sinon seuls les titres sont mis à jour, pour qu'il reste utilisable ouvert.
- Une lecture AX en erreur (`failed`) est **ignorée** : surtout ne pas déclarer toutes les
  copies terminées sur un raté passager. Finder absent → copies oubliées sans notification.

**Premier plan** (`FinderProbe.raise`) : `AXMinimized=false`, action `AXRaise`, puis
`AXFrontmost=true` sur l'application Finder.

**Login** : `SMAppService.mainApp.register()` au premier lancement (drapeau
`loginItemConfigured` dans les préférences), ensuite seul l'élément de menu le change.

## Historique et marche arrière

Menu › **Historique** : une entrée par copie finie (la plus récente en haut), avec un
sous-menu : titre du Finder, élément(s), « De », « Vers » (cliquables : ouvrent le dossier),
taille · nombre de fichiers · durée · débit, issue, puis « Afficher dans le Finder »,
« Faire marche arrière… » et « Retirer de l'historique ». « Effacer l'historique » vide la
liste (sans toucher aux fichiers).

### D'où viennent les chemins

La fenêtre de progression ne donne que des noms. Les chemins viennent de deux observations
faites le 18/11/2026 (`OriginProbe`), sans autorisation supplémentaire :

- **Marqueur « en cours ».** Le Finder donne à tout élément en cours de copie la date de
  création du **24 janvier 1984** (08:00 UTC), y compris au dossier de premier niveau d'une
  copie de dossier ; à la fin, il lui rend la date de création de l'original.
- **Gros fichier ouvert.** Pendant la copie d'un gros fichier, le Finder garde le fichier de
  destination ouvert : `proc_pidinfo` le montre. Pas pendant une copie de petits fichiers.
- **Dossiers des fenêtres.** Les fenêtres du Finder n'ont pas d'`AXDocument`, mais leurs
  éléments affichés ont un `AXURL` : le parent d'un élément visible donne le dossier affiché
  (toutes les colonnes en présentation par colonnes).

Destination : on cherche des éléments marqués 1984 dans les dossiers candidats (dossiers des
fenêtres du Finder, dossiers que le Finder tient ouverts, bureau, dossiers usuels du compte,
volumes) dont le nom correspond à celui cité dans le titre (« … dans « y » »), ou dans un
sous-dossier de ce nom. Provenance : élément de même nom dans un autre dossier candidat ou
dans le presse-papiers (copier-coller et glisser-déposer y laissent les URL), **retenu
seulement s'il est identique** à la copie (même date de création, même taille pour un
fichier). Si une source présente au début a disparu à la fin, c'était un **déplacement**.

L'issue affichée est confirmée par le disque : éléments identiques à leur source → terminée ;
plus rien à destination → interrompue ; élément encore marqué 1984 → « fin non observée ».

### Marche arrière

- **Copie** : les éléments copiés partent à la **corbeille** ; les originaux ne sont pas
  touchés. Proposée seulement si l'original a été retrouvé identique, et sa présence est
  revérifiée au moment d'agir, ainsi que l'identité (inode) de l'élément à retirer. Volume
  sans corbeille : une seconde confirmation propose la suppression définitive.
- **Déplacement** : les éléments sont remis à leur emplacement d'origine (refusé si un
  élément du même nom y existe).
- Toujours après confirmation, avec la liste des éléments. Sinon le menu affiche « Marche
  arrière indisponible : provenance non vérifiée ».

### Limites connues

- Chemins non retrouvés si la destination n'est visible dans aucune fenêtre du Finder au
  moment de la copie (et que ce n'est ni le bureau, ni un volume, ni un dossier usuel) : l'entrée
  n'a alors que le titre, la taille lue dans la fenêtre et la durée.
- Copie de plusieurs éléments : ceux copiés en moins de 2-3 s ne sont jamais vus « en cours ».
  Sur un volume local ils sont rattrapés par la date d'ajout au dossier ; **sur un NAS (pas de
  date d'ajout) ils peuvent manquer** dans la liste, d'où « N éléments identifiés ».
- Le titre du Finder est analysé par ses guillemets (« », “ ”, " ") : avec une autre
  convention, la recherche se rabat sur les 15 premiers dossiers candidats.
- Un déplacement AppleScript entre volumes est en réalité une copie (la source reste).

## Pièges rencontrés

**Signature ad hoc et Accessibilité.** Une signature ad hoc n'a pas d'identité stable : TCC
retient le hash du binaire. Après chaque recompilation, l'entrée Accessibilité existe
toujours, case cochée, mais ne correspond plus (`SecStaticCodeCheckValidity … -67050` dans
le journal de `tccd`). D'où le `tccutil reset` dans `build.sh`, pour que macOS redemande
proprement. Seule une vraie identité de signature règle le problème.

**Bannière de notifications fermée sans réponse.** Si la demande d'autorisation est fermée
sans réponse — ce qui arrive si l'app est tuée pendant que la bannière est affichée — macOS
passe l'app en « refusé » et ne redemande plus : `requestAuthorization` renvoie
`UNErrorDomain Code=1 "Notifications are not allowed for this application"`. Il faut alors
passer par Réglages › Notifications. L'entrée de menu « Activer les notifications… » y mène.

**Apps de test dans `/private/tmp`.** Des mini-apps placées là se voient refuser les
notifications pour une autre raison (`usernoted` : « Failed to find or validate client »).
Ne pas tester les notifications depuis un dossier temporaire.

**`log` dans zsh.** Dans ce shell, `log` est masqué ; utiliser `/usr/bin/log`. Commandes
qui ont servi au diagnostic :

```sh
/usr/bin/log show --last 2m --info --debug --style compact \
  --predicate 'process == "usernoted" AND eventMessage CONTAINS "local.copybar"'
/usr/bin/log show --last 2m --info --style compact \
  --predicate 'process == "Finder" AND subsystem == "com.apple.DesktopServices"'
```

**Disque plein pendant les tests.** `duplicate … with replacing` garde l'ancien fichier
jusqu'à la fin de la copie : il faut la place pour les deux. C'est cet échec réel
(`dskFulErr`) qui a révélé que la première version annonçait « terminée » une copie
échouée, et motivé l'heuristique d'interruption.

## Refaire les tests

Une copie sur le même volume APFS est un clone instantané : il faut **un autre volume**.
Les tests ont utilisé une image disque et un fichier aléatoire (non compressible) :

```sh
T=~/copybar-test && mkdir -p $T/src
hdiutil create -size 40g -type SPARSE -fs APFS -volname CopyBarTest $T/test.sparseimage
hdiutil attach $T/test.sparseimage
dd if=/dev/urandom of=$T/src/gros.bin bs=1m count=12000        # 12 Go, ~25 s de copie

# copie pilotée par le Finder (demande l'autorisation Automatisation la première fois)
osascript -e 'with timeout of 600 seconds' \
  -e "tell application \"Finder\" to duplicate (POSIX file \"$T/src/gros.bin\" as alias) to (POSIX file \"/Volumes/CopyBarTest/\" as alias) with replacing" \
  -e 'end timeout' &
```

Pour le cas « nombreux petits fichiers » (titre qui change) : 60 dossiers de 500 fichiers
de 8 Ko. Pour le cas « interrompue » : relancer deux copies vers une destination qui
contient déjà les fichiers, jusqu'à saturer l'image.

Outils (les compiler avec `swiftc -O outils/X.swift -o X`) ; ils ont besoin du droit
Accessibilité **pour le terminal qui les lance** :

```sh
./axdump            # arbre AX complet des fenêtres du Finder ; « ./axdump brief » : liste seule
./cbprobe           # titre et infobulle de l'élément de barre de menus de CopyBar
./cbprobe menu      # ouvre le menu et liste ses éléments
./cbprobe menu press:"Afficher la fenêtre"     # clique un élément du menu
./axwin [minimize]  # état de la fenêtre de progression, app au premier plan
```

Astuce : lancer le binaire directement (`CopyBar.app/Contents/MacOS/CopyBar &`) le fait
hériter du droit Accessibilité du terminal, ce qui évite de réaccorder l'autorisation à
chaque build pendant le développement. Les notifications, elles, restent liées au bundle.

Résultats du 16/11/2026, avec l'app lancée normalement : pourcentage et compteur corrects
avec 2 et 3 copies simultanées, une notification présentée par copie (vérifié dans le
journal de `usernoted`), échec sur disque plein classé « interrompu » (derniers relevés
71 % et 59 %), succès classés « terminé » (derniers relevés 91 à 100 %).

Résultats du 18/11/2026 (historique), build de test lancé depuis le terminal, copies
pilotées par AppleScript entre le disque interne et une image disque APFS : fichier de 10 Go,
dossier de 18 fichiers, lot de deux éléments (dont un de 300 Mo copié trop vite pour être vu
en cours, rattrapé par la date d'ajout) — destination, provenance, taille et nombre de
fichiers exacts ; marche arrière vers la corbeille vérifiée (originaux intacts) ; déplacement
simulé (source supprimée à la fin de la copie) détecté et remis à sa place.

## Ce qui n'a pas été vérifié

- Historique sur un **NAS (SMB)** : marqueur 1984, corbeille, vitesse des relevés de dossier.
- Historique avec un vrai glisser-déposer ou copier-coller (les tests passaient par
  AppleScript, presse-papiers vides) et avec un vrai déplacement Finder (⌘-glisser).
- Deux copies simultanées vers le même dossier ; copie avec « Conserver les deux ».
- Une ligne de progression a disparu une fois en pleine copie (les deux versions de l'app
  l'ont crue interrompue à 11 %), non reproduit. Piste : fenêtre de progression sur un autre
  bureau (Spaces), absente de la liste AX.

- Le **démarrage réel au login** : l'élément est enregistré et actif, mais aucune fermeture
  de session n'a été faite.
- L'action « Afficher la fenêtre de progression » depuis l'app lancée normalement : elle a
  été testée en lançant le binaire depuis le terminal.
- Les autres opérations du Finder (déplacement, vidage de corbeille, copie réseau lente) :
  elles passent probablement par la même fenêtre, non testé.
- La phase « Préparation… » avec indicateur indéterminé : prévue dans le code, jamais
  observée (les copies de test démarraient trop vite).
- Fenêtre de progression sur un autre bureau (Spaces) ou en plein écran.
- Finder dans une autre langue, autres versions de macOS, Mac Intel.
- Une annulation manuelle par le bouton stop (seul l'échec disque plein a été observé).

## Pour continuer

**Déplacer l'app.** `SMAppService` enregistre le chemin du bundle. Avant de déplacer ou de
supprimer `~/bin/CopyBar/CopyBar.app` : décocher « Lancer au login » dans le menu, quitter,
déplacer, relancer, recocher. Puis réaccorder l'Accessibilité si le binaire a changé.

**Pour en faire quelque chose de déployable**, dans l'ordre d'importance :

1. **Vraie signature.** Signer avec une identité Developer ID et notariser (`notarytool`).
   C'est ce qui rend l'autorisation Accessibilité durable d'une version à l'autre, et ce
   qui évite le blocage Gatekeeper chez les autres. Retirer alors le `tccutil reset` de
   `build.sh`. Une identité de signature est présente dans le trousseau de cette machine
   (type non vérifié) ; avec un certificat stable, même non Developer ID, le problème TCC
   local disparaît déjà.
2. **Identifiant de bundle** définitif en nom de domaine inversé à la place de
   `local.copybar` (cela repart de zéro pour les autorisations et l'élément de login).
3. **Pas de Mac App Store** : le bac à sable interdit de lire l'interface d'une autre app
   par l'accessibilité. Distribution directe uniquement (zip ou dmg notarisé).
4. **Projet Xcode ou paquet SwiftPM**, icône d'app, numéro de version, binaire universel
   (`build.sh` ne compile que pour l'architecture de la machine).
5. **Robustesse face au Finder.** Tout repose sur une structure d'interface non documentée
   qu'Apple peut changer à chaque version. À prévoir : test de la structure au démarrage
   avec un message clair si elle n'est plus reconnue, et essais sur chaque macOS visé.
6. **Écran d'accueil** expliquant les deux autorisations, plutôt que les seules entrées de menu.
7. ~~Localisation~~ : fait le 18/11/2026. Interface en français si c'est la langue du Mac, en
   anglais sinon (fonction `L(fr, en)` dans le code, pas de fichiers `.lproj`). Le journal reste en français.

**Améliorations possibles du fonctionnement :**

- Remplacer le polling par un `AXObserver` (création/destruction de fenêtre, changement de
  valeur) : moins de réveils, et fin de copie détectée sans attendre une seconde.
- Affiner « terminée / interrompue » : vérifier la présence du fichier de destination quand
  le titre donne un nom unique, ou repérer la fenêtre d'alerte du Finder.
- Octets et temps restant dans la barre : les textes de détail sont localisés, il faudrait
  les analyser par langue.
- Clic sur la notification → ramener la fenêtre ou révéler la destination.
- Réglages : intervalle, son, seuil de durée en dessous duquel on ne notifie pas.
- Tests unitaires de `Tracker` : c'est une structure pure, sans AX, facile à tester avec
  des suites de relevés (les cas réels sont décrits plus haut).
- Se servir du marqueur 1984 pour le suivi lui-même : tant qu'un élément est marqué, la copie
  n'est pas finie, même si sa ligne a disparu de la fenêtre (verrouillage, autre bureau).
