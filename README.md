# StorageScope

StorageScope est une application macOS native, locale et sans télémétrie qui répond à une question simple : **qu’est-ce qui occupe réellement le stockage de ce Mac ?**

La version 2.0.1 est une application SwiftUI complète. Elle analyse les fichiers accessibles, classe tout l’espace identifié, agrège les dossiers, permet une exploration visuelle exhaustive et ne modifie que les éléments explicitement confirmés.

## Installer une version publiée

Les releases GitHub contiennent une application **universelle Apple Silicon + Intel**, compatible avec macOS 14 et les versions ultérieures. La page [Releases](https://github.com/laBrioche97/StorageScope/releases) permet de choisir précisément la version à installer.

Installation de la dernière version publiée, avec vérification SHA-256. Téléchargez et examinez d’abord le petit script d’installation :

```sh
curl -fsSLo StorageScope-install.zsh https://raw.githubusercontent.com/laBrioche97/StorageScope/main/scripts/install-release.sh
less StorageScope-install.zsh
/bin/zsh StorageScope-install.zsh latest
```

Installation d’une version précise :

```sh
/bin/zsh StorageScope-install.zsh 2.0.1
```

L’installeur télécharge uniquement la release officielle, vérifie sa somme SHA-256, son identifiant de bundle, sa signature et la présence des deux architectures avant de remplacer l’application. Il conserve temporairement la version précédente dans `/tmp` et ne ferme jamais de force une instance en cours d’exécution.

Pour une installation manuelle, téléchargez `StorageScope-universal.zip` et `StorageScope-universal.zip.sha256` depuis la release choisie, placez-les dans le même dossier, puis exécutez :

```sh
shasum -a 256 -c StorageScope-universal.zip.sha256
```

Décompressez ensuite l’archive et déplacez `StorageScope.app` dans `/Applications`. Une release ad hoc non notariée doit être ouverte une première fois avec **clic droit → Ouvrir**. L’installeur ne retire pas l’attribut de quarantaine ; il l’ajoute même lorsque `curl` ne l’a pas transmis à une release refusée par Gatekeeper. Les releases signées Developer ID et notariées s’ouvrent normalement. Dans les deux cas, ajoutez ensuite StorageScope dans **Réglages Système → Confidentialité et sécurité → Accès complet au disque**.

La procédure de publication, les secrets facultatifs de signature et la restauration d’une ancienne version sont documentés dans [DISTRIBUTION.md](DISTRIBUTION.md).

## Ouvrir et lancer dans Xcode

Prérequis : macOS 14 ou ultérieur, un Mac Apple Silicon ou Intel, et une installation complète récente de Xcode.

1. Ouvrir `Package.swift` avec Xcode (`File > Open`).
2. Sélectionner le scheme **StorageScope** et la destination **My Mac**.
3. Compiler avec `⌘B`, puis lancer avec `⌘R`.
4. Pour les tests, sélectionner le scheme **StorageCoreTests** et l’exécuter. Cette cible autonome ne dépend ni d’Internet ni d’un framework tiers.

En ligne de commande avec une installation Xcode complète :

```sh
swift build
swift run StorageCoreTests
swift run StorageScope
```

### Construire une véritable application macOS

La commande `swift run` lance un exécutable de développement qui n’apparaît pas toujours correctement dans les permissions TCC de macOS. Pour créer un bundle installable et sélectionnable dans **Accès complet au disque** :

```sh
chmod +x scripts/build-app.sh
./scripts/build-app.sh
```

Le résultat est créé dans `dist/StorageScope.app`. Vous pouvez ensuite utiliser `scripts/install-app.sh` ou glisser manuellement l’application dans `/Applications`.

Par défaut, le script compile uniquement pour l’architecture du Mac courant. Pour reproduire le bundle universel des releases GitHub :

```sh
STORAGESCOPE_ARCHITECTURES=universal ./scripts/build-app.sh
lipo -archs dist/StorageScope.app/Contents/MacOS/StorageScope
```

La dernière commande doit afficher `arm64 x86_64` (l’ordre peut varier). Le script refuse la release si une architecture manque et génère le dSYM correspondant dans `dist/StorageScope.app.dSYM`.

Le script d’installation local effectue également la copie, retire les attributs File Provider et vérifie la signature :

```sh
chmod +x scripts/install-app.sh
sudo ./scripts/install-app.sh
```

**Réglages Système → Confidentialité et sécurité → Accès complet au disque → + → Applications → StorageScope**

Activez StorageScope, quittez-la complètement avec `⌘Q`, puis relancez-la. Le bundle utilise l’identifiant stable `com.labrioche.StorageScope`. Par défaut il est signé localement de manière ad hoc ; après une reconstruction, macOS peut exceptionnellement demander de retirer puis d’ajouter de nouveau l’autorisation. Une identité Apple Development peut être utilisée avec `STORAGESCOPE_SIGNING_IDENTITY`.

Le toolchain Command Line Tools utilisé pendant le développement est une version Swift 6.4 préliminaire dont le moteur `swiftbuild` échoue à initialiser un manifeste. La validation locale a donc utilisé temporairement `--build-system native`; ce contournement n’est normalement pas nécessaire avec Xcode.

## Fonctions du MVP

- scan asynchrone et annulable, sans blocage de l’interface ;
- résultats progressifs publiés par lots ;
- barre de progression linéaire avec débit, durée, compteurs et estimation issue du scan précédent ;
- fichiers cachés inclus lorsque macOS autorise leur lecture ;
- liens symboliques jamais suivis et comptabilisés comme ignorés ;
- frontières de volume respectées (`/Volumes` et la vue APFS `/System/Volumes` ne sont pas parcourus lors du scan de `/`) ;
- tailles logique et allouée distinctes ;
- Top fichiers, Top dossiers et exploration par breadcrumb ;
- recherche par nom, extension ou chemin ;
- filtres de taille et catégories conservatrices ;
- sélection multiple native dans `Table` (`⌘`/`⇧`) ;
- affichage dans Finder, ouverture, copie du chemin et Quick Look ;
- déplacement vers la Corbeille avec confirmation et mise à jour des parents ;
- protection explicite de `/System`, `/bin`, `/sbin`, `/usr`, `/private` et de zones Apple sensibles ;
- signalement des refus d’accès, éléments ignorés et chemins concernés ;
- cache compact du dernier scan ;
- vue de l’écart entre espace utilisé par le volume et fichiers identifiés.
- suggestions conservatrices : anciens installateurs, DerivedData Xcode, caches d’outils, caches tiers volumineux, anciens `node_modules`, diagnostics et Corbeille ;

## Nouveautés 2.0

- explorateur depuis la racine en grille proportionnelle ou liste, avec fil d’Ariane et navigation dans tous les enfants d’un dossier ;
- index SQLite séparé par volume : tous les dossiers sont indexés, tandis que les fichiers sont lus seulement dans le dossier ouvert ;
- 14 catégories calculées sur l’ensemble des fichiers accessibles, avec héritage des bundles `.app`, photothèques et machines virtuelles ;
- grille de catégories cliquable, distincte des zones système, snapshots et données inaccessibles ;
- calcul animé et annulable du nettoyage conseillé ;
- recherche approfondie facultative des doublons par taille, échantillons puis SHA-256 ;
- inventaire des applications et désinstallation prudente par `CFBundleIdentifier` ;
- préflight inode/volume avant déplacement, résultats partiels et protection TOCTOU ;
- inventaire de la Corbeille et vidage définitif séparé exigeant une double confirmation et la saisie de `VIDER` ;
- séparation explicite entre espace disponible, espace récupérable dans la Corbeille et gain réellement mesuré ;
- cache et titre strictement liés au volume sélectionné.

## Comment les tailles sont calculées

Le chemin rapide du scanner demande à `URLResourceValues` :

- `fileSize` pour la **taille logique**, c’est-à-dire la longueur vue par une application ;
- `fileAllocatedSize` pour la **taille allouée**, c’est-à-dire les blocs actuellement attribués par le système de fichiers.

Les propriétés `totalFileSize` et `totalFileAllocatedSize` ne sont volontairement jamais demandées pendant l’énumération des dossiers : certains fournisseurs peuvent alors recalculer récursivement leur contenu, ce qui transforme un scan unique en milliers de sous-scans. Les totaux de dossiers sont calculés par notre propre agrégateur.

Le classement principal utilise `allocatedSize`. Un fichier sparse logique de 100 Go dont seulement 5 Go ont des blocs alloués est donc classé autour de 5 Go, tout en affichant 100 Go dans la colonne logique. Quand macOS ne fournit pas la taille allouée, le scanner retombe prudemment sur la taille logique.

Les tailles de dossiers ne viennent pas d’une catégorie macOS : `DirectoryAggregator` additionne chaque fichier dans son parent direct, puis effectue une réduction bottom-up unique à la fin. Cette architecture est en O(fichiers + dossiers), au lieu de remonter tous les ancêtres après chaque fichier. Les dossiers imbriqués peuvent chacun afficher leur total, mais l’application ne les additionne pas entre eux pour estimer l’espace global.

## Performance et progression

La progression légère est séparée des résultats :

- heartbeat toutes les ~150 ms, sans reconstruction de l’arbre ;
- résumé vivant borné des catégories et des enfants de la racine environ une fois par seconde ;
- aucune reconstruction complète des dossiers dans la boucle de parcours, y compris lors d’une annulation ;
- index de navigation complet construit une seule fois pendant la phase « Finalisation » ;
- heaps bornés en O(log n) pour les plus gros fichiers et enfants ;
- aucune création de `Set` de métadonnées dans la boucle ;
- tâche explicitement lancée en priorité `userInitiated`.

Un pourcentage exact exigerait de parcourir le disque une première fois uniquement pour compter les éléments, doublant le coût. La première analyse affiche donc une vraie barre d’activité indéterminée. À partir de la seconde analyse du même volume, l’application affiche une estimation fondée sur le nombre d’éléments du scan précédent, plafonnée à 99 % jusqu’à la fin et explicitement présentée comme une estimation.

Le benchmark inclus crée 5 000 fichiers temporaires. Lors de la dernière validation, il atteint environ **7 500 fichiers/s**. Le débit réel varie selon les permissions, iCloud/File Provider, la latence du disque et la structure des dossiers.

## Suggestions de nettoyage

`CleanupAnalyzer` observe le flux complet en une passe ; il ne travaille pas seulement sur le Top 2 000. Les règles v1 sont des allowlists explicites et aucune donnée personnelle arbitraire n’est qualifiée d’inutile.

- DMG, PKG et ISO de plus de 30 jours dans `~/Downloads` ;
- enfants DerivedData Xcode anciens et volumineux ;
- caches npm, pnpm, pip, Homebrew, Yarn, Gradle, CocoaPods et SwiftPM reconnus ;
- caches d’applications tierces volumineux, en inspection uniquement ;
- anciens dossiers `node_modules`, en inspection uniquement ;
- anciens rapports `.ips`, `.crash` et `.hang` ;
- anciennes archives et données d’appareils Xcode, gros téléchargements anciens et sauvegardes iOS, en inspection uniquement ;
- taille de la Corbeille, sans action irréversible.

Mail, Messages, Safari, Photos, Containers, Application Support, documents, bureaux, images, sauvegardes, VMs et applications ne sont jamais des candidats automatiques. Les suggestions n’ont pas de bouton « Tout nettoyer » : elles expliquent le risque et permettent d’examiner chaque élément dans Finder ou dans l’explorateur de stockage.

APFS ajoute des nuances impossibles à résoudre par une simple énumération : clones, compression, snapshots, purgeable et partage de blocs. Une taille allouée n’est donc pas nécessairement une mesure de blocs *uniques*. L’interface sépare volontairement :

- **espace utilisé par le volume** ;
- **fichiers identifiés par le scan** ;
- **non attribué / système / snapshots / inaccessible**.

## Permissions et Accès complet au disque

macOS protège notamment certaines données de Mail, Messages, Safari, Photos, sauvegardes mobiles, conteneurs et bibliothèques. Le scanner continue lorsqu’un accès échoue et ne prétend jamais avoir analysé 100 % du disque.

Pour améliorer la couverture :

1. ouvrir **Réglages Système > Confidentialité et sécurité > Accès complet au disque** ;
2. ajouter et activer StorageScope (ou Xcode/Terminal pendant le développement) ;
3. quitter puis relancer l’application ;
4. relancer l’analyse.

Le bouton **Accès complet au disque** tente d’ouvrir directement cette section. macOS peut néanmoins ouvrir la page Confidentialité générale selon sa version.

Même avec cet accès, SIP, le volume système scellé et d’autres protections du système restent en vigueur. StorageScope ne les contourne jamais.

## Choix de sandboxing

Le MVP est destiné à une distribution directe et n’active pas l’App Sandbox. Un binaire sandboxé ne peut pas parcourir arbitrairement `/` : il serait limité aux emplacements choisis par l’utilisateur via des security-scoped bookmarks, ce qui contredit l’objectif d’analyse globale.

Ce choix ne donne aucun privilège administrateur : TCC, Full Disk Access, permissions Unix, SIP et le volume système en lecture seule continuent de s’appliquer. L’application ne demande pas de mot de passe, n’exécute pas de shell, ne contacte aucun serveur et utilise uniquement les API Foundation/AppKit.

Pour une distribution Mac App Store, il faudrait concevoir un mode sandbox séparé fondé sur des dossiers explicitement sélectionnés, avec une couverture nécessairement réduite.

## Sécurité de suppression

- Aucune suppression automatique ou définitive.
- Toute action passe par `FileManager.trashItem`.
- Une confirmation indique le nombre d’éléments et l’espace potentiellement récupérable après vidage de la Corbeille.
- Les chemins système critiques sont non sélectionnables pour la suppression.
- Les tailles des parents et les listes sont recalculées immédiatement après succès.
- SIP et la partition système ne sont jamais modifiés.

Les badges sont des indications conservatrices, pas une promesse qu’un fichier est inutile. Un document personnel reste marqué comme personnel, et un cache est seulement « sûr à examiner ».

## Architecture

```text
Sources/
├── StorageCore/
│   ├── FileSystemItem.swift       modèles et progression
│   ├── StorageScanner.swift       énumération asynchrone et batching
│   ├── DirectoryAggregator.swift  agrégation bottom-up
│   ├── DirectoryIndexStore.swift  index SQLite distinct par volume
│   ├── DirectoryBrowserService.swift navigation exhaustive à la demande
│   ├── CategoryAccumulator.swift  catégories exactes sur le flux complet
│   ├── TopItemHeap.swift          tops bornés en O(log n)
│   ├── CleanupAnalyzer.swift      suggestions en une passe
│   ├── DuplicateAnalysisService.swift doublons taille/échantillon/SHA-256
│   ├── ApplicationUninstall.swift désinstallation par identifiant de bundle
│   ├── SelectionNormalizer.swift  anti-double-comptage parent/enfant
│   ├── FileTypeClassifier.swift   catégories et niveaux de sécurité
│   ├── StorageService.swift       volumes montés
│   ├── TrashService.swift         préflight, Corbeille et vidage confirmé
│   └── ScanCache.swift            cache JSON compact
└── StorageScope/
    ├── StorageScopeApp.swift
    ├── AppModel.swift             état UI isolé sur MainActor
    ├── ContentView.swift
    ├── ExplorerView.swift
    ├── CategoriesView.swift
    ├── CleanupView.swift
    ├── ApplicationsView.swift
    ├── EmptyTrashView.swift
    └── PermissionView.swift
Tests/StorageCoreTests/main.swift   validations autonomes
```

Le scanner tourne dans une tâche `userInitiated`, respecte `Task` cancellation et communique par `AsyncStream`. Les événements légers de progression sont isolés dans `ScanStatus`, afin de ne pas invalider la Table SwiftUI. L’état applicatif ne change que depuis `AppModel`, isolé sur `MainActor`. Le flux conserve au plus cinq événements récents.

Pour contenir la mémoire, seuls les 2 000 plus gros fichiers sont publiés dans la vue globale. Tous les résumés de dossiers sont écrits en une transaction dans un index SQLite par volume. L’explorateur énumère ensuite les enfants directs par lots, sans limite silencieuse de 250, et fusionne les tailles indexées des sous-dossiers. Le cache de résultats reste une photographie potentiellement périmée et chaque action destructive revalide l’identité réelle du fichier.

## Validation effectuée

La cible `StorageCoreTests` crée des dossiers temporaires et vérifie :

- l’agrégation logique/allouée dans plusieurs parents ;
- le classement et la limite d’enfants ;
- la classification et la protection système ;
- la découverte de fichiers normaux et cachés ;
- le non-suivi d’un symlink en boucle ;
- l’aller-retour du cache JSON ;
- l’isolation de deux caches par identifiant de volume ;
- la normalisation des sélections parent/enfant ;
- les règles de nettoyage et leurs zones interdites ;
- l’invariant exact des catégories et leur ordre de priorité ;
- une navigation SQLite exhaustive dans un dossier de plus de 250 enfants ;
- le treemap proportionnel, déterministe, sans chevauchement, y compris avec des tailles nulles ;
- le préflight d’identité avant Corbeille ;
- les identifiants Darwin `st_dev` à bit haut et un scan de régression sur `/dev` ;
- les protections du dossier personnel et la validation stricte des identifiants de bundle ;
- les doublons confirmés par SHA-256 ;
- un seuil minimal de débit sur 5 000 fichiers temporaires.

La compilation Swift 6 stricte et les vingt-quatre validations passent localement.

## Licence

Aucune licence open source n’est accordée pour le moment. Sauf mention contraire, le code et les ressources de ce dépôt restent protégés par le droit d’auteur et tous les droits sont réservés à `laBrioche97`.

## Limites connues du MVP

- La première progression est volontairement indéterminée ; les suivantes sont des estimations basées sur le dernier scan.
- Les anciennes analyses sont indicatives et ne remplacent jamais une nouvelle analyse.
- Le cache compact ne garantit pas un drill-down complet hors ligne dans tous les petits dossiers.
- Les catégories sont heuristiques ; le scan de fichiers reste la source de vérité.
- La mesure APFS ne peut pas attribuer exactement les snapshots ou les blocs clonés à un fichier unique.
- Un volume réseau, externe ou Time Machine n’est analysé que si l’utilisateur le choisit explicitement.
