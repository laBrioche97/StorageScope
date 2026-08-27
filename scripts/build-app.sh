#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
PROJECT_DIRECTORY=${SCRIPT_DIRECTORY:h}
OUTPUT_DIRECTORY="$PROJECT_DIRECTORY/dist"
APPLICATION_PATH="$OUTPUT_DIRECTORY/StorageScope.app"
DEBUG_SYMBOL_PATH="$OUTPUT_DIRECTORY/StorageScope.app.dSYM"
BUILD_SYSTEM=${STORAGESCOPE_BUILD_SYSTEM:-native}
SIGNING_IDENTITY=${STORAGESCOPE_SIGNING_IDENTITY:--}
MINIMUM_MACOS_VERSION=${STORAGESCOPE_MINIMUM_MACOS_VERSION:-14.0}
ARCHITECTURES_INPUT=${STORAGESCOPE_ARCHITECTURES:-$(/usr/bin/uname -m)}

if [[ "$ARCHITECTURES_INPUT" == "universal" ]]; then
    ARCHITECTURES_INPUT="arm64 x86_64"
fi

ARCHITECTURES=( ${(z)ARCHITECTURES_INPUT} )
if (( ${#ARCHITECTURES[@]} == 0 )); then
    echo "Erreur : STORAGESCOPE_ARCHITECTURES ne contient aucune architecture." >&2
    exit 1
fi

typeset -A SEEN_ARCHITECTURES
typeset -a NORMALIZED_ARCHITECTURES
for ARCHITECTURE in "${ARCHITECTURES[@]}"; do
    case "$ARCHITECTURE" in
        arm64|x86_64) ;;
        *)
            echo "Erreur : architecture non prise en charge : $ARCHITECTURE" >&2
            exit 1
            ;;
    esac
    if [[ -z ${SEEN_ARCHITECTURES[$ARCHITECTURE]:-} ]]; then
        SEEN_ARCHITECTURES[$ARCHITECTURE]=1
        NORMALIZED_ARCHITECTURES+=("$ARCHITECTURE")
    fi
done
ARCHITECTURES=("${NORMALIZED_ARCHITECTURES[@]}")

/bin/mkdir -p "$OUTPUT_DIRECTORY" "$PROJECT_DIRECTORY/.build-app"

TEMPORARY_BUILD_ROOT=$(/usr/bin/mktemp -d "/tmp/StorageScope-package.XXXXXX")
SOURCE_PACKAGE_DIRECTORY="$TEMPORARY_BUILD_ROOT/package"
SWIFTPM_BUILD_DIRECTORY="$TEMPORARY_BUILD_ROOT/swiftpm"
STAGING_DIRECTORY=""

cleanup_build() {
    if [[ -n "$STAGING_DIRECTORY" && -d "$STAGING_DIRECTORY" ]]; then
        /bin/rm -rf "$STAGING_DIRECTORY"
    fi
    /bin/rm -rf "$TEMPORARY_BUILD_ROOT"
}
trap cleanup_build EXIT

/bin/mkdir -p "$SOURCE_PACKAGE_DIRECTORY"
/bin/cp "$PROJECT_DIRECTORY/Package.swift" "$SOURCE_PACKAGE_DIRECTORY/Package.swift"
/usr/bin/ditto --norsrc --noextattr "$PROJECT_DIRECTORY/Sources" "$SOURCE_PACKAGE_DIRECTORY/Sources"
/usr/bin/ditto --norsrc --noextattr "$PROJECT_DIRECTORY/Tests" "$SOURCE_PACKAGE_DIRECTORY/Tests"

export CLANG_MODULE_CACHE_PATH="$TEMPORARY_BUILD_ROOT/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TEMPORARY_BUILD_ROOT/clang-module-cache"

typeset -a BINARY_PATHS
for ARCHITECTURE in "${ARCHITECTURES[@]}"; do
    ARCHITECTURE_BUILD_DIRECTORY="$SWIFTPM_BUILD_DIRECTORY/$ARCHITECTURE"
    TARGET_TRIPLE="${ARCHITECTURE}-apple-macosx${MINIMUM_MACOS_VERSION}"
    echo "Compilation release de StorageScope pour $ARCHITECTURE…"
    /usr/bin/env swift build \
        --package-path "$SOURCE_PACKAGE_DIRECTORY" \
        --disable-sandbox \
        --cache-path "$TEMPORARY_BUILD_ROOT/cache" \
        --config-path "$TEMPORARY_BUILD_ROOT/config" \
        --security-path "$TEMPORARY_BUILD_ROOT/security" \
        --manifest-cache none \
        --configuration release \
        --product StorageScope \
        --build-system "$BUILD_SYSTEM" \
        --scratch-path "$ARCHITECTURE_BUILD_DIRECTORY" \
        --triple "$TARGET_TRIPLE"

    BINARY_DIRECTORY=$(/usr/bin/env swift build \
        --package-path "$SOURCE_PACKAGE_DIRECTORY" \
        --disable-sandbox \
        --cache-path "$TEMPORARY_BUILD_ROOT/cache" \
        --config-path "$TEMPORARY_BUILD_ROOT/config" \
        --security-path "$TEMPORARY_BUILD_ROOT/security" \
        --manifest-cache none \
        --configuration release \
        --product StorageScope \
        --build-system "$BUILD_SYSTEM" \
        --scratch-path "$ARCHITECTURE_BUILD_DIRECTORY" \
        --triple "$TARGET_TRIPLE" \
        --show-bin-path)
    BINARY_PATH="$BINARY_DIRECTORY/StorageScope"
    if [[ ! -x "$BINARY_PATH" ]]; then
        echo "Erreur : binaire $ARCHITECTURE absent après compilation." >&2
        exit 1
    fi
    ACTUAL_ARCHITECTURES=$(/usr/bin/lipo -archs "$BINARY_PATH")
    if [[ " $ACTUAL_ARCHITECTURES " != *" $ARCHITECTURE "* ]]; then
        echo "Erreur : le binaire produit ne contient pas $ARCHITECTURE ($ACTUAL_ARCHITECTURES)." >&2
        exit 1
    fi
    BINARY_PATHS+=("$BINARY_PATH")
done

STAGING_DIRECTORY=$(/usr/bin/mktemp -d "$TEMPORARY_BUILD_ROOT/app.XXXXXX")
STAGING_APPLICATION="$STAGING_DIRECTORY/StorageScope.app"

/bin/mkdir -p "$STAGING_APPLICATION/Contents/MacOS" "$STAGING_APPLICATION/Contents/Resources"
if (( ${#BINARY_PATHS[@]} == 1 )); then
    /usr/bin/install -m 755 "${BINARY_PATHS[1]}" "$STAGING_APPLICATION/Contents/MacOS/StorageScope"
else
    /usr/bin/lipo -create "${BINARY_PATHS[@]}" -output "$STAGING_APPLICATION/Contents/MacOS/StorageScope"
    /bin/chmod 755 "$STAGING_APPLICATION/Contents/MacOS/StorageScope"
fi
/bin/cp "$PROJECT_DIRECTORY/Packaging/Info.plist" "$STAGING_APPLICATION/Contents/Info.plist"
/bin/cp "$PROJECT_DIRECTORY/Packaging/PrivacyInfo.xcprivacy" "$STAGING_APPLICATION/Contents/Resources/PrivacyInfo.xcprivacy"

FINAL_ARCHITECTURES=$(/usr/bin/lipo -archs "$STAGING_APPLICATION/Contents/MacOS/StorageScope")
for ARCHITECTURE in "${ARCHITECTURES[@]}"; do
    if [[ " $FINAL_ARCHITECTURES " != *" $ARCHITECTURE "* ]]; then
        echo "Erreur : le bundle final ne contient pas $ARCHITECTURE ($FINAL_ARCHITECTURES)." >&2
        exit 1
    fi
done
FINAL_ARCHITECTURE_LIST=( ${(z)FINAL_ARCHITECTURES} )
FINAL_ARCHITECTURE_COUNT=${#FINAL_ARCHITECTURE_LIST[@]}
if (( FINAL_ARCHITECTURE_COUNT != ${#ARCHITECTURES[@]} )); then
    echo "Erreur : architectures inattendues dans le bundle final : $FINAL_ARCHITECTURES" >&2
    exit 1
fi

/usr/bin/plutil -lint "$STAGING_APPLICATION/Contents/Info.plist"
/usr/bin/plutil -lint "$STAGING_APPLICATION/Contents/Resources/PrivacyInfo.xcprivacy"
/usr/bin/xattr -cr "$STAGING_APPLICATION"
typeset -a TIMESTAMP_ARGUMENTS
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    TIMESTAMP_ARGUMENTS=(--timestamp=none)
else
    TIMESTAMP_ARGUMENTS=(--timestamp)
fi
/usr/bin/codesign \
    --force \
    --options runtime \
    "${TIMESTAMP_ARGUMENTS[@]}" \
    --sign "$SIGNING_IDENTITY" \
    "$STAGING_APPLICATION"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGING_APPLICATION"

if [[ -e "$APPLICATION_PATH" ]]; then
    /bin/rm -rf "$APPLICATION_PATH"
fi
/usr/bin/ditto --norsrc --noextattr "$STAGING_APPLICATION" "$APPLICATION_PATH"
/usr/bin/xattr -cr "$APPLICATION_PATH"
/usr/bin/codesign \
    --force \
    --options runtime \
    "${TIMESTAMP_ARGUMENTS[@]}" \
    --sign "$SIGNING_IDENTITY" \
    "$APPLICATION_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APPLICATION_PATH"

if [[ -e "$DEBUG_SYMBOL_PATH" ]]; then
    /bin/rm -rf "$DEBUG_SYMBOL_PATH"
fi
/usr/bin/xcrun dsymutil "$APPLICATION_PATH/Contents/MacOS/StorageScope" -o "$DEBUG_SYMBOL_PATH"
BINARY_UUIDS=$(/usr/bin/dwarfdump --uuid "$APPLICATION_PATH/Contents/MacOS/StorageScope" | /usr/bin/awk '{ print $2 }' | /usr/bin/sort)
DSYM_UUIDS=$(/usr/bin/dwarfdump --uuid "$DEBUG_SYMBOL_PATH" | /usr/bin/awk '{ print $2 }' | /usr/bin/sort)
if [[ -z "$BINARY_UUIDS" || "$BINARY_UUIDS" != "$DSYM_UUIDS" ]]; then
    echo "Erreur : le dSYM ne correspond pas à toutes les architectures du binaire final." >&2
    exit 1
fi

echo "Application créée : $APPLICATION_PATH"
echo "Architectures : $FINAL_ARCHITECTURES"
echo "Symboles de diagnostic : $DEBUG_SYMBOL_PATH"
echo "Glissez-la dans /Applications, puis ajoutez StorageScope dans Accès complet au disque."
