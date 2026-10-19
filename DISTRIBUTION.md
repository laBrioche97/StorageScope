# Distribution signée de StorageScope 3

## Construire et vérifier

Windows utilise .NET 10 LTS, WPF et Inno Setup 7.1.0. macOS utilise Swift 6 / macOS 14+, SwiftUI et Sparkle 2.9.6. Tous les composants nécessaires à l’exécution sont embarqués ; seul l’outil de développement doit résoudre ses dépendances pendant la compilation.

```powershell
dotnet run --project Windows/StorageScope.Windows.Tests -c Release
./scripts/build-windows-release.ps1 -Tag v3.0.0 -Development
```

```sh
swift build --disable-sandbox -Xswiftc -warnings-as-errors
swift run --disable-sandbox StorageCoreTests
zsh scripts/build-app.sh
```

Les builds de développement ne sont pas signées pour une distribution publique. La recherche de mises à jour y reste désactivée sans clé publique et identité d’éditeur. Ne jamais les annoncer comme exemptes de SmartScreen ou Gatekeeper.

## Configurer les signatures avant la première publication

Une distribution de test non signée peut être publiée séparément sous le nom explicite `StorageScope-Windows-Setup-DEVELOPMENT.exe`. Elle doit annoncer SmartScreen et les mises à jour manuelles ; elle ne contient aucun manifeste de mise à jour signé. Après configuration et validation de tous les certificats, activer la variable GitHub Actions `STORAGESCOPE_SIGNED_RELEASES_ENABLED=true` pour publier automatiquement les tags signés. Le lancement manuel du workflow signé reste possible et exige toujours tous les secrets.

Configurer ces **secrets GitHub Actions**, sans les commiter :

| Secret | Usage |
|---|---|
| `WINDOWS_CERTIFICATE_P12_BASE64` | Certificat Authenticode approuvé, avec clé privée, au format PFX/P12 encodé en base64 |
| `WINDOWS_CERTIFICATE_PASSWORD` | Mot de passe du PFX |
| `WINDOWS_UPDATE_PRIVATE_KEY_PEM_BASE64` | Clé privée RSA de mise à jour, au moins 3072 bits, PEM encodé en base64 |
| `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD` | Identité Developer ID Application et mot de passe |
| `MACOS_INSTALLER_P12_BASE64`, `MACOS_INSTALLER_PASSWORD` | Identité Developer ID Installer et mot de passe |
| `APPLE_API_KEY_P8_BASE64`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID` | Accès à la notarisation Apple |
| `SPARKLE_PRIVATE_KEY` | Clé privée Ed25519 exportée par les outils Sparkle ; conserver son format base64 original |

Configurer également la **variable** GitHub Actions `SPARKLE_PUBLIC_KEY`, fournie par `generate_keys` de Sparkle. Générer les clés dans un environnement de confiance et sauvegarder leurs originaux de manière sécurisée. Les outils de génération des clés ne sont jamais lancés implicitement par la publication.

Le script Windows dérive la clé publique RSA depuis la clé privée et l’embarque dans l’exécutable ; il embarque aussi le sujet exact du certificat Authenticode comme identité attendue pour les futures mises à jour. Le fichier PEM public généré ne contient aucun secret. La même identité doit rester stable lors du renouvellement du certificat ; un changement d’identité ou de clé requiert une stratégie de transition via une version encore approuvée, ou une réinstallation manuelle.

Le bundle macOS embarque `SUPublicEDKey`. Sparkle vérifie la signature EdDSA avant extraction ; les applications sont signées Developer ID et notariées. Les téléchargements automatiques sans consentement sont désactivés. Un redémarrage demandé par une mise à jour est reporté pendant une opération locale.

La signature Authenticode ne garantit pas l’absence immédiate de SmartScreen : la réputation de l’éditeur et des fichiers reste évaluée par Windows. Aucun contournement de SmartScreen, de Gatekeeper ou de la quarantaine n’est ajouté.

## Publier une version complète

1. Mettre à jour la version du projet Windows, son manifeste, `Packaging/Info.plist` et `RELEASE_NOTES.md`. Incrémenter également `CFBundleVersion`.
2. Exécuter les tests Windows et macOS. Vérifier les parcours avec de vraies bibliothèques de jeux de test ; ne pas utiliser les données personnelles comme fixtures.
3. Créer puis pousser un tag stable `vX.Y.Z` correspondant aux versions. Le workflow `release.yml` construit les deux plateformes et refuse de continuer si une signature ou la notarisation manque.
4. Le job final attend les deux plateformes, vérifie les fichiers et empreintes, charge tout dans une release brouillon puis rend la release publique. Une version publique existante n’est jamais écrasée.

Fichiers publiés :

- `StorageScope-Windows-Setup.exe` et `.sha256` : x64 + ARM64 dans un installateur autonome ;
- `StorageScope-macOS-universal.pkg` et `.sha256` : installation macOS ;
- `StorageScope-universal.zip` et `.sha256` : archive macOS utilisée par Sparkle ;
- `windows-update.json` et `.sig` : manifeste signé RSA-PSS/SHA-256, avec version, taille, empreinte et lien immuable ;
- `appcast.xml` : flux Sparkle avec signature EdDSA de l’archive finale notariée.

Le site ne propose que les installateurs effectivement présents dans la dernière release stable. Tant que les nouveaux installateurs ne sont pas publiés, il n’invente pas de liens vers les anciennes archives ZIP.

## Garanties et vérifications avant livraison

- Windows télécharge le paquet uniquement après acceptation et vérifie le manifeste, la version, la taille, le SHA-256, Authenticode et l’identité d’éditeur avant exécution. Un paquet invalide est refusé.
- L’installateur Windows place chaque version dans son propre dossier. Il vérifie hors ligne le chargement de l’interface avant de déclarer la version active ; un échec rétablit le raccourci précédent. Les anciennes versions ne sont pas effacées automatiquement.
- Sparkle gère le remplacement de l’application macOS. La première migration depuis une version ancienne sans updater exige une installation manuelle.
- Tester la première installation et une mise à jour sur Windows x64/ARM64 et Mac Intel/Apple Silicon ; tester aussi annulation, réseau interrompu, signature invalide et maintien de la version précédente.
- La CI Windows vérifie les frontières de suppression, substitutions de fichiers, liens physiques, doublons, annulation, échecs partiels, signatures et rendus WPF. Les captures utilisent des données de test, pas une désinstallation réelle.
- Les contrôles d’interface sur des machines Windows et macOS réelles restent nécessaires avant publication publique ; les tests de rendu ne certifient pas à eux seuls tous les réglages d’accessibilité.
