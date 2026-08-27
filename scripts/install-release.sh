#!/bin/zsh
set -euo pipefail

REPOSITORY=${STORAGESCOPE_GITHUB_REPOSITORY:-laBrioche97/StorageScope}
REQUESTED_VERSION=${1:-latest}
ASSET_NAME="StorageScope-universal.zip"
CHECKSUM_NAME="StorageScope-universal.zip.sha256"
TARGET_APPLICATION="/Applications/StorageScope.app"
EXPECTED_BUNDLE_IDENTIFIER="com.labrioche.StorageScope"
LAUNCH_SERVICES_REGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
    echo "Erreur : cet installeur fonctionne uniquement sous macOS." >&2
    exit 1
fi

MACOS_MAJOR_VERSION=$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)
if (( MACOS_MAJOR_VERSION < 14 )); then
    echo "Erreur : StorageScope nécessite macOS 14 ou ultérieur." >&2
    exit 1
fi

if [[ "$REQUESTED_VERSION" == "latest" ]]; then
    RELEASE_PATH="latest/download"
    EXPECTED_VERSION=""
else
    if [[ ! "$REQUESTED_VERSION" =~ '^v?[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$' ]]; then
        echo "Erreur : version invalide. Exemple : 2.0.1, v2.0.1 ou latest." >&2
        exit 1
    fi
    EXPECTED_VERSION=${REQUESTED_VERSION#v}
    RELEASE_PATH="download/v$EXPECTED_VERSION"
fi

DOWNLOAD_ROOT="https://github.com/$REPOSITORY/releases/$RELEASE_PATH"
TEMPORARY_DIRECTORY=$(/usr/bin/mktemp -d "/tmp/StorageScope-install.XXXXXX")
BACKUP_DIRECTORY=""

cleanup_install() {
    /bin/rm -rf "$TEMPORARY_DIRECTORY"
}
trap cleanup_install EXIT

echo "Téléchargement de StorageScope depuis $REPOSITORY…"
/usr/bin/curl \
    --fail \
    --location \
    --proto '=https' \
    --retry 3 \
    --silent \
    --show-error \
    --output "$TEMPORARY_DIRECTORY/$ASSET_NAME" \
    "$DOWNLOAD_ROOT/$ASSET_NAME"
/usr/bin/curl \
    --fail \
    --location \
    --proto '=https' \
    --retry 3 \
    --silent \
    --show-error \
    --output "$TEMPORARY_DIRECTORY/$CHECKSUM_NAME" \
    "$DOWNLOAD_ROOT/$CHECKSUM_NAME"

EXPECTED_HASH=$(/usr/bin/awk -v asset="$ASSET_NAME" '$2 == asset { print $1; exit }' "$TEMPORARY_DIRECTORY/$CHECKSUM_NAME")
if [[ ! "$EXPECTED_HASH" =~ '^[0-9A-Fa-f]{64}$' ]]; then
    echo "Erreur : somme SHA-256 publiée absente ou invalide." >&2
    exit 1
fi
ACTUAL_HASH=$(/usr/bin/shasum -a 256 "$TEMPORARY_DIRECTORY/$ASSET_NAME" | /usr/bin/awk '{ print $1 }')
if [[ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]]; then
    echo "Erreur : l’archive téléchargée ne correspond pas à la somme SHA-256 publiée." >&2
    exit 1
fi

/usr/bin/ditto -x -k "$TEMPORARY_DIRECTORY/$ASSET_NAME" "$TEMPORARY_DIRECTORY/extracted"
SOURCE_APPLICATION="$TEMPORARY_DIRECTORY/extracted/StorageScope.app"
SOURCE_BINARY="$SOURCE_APPLICATION/Contents/MacOS/StorageScope"
if [[ ! -x "$SOURCE_BINARY" ]]; then
    echo "Erreur : l’archive ne contient pas un bundle StorageScope valide." >&2
    exit 1
fi

BUNDLE_IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APPLICATION/Contents/Info.plist")
BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APPLICATION/Contents/Info.plist")
if [[ "$BUNDLE_IDENTIFIER" != "$EXPECTED_BUNDLE_IDENTIFIER" ]]; then
    echo "Erreur : identifiant de bundle inattendu : $BUNDLE_IDENTIFIER" >&2
    exit 1
fi
if [[ -n "$EXPECTED_VERSION" && "$BUNDLE_VERSION" != "$EXPECTED_VERSION" ]]; then
    echo "Erreur : la release demandée ($EXPECTED_VERSION) contient la version $BUNDLE_VERSION." >&2
    exit 1
fi

ARCHITECTURES=$(/usr/bin/lipo -archs "$SOURCE_BINARY")
if [[ " $ARCHITECTURES " != *" arm64 "* || " $ARCHITECTURES " != *" x86_64 "* ]]; then
    echo "Erreur : la release n’est pas universelle ($ARCHITECTURES)." >&2
    exit 1
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$SOURCE_APPLICATION"

if /usr/bin/pgrep -x StorageScope >/dev/null 2>&1; then
    echo "Erreur : quittez complètement StorageScope avec ⌘Q, puis relancez cet installeur." >&2
    exit 1
fi

typeset -a PRIVILEGE
if [[ -w "/Applications" ]]; then
    PRIVILEGE=()
else
    PRIVILEGE=(/usr/bin/sudo)
fi

if [[ -e "$TARGET_APPLICATION" ]]; then
    BACKUP_DIRECTORY=$(/usr/bin/mktemp -d "/tmp/StorageScope-previous.XXXXXX")
    "${PRIVILEGE[@]}" /bin/mv "$TARGET_APPLICATION" "$BACKUP_DIRECTORY/StorageScope.app"
fi

if ! "${PRIVILEGE[@]}" /usr/bin/ditto --norsrc "$SOURCE_APPLICATION" "$TARGET_APPLICATION"; then
    echo "Erreur : l’installation a échoué." >&2
    if [[ -n "$BACKUP_DIRECTORY" && -d "$BACKUP_DIRECTORY/StorageScope.app" ]]; then
        "${PRIVILEGE[@]}" /bin/mv "$BACKUP_DIRECTORY/StorageScope.app" "$TARGET_APPLICATION"
        echo "La version précédente a été restaurée." >&2
    fi
    exit 1
fi

"${PRIVILEGE[@]}" /usr/bin/codesign --verify --deep --strict --verbose=2 "$TARGET_APPLICATION"
"$LAUNCH_SERVICES_REGISTER" -f "$TARGET_APPLICATION"

if /usr/sbin/spctl --assess --type execute "$TARGET_APPLICATION" >/dev/null 2>&1; then
    GATEKEEPER_APPROVED=true
else
    GATEKEEPER_APPROVED=false
    if ! "${PRIVILEGE[@]}" /usr/bin/xattr -p com.apple.quarantine "$TARGET_APPLICATION" >/dev/null 2>&1; then
        QUARANTINE_TIMESTAMP=$(/usr/bin/printf '%x' "$(/bin/date +%s)")
        "${PRIVILEGE[@]}" /usr/bin/xattr -w \
            com.apple.quarantine \
            "0081;$QUARANTINE_TIMESTAMP;StorageScope;" \
            "$TARGET_APPLICATION"
    fi
fi

echo "StorageScope $BUNDLE_VERSION est installée dans /Applications ($ARCHITECTURES)."
if [[ -n "$BACKUP_DIRECTORY" ]]; then
    echo "La version précédente est sauvegardée temporairement dans $BACKUP_DIRECTORY."
fi
if [[ "$GATEKEEPER_APPROVED" == true ]]; then
    echo "La signature et la notarisation sont acceptées par Gatekeeper."
else
    echo "Cette release n’est pas approuvée par Gatekeeper. Dans Finder, faites un clic droit sur StorageScope puis choisissez Ouvrir pour prendre une décision explicite."
fi
echo "Autorisez ensuite StorageScope dans Accès complet au disque si macOS le demande."
