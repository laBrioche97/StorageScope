# Distribution de StorageScope sur GitHub

Ce dépôt est prévu pour être publié sous le nom `laBrioche97/StorageScope`. Deux workflows GitHub Actions assurent la distribution :

- `.github/workflows/ci.yml` compile le projet en Swift strict et exécute les validations à chaque push sur `main` et chaque pull request ;
- `.github/workflows/release.yml` répond à un tag `vX.Y.Z`, vérifie que le tag correspond au `CFBundleShortVersionString`, construit un bundle universel `arm64` + `x86_64`, exécute les tests, vérifie la signature et publie l’application, sa somme SHA-256 et son dSYM.

## Publier une nouvelle version

1. Mettre à jour les deux valeurs de `Packaging/Info.plist` :
   - `CFBundleShortVersionString` pour la version publique, par exemple `2.1.0` ;
   - `CFBundleVersion` pour un numéro de build entier strictement croissant.
2. Compiler et tester localement :

   ```sh
   swift build --disable-sandbox -Xswiftc -warnings-as-errors
   swift run StorageCoreTests
   STORAGESCOPE_ARCHITECTURES=universal ./scripts/build-app.sh
   lipo -archs dist/StorageScope.app/Contents/MacOS/StorageScope
   ```

3. Commiter la version, créer un tag annoté qui correspond exactement à la version du plist, puis pousser les deux :

   ```sh
   git add Packaging/Info.plist
   git commit -m "Release 2.1.0"
   git tag -a v2.1.0 -m "StorageScope 2.1.0"
   git push origin main
   git push origin v2.1.0
   ```

Le push du tag crée ou met à jour la release GitHub. Une exécution manuelle du workflow est également possible pour republier un **tag existant**. Le workflow ne fabrique jamais silencieusement un tag.

Les assets ont volontairement un nom stable afin que l’installeur fonctionne pour `latest` comme pour une version précise :

- `StorageScope-universal.zip` ;
- `StorageScope-universal.zip.sha256` ;
- `StorageScope-dSYM.zip` pour symboliquer les rapports de crash.

GitHub fournit en complément les archives du code source de chaque tag.

## Signature et notarisation

Le workflow fonctionne sans aucun secret : il produit alors une signature ad hoc. Cette variante est installable avec `scripts/install-release.sh`, mais un téléchargement manuel peut déclencher l’avertissement Gatekeeper et l’Accès complet au disque peut devoir être réaccordé après une mise à jour.

Pour une distribution normale sur plusieurs Mac et une identité TCC stable, configurez un certificat **Developer ID Application** et la notarisation Apple. Ajoutez ces secrets dans **Settings → Secrets and variables → Actions** du dépôt GitHub :

| Secret | Contenu |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | Certificat Developer ID Application exporté en `.p12`, encodé en base64 |
| `MACOS_CERTIFICATE_PASSWORD` | Mot de passe du fichier `.p12` |
| `APPLE_API_KEY_P8_BASE64` | Clé App Store Connect `.p8`, encodée en base64 |
| `APPLE_API_KEY_ID` | Identifiant de la clé App Store Connect |
| `APPLE_API_ISSUER_ID` | Issuer ID App Store Connect |

Exemple local pour encoder les deux fichiers sans retour à la ligne :

```sh
base64 -i DeveloperIDApplication.p12 | tr -d '\n'
base64 -i AuthKey_ABC123.p8 | tr -d '\n'
```

Ne commitez jamais le certificat, la clé `.p8`, leurs mots de passe ou leurs valeurs base64. Le workflow importe le certificat dans un trousseau temporaire, signe avec le hardened runtime et un horodatage Apple, soumet l’archive à `notarytool`, agrafe le ticket au bundle, puis supprime le trousseau temporaire même si une étape échoue.

La notarisation n’est tentée que lorsque **tous** les secrets nécessaires sont présents. Après publication, vérifiez ponctuellement une release signée sur un autre Mac :

```sh
codesign --verify --deep --strict --verbose=2 /Applications/StorageScope.app
spctl --assess --type execute --verbose=2 /Applications/StorageScope.app
```

## Installer ou revenir à une version

Dernière release :

```sh
curl -fsSLo StorageScope-install.zsh https://raw.githubusercontent.com/laBrioche97/StorageScope/main/scripts/install-release.sh
less StorageScope-install.zsh
/bin/zsh StorageScope-install.zsh latest
```

Version précise ou retour à une ancienne version :

```sh
/bin/zsh StorageScope-install.zsh 2.0.1
```

StorageScope doit être complètement quittée avant l’opération. L’ancienne application est déplacée dans un dossier temporaire `/tmp/StorageScope-previous.*` et son chemin exact est affiché. macOS nettoie généralement `/tmp` au redémarrage ; cette sauvegarde est donc un filet de sécurité immédiat, pas une archive durable.

Dans un fork, l’installeur peut viser un autre dépôt sans modifier le script :

```sh
STORAGESCOPE_GITHUB_REPOSITORY=proprietaire/depot ./scripts/install-release.sh latest
```

## Garanties du paquet universel

`scripts/build-app.sh` compile séparément les triples `arm64-apple-macosx14.0` et `x86_64-apple-macosx14.0`, les fusionne avec `lipo`, puis vérifie strictement que le binaire final contient exactement les architectures demandées. Il génère ensuite un dSYM universel et compare l’ensemble de ses UUID à ceux du binaire.

La compatibilité commence à macOS 14. Un bundle universel évite Rosetta sur Apple Silicon tout en restant directement exécutable sur les Mac Intel compatibles.
