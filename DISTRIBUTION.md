# Distribution de StorageScope 3.6

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

`-Development` construit un paquet de test sans manifeste signé. Depuis la version 3.2, `-KeySigned` construit une distribution Windows avec manifeste RSA-PSS signé et vérification d’intégrité, même en l’absence de certificat Authenticode. La clé publique doit être préalablement commitée et correspondre au secret de publication. Ne jamais annoncer ces paquets comme exempts de SmartScreen ou Gatekeeper.

Pour la distribution de test Windows et Mac, le workflow **Publish validated desktop installers and authenticated updates** (`release-windows-key.yml`) exige un tag et l’identifiant d’une CI réussie pour le même commit. Cette CI construit un paquet macOS arm64 puis installe et teste ce paquet sur macOS 14, 26 et 27 Apple Silicon. Le paquet validé est réutilisé à l’identique lors de la publication. La release brouillon n’est rendue publique qu’avec les deux installateurs, leurs empreintes et les métadonnées de mise à jour.

Le mode Mac `development` de `scripts/build-macos-release.sh` est explicite : application signée ad hoc, paquet `StorageScope-macOS-arm64-DEVELOPMENT.pkg` sans Developer ID ni notarisation. Le mode `production` reste distinct et échoue si les certificats ou la notarisation manquent. Aucun contournement de Gatekeeper ni suppression de quarantaine du téléchargement n’est requis.

L’archive Apple Silicon et le flux Sparkle sont signés Ed25519 dans les deux modes. `SURequireSignedFeed` et `SUVerifyUpdateBeforeExtraction` sont activés. La clé publique est versionnée dans `Packaging/sparkle-public-key.txt`, le secret privé reste dans GitHub Actions. Une signature ad hoc peut nécessiter une réautorisation TCC après mise à jour ; elle n’identifie pas l’éditeur auprès d’Apple.

Les hôtes Intel virtualisés ont un pilote Metal sans architecture cible. `METAL_ERROR_MODE=5` est limité à ces jobs de test pour journaliser les avertissements et permettre la compilation des shaders de secours ; cette variable n’est jamais intégrée à l’application. Les captures et les démarrages du paquet restent obligatoires. Ces tests ne certifient pas 60 images/s sur un Mac physique ni tous les parcours VoiceOver.

## Configurer les signatures avant la première publication

Une distribution sans clé ni manifeste doit annoncer les mises à jour manuelles. Une distribution `-KeySigned` annonce ses mises à jour vérifiées et l’absence de certificat Windows. Après activation des certificats Windows et Apple, activer `STORAGESCOPE_SIGNED_RELEASES_ENABLED=true` pour publier les deux plateformes via `release.yml`. Le workflow complet exige toujours les identités de signature et la notarisation.

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

Le workflow de production peut également utiliser la **variable** GitHub Actions `SPARKLE_PUBLIC_KEY` ; elle doit correspondre à la clé publique versionnée. Générer les clés dans un environnement de confiance et sauvegarder leurs originaux de manière sécurisée. Les outils de génération des clés ne sont jamais lancés implicitement par la publication.

Le script Windows vérifie que la clé privée correspond au PEM public commité et embarqué. Un build Authenticode embarque aussi le sujet exact de son certificat ; après activation de cette identité, le client refuse une rétrogradation vers un paquet non signé. La clé privée reste dans les secrets GitHub Actions. Un changement de clé nécessite une transition via une version encore approuvée ou une réinstallation manuelle.

Le bundle macOS embarque `SUPublicEDKey`. Sparkle vérifie la signature EdDSA avant extraction ; les applications du mode production sont signées Developer ID et notariées ; le mode développement conserve la mention de test. Les téléchargements automatiques sans consentement sont désactivés. Un redémarrage demandé par une mise à jour est reporté pendant une opération locale.

La signature Authenticode ne garantit pas l’absence immédiate de SmartScreen : la réputation de l’éditeur et des fichiers reste évaluée par Windows. Aucun contournement de SmartScreen, de Gatekeeper ou de la quarantaine n’est ajouté.

## Publier une version complète

1. Mettre à jour la version du projet Windows, son manifeste, `Packaging/Info.plist` et `RELEASE_NOTES.md`. Incrémenter également `CFBundleVersion`.
2. Exécuter les tests Windows et macOS. Vérifier les parcours avec de vraies bibliothèques de jeux de test ; ne pas utiliser les données personnelles comme fixtures.
3. Créer puis pousser un tag stable `vX.Y.Z` correspondant aux versions. Le workflow `release.yml` construit les deux plateformes et refuse de continuer si une signature ou la notarisation manque.
4. Le job final attend les deux plateformes, vérifie les fichiers et empreintes, charge tout dans une release brouillon puis rend la release publique. Une version publique existante n’est jamais écrasée.

Fichiers publiés :

- `StorageScope-Windows-Setup.exe` et `.sha256` : x64 + ARM64 dans un installateur autonome ;
- `StorageScope-macOS-arm64.pkg` et `.sha256` : installation macOS ;
- `StorageScope-arm64.zip` et `.sha256` : archive macOS utilisée par Sparkle ;
- `windows-update.json` et `.sig` : manifeste signé RSA-PSS/SHA-256, avec version, taille, empreinte et lien immuable ;
- `appcast.xml` : flux Sparkle avec signature EdDSA de l’archive finale notariée.

Le site ne propose que les installateurs effectivement présents dans la dernière release stable. Tant que les nouveaux installateurs ne sont pas publiés, il n’invente pas de liens vers les anciennes archives ZIP.

## Garanties et vérifications avant livraison

- Windows télécharge après acceptation et vérifie le manifeste signé, la version, la taille et le SHA-256 ; Authenticode et l’identité d’éditeur sont obligatoires dès leur activation. Un paquet invalide est refusé.
- L’installateur Windows vérifie hors ligne l’interface avant de déclarer la version active. Un échec conserve la précédente, restaure son raccourci et renvoie un code d’échec. Après réussite, les anciennes versions gérées sont supprimées. Liens/jonctions et dossiers non reconnus ne sont jamais suivis pendant ce nettoyage.
- Sparkle gère le remplacement de l’application macOS. La première migration depuis une version ancienne sans updater exige une installation manuelle.
- Tester la première installation et une mise à jour sur Windows x64/ARM64 et Mac Intel/Apple Silicon ; tester aussi annulation, réseau interrompu, signature invalide et maintien de la version précédente.
- La CI Windows vérifie les frontières de suppression, substitutions de fichiers, liens physiques, doublons, annulation, échecs partiels, signatures et rendus WPF. Les captures utilisent des données de test, pas une désinstallation réelle.
- Les contrôles d’interface sur des machines Windows et macOS réelles restent nécessaires avant publication publique ; les tests de rendu ne certifient pas à eux seuls tous les réglages d’accessibilité.
