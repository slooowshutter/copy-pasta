#!/bin/bash
# Make a CopyPasta release in dist/:
#   CopyPasta.dmg   the app (Apple silicon + Intel) and an Applications link, signed with
#                   Developer ID and notarized, the app and the disk image both stapled
#   appcast.xml     the Sparkle feed for it: version, download URL and EdDSA signature
#   release-notes.md  (if RELEASE_NOTES is set) the notes the update alert shows
# The release workflow (.github/workflows/release.yml) runs this on a pushed vX.Y.Z tag and
# uploads both to the GitHub release; it runs locally too. README › Releasing has the setup.
#
# Without a Developer ID certificate it still makes the DMG and appcast, ad-hoc signed and NOT
# notarized: fine for testing, but Gatekeeper blocks it on other Macs.
#
# Usage: scripts/release.sh [--require-notarization]
#   --require-notarization   fail unless the result is Developer ID signed and notarized (CI)
#
# Environment (all optional):
#   RELEASE_VERSION    X.Y.Z (default: the vX.Y.Z tag on HEAD; untagged, Info.plist's, as a test)
#   DEVELOPER_ID       signing identity, name or SHA-1 (default: the keychain's Developer ID
#                      Application certificate, if there's exactly one)
#   Notarization, either an App Store Connect API key:
#     NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID   the .p8 file, its key ID, the issuer ID
#   or NOTARY_KEYCHAIN_PROFILE, a profile saved by `xcrun notarytool store-credentials`.
#   The Sparkle private key that signs updates (default: the login keychain, where
#   Sparkle's generate_keys keeps it):
#     SPARKLE_KEY_FILE     a file holding it (`generate_keys -x <file>` exports one)
#     SPARKLE_PRIVATE_KEY  the key itself (CI secret)
#   SPARKLE_PUBLIC_KEY   build this SUPublicEDKey in instead of Info.plist's (testing with a
#                        throwaway key)
#   RELEASE_NOTES        a Markdown file for the update alert
#   GITHUB_REPOSITORY    owner/name, for the download URLs (default slooowshutter/copy-pasta)
set -euo pipefail
cd "$(dirname "$0")/.."

REQUIRE_NOTARIZATION=0
for arg in "$@"; do
    case "$arg" in
        --require-notarization) REQUIRE_NOTARIZATION=1 ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown argument $arg (see --help)" >&2; exit 1 ;;
    esac
done

REPO="${GITHUB_REPOSITORY:-slooowshutter/copy-pasta}"
APP="dist/CopyPasta.app"
DMG="dist/CopyPasta.dmg"
APPCAST="dist/appcast.xml"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
# A requirement CI must meet; locally a warning, and the result isn't for shipping.
must() { if [[ $REQUIRE_NOTARIZATION == 1 ]]; then die "$*"; else warn "$*"; fi; }

# --- Version -----------------------------------------------------------------------------------
# CFBundleShortVersionString from the tag, CFBundleVersion (what Sparkle compares) from the
# commit count, which only goes up as long as releases are tagged on one branch (main).
step "Version"
if [[ -z "${RELEASE_VERSION:-}" ]]; then
    TAG="$(git describe --tags --exact-match --match 'v[0-9]*' HEAD 2>/dev/null || true)"
    RELEASE_VERSION="${TAG#v}"
fi
if [[ -z "$RELEASE_VERSION" ]]; then
    RELEASE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
    must "HEAD has no vX.Y.Z tag: a test build, versioned $RELEASE_VERSION from Info.plist"
fi
[[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] \
    || die "version '$RELEASE_VERSION' isn't X.Y.Z (or X.Y.Z-beta.1)"
[[ "$(git rev-parse --is-shallow-repository)" == false ]] \
    || die "shallow clone: the build number is the commit count, so fetch the full history (fetch-depth: 0)"
BUILD="$(git rev-list --count HEAD)"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || must "uncommitted changes: they're in this build but not in git"
echo "CopyPasta $RELEASE_VERSION (build $BUILD)"

# --- Signing identity and notarization credentials ---------------------------------------------
step "Signing"
if [[ -z "${DEVELOPER_ID:-}" ]]; then
    # Listing identities doesn't touch private keys, so it never prompts.
    IDS="$(security find-identity -v -p codesigning | grep '"Developer ID Application: ' || true)"
    if [[ "$(grep -c . <<<"$IDS")" -gt 1 ]]; then
        die "several Developer ID Application certificates: pick one with DEVELOPER_ID"$'\n'"$IDS"
    fi
    DEVELOPER_ID="$(awk '{print $2}' <<<"$IDS")"
fi
NOTARY=()
if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    [[ -f "$NOTARY_KEY_PATH" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]] \
        || die "NOTARY_KEY_PATH needs NOTARY_KEY_ID and NOTARY_ISSUER_ID, and the .p8 file to exist"
    NOTARY=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
elif [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    NOTARY=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
fi
if [[ -n "$DEVELOPER_ID" ]]; then
    echo "Developer ID: $DEVELOPER_ID"
    [[ ${#NOTARY[@]} -gt 0 ]] || must "no notarization credentials (NOTARY_KEY_PATH… or NOTARY_KEYCHAIN_PROFILE): it won't be notarized"
else
    must "no Developer ID Application certificate: ad-hoc signed, NOT notarized"
fi

# --- Sparkle keys ------------------------------------------------------------------------------
# The app only installs updates signed with the private key matching its SUPublicEDKey. Check
# they match now rather than ship an update nobody can install (or a key nobody can use).
step "Sparkle key"
xcrun swiftc -O scripts/sparkle_key.swift -o "$WORK/sparkle_key"
PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Info.plist)}"
SPARKLE_READY=1
if [[ "$(base64 -d <<<"$PUBLIC_KEY" 2>/dev/null | wc -c | tr -d ' ')" != 32 ]]; then
    SPARKLE_READY=0
    must "no Sparkle public key (Info.plist's SUPublicEDKey is '$PUBLIC_KEY'): no appcast, and this build won't update itself. README › Releasing sets it up"
fi
KEY_ARGS=()
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    KEY_ARGS=(--ed-key-file -) # read from stdin, so the key never lands on disk
    private_key() { printf '%s' "$SPARKLE_PRIVATE_KEY"; }
elif [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
    KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
    private_key() { cat "$SPARKLE_KEY_FILE"; }
fi
if [[ $SPARKLE_READY == 0 ]]; then
    :
elif [[ ${#KEY_ARGS[@]} -gt 0 ]]; then
    [[ "$(private_key | "$WORK/sparkle_key" public)" == "$PUBLIC_KEY" ]] \
        || die "the Sparkle private key doesn't match the app's public key ($PUBLIC_KEY)"
    echo "Private key matches SUPublicEDKey $PUBLIC_KEY"
else
    echo "Private key: from the login keychain (macOS may ask to allow generate_appcast)"
fi

# --- Build and sign ----------------------------------------------------------------------------
step "Build"
HARDENED=""
[[ -n "$DEVELOPER_ID" ]] && HARDENED=1
COPYPASTA_VERSION="$RELEASE_VERSION" COPYPASTA_BUILD="$BUILD" COPYPASTA_UNIVERSAL=1 \
    COPYPASTA_SIGN_IDENTITY="${DEVELOPER_ID:--}" COPYPASTA_HARDENED_RUNTIME="$HARDENED" \
    COPYPASTA_SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}" \
    ./build.sh
ARCHS="$(lipo -archs "$APP/Contents/MacOS/CopyPasta")"
[[ " $ARCHS " == *" arm64 "* && " $ARCHS " == *" x86_64 "* ]] || die "not a universal binary ($ARCHS)"
if [[ -n "$DEVELOPER_ID" ]]; then
    INFO="$(codesign -dvv "$APP" 2>&1)"
    grep -q 'Authority=Developer ID Application' <<<"$INFO" || die "not signed with a Developer ID Application certificate"
    grep -q 'flags=.*(runtime)' <<<"$INFO" || die "no hardened runtime"
    grep -q '^Timestamp=' <<<"$INFO" || die "no secure timestamp"
    # The default designated requirement names the team, so macOS keeps CopyPasta's privacy
    # permissions across updates without trusting any other app with the same identifier.
    codesign -d -r- "$APP" 2>&1 | grep -q 'certificate leaf\[subject.OU\]' || die "the designated requirement doesn't pin the team"
fi

# --- Notarize ----------------------------------------------------------------------------------
NOTARIZED=0
notarize() { # <file to submit> <what to staple>
    local log="$WORK/notary.json" id status
    xcrun notarytool submit "$1" "${NOTARY[@]}" --wait --timeout 1h --output-format json >"$log" || true
    id="$(plutil -extract id raw "$log" 2>/dev/null || true)"
    status="$(plutil -extract status raw "$log" 2>/dev/null || true)"
    if [[ "$status" != Accepted ]]; then
        cat "$log" >&2
        [[ -n "$id" ]] && xcrun notarytool log "$id" "${NOTARY[@]}" >&2 || true
        die "notarization of $(basename "$2") failed (${status:-no status})"
    fi
    xcrun stapler staple "$2"
    xcrun stapler validate "$2"
}
if [[ -n "$DEVELOPER_ID" && ${#NOTARY[@]} -gt 0 ]]; then
    step "Notarize the app"
    ditto -c -k --keepParent "$APP" "$WORK/CopyPasta.zip"
    notarize "$WORK/CopyPasta.zip" "$APP"
    spctl --assess --type execute -vv "$APP"
    NOTARIZED=1
fi

# --- Disk image --------------------------------------------------------------------------------
step "Disk image"
mkdir "$WORK/dmg"
ditto "$APP" "$WORK/dmg/CopyPasta.app"
ln -s /Applications "$WORK/dmg/Applications"
rm -f "$DMG"
# APFS + lzfse, as Sparkle recommends. hdiutil sometimes fails with "Resource busy" on CI
# runners; it passes on a retry.
for attempt in 1 2 3; do
    hdiutil create -volname CopyPasta -srcfolder "$WORK/dmg" -fs APFS -format ULFO -ov "$DMG" && break
    [[ $attempt == 3 ]] && die "hdiutil create failed"
    sleep 5
done
if [[ -n "$DEVELOPER_ID" ]]; then
    codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG"
    codesign --verify --strict "$DMG"
fi
if [[ $NOTARIZED == 1 ]]; then
    step "Notarize the disk image"
    notarize "$DMG" "$DMG"
    spctl --assess --type open --context context:primary-signature -vv "$DMG"
fi
hdiutil verify "$DMG"

# --- Appcast -----------------------------------------------------------------------------------
# A fresh one-item feed: Sparkle only needs the newest version, and each release's feed is
# served from that release (SUFeedURL is …/releases/latest/download/appcast.xml).
rm -f "$APPCAST" dist/release-notes.md
if [[ $SPARKLE_READY == 1 ]]; then
    step "Appcast"
    mkdir "$WORK/updates"
    cp "$DMG" "$WORK/updates/CopyPasta.dmg"
    APPCAST_ARGS=(
        --download-url-prefix "https://github.com/$REPO/releases/download/v$RELEASE_VERSION/"
        --link "https://github.com/$REPO"
        --full-release-notes-url "https://github.com/$REPO/releases"
        --maximum-deltas 0
    )
    if [[ -n "${RELEASE_NOTES:-}" ]]; then
        [[ -f "$RELEASE_NOTES" ]] || die "RELEASE_NOTES: no file $RELEASE_NOTES"
        cp "$RELEASE_NOTES" "$WORK/updates/CopyPasta.md" # same name as the archive: its notes
        cp "$RELEASE_NOTES" dist/release-notes.md
        APPCAST_ARGS+=(--embed-release-notes)
    fi
    generate_appcast() { "$SPARKLE_BIN/generate_appcast" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} "${APPCAST_ARGS[@]}" "$WORK/updates"; }
    if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
        private_key | generate_appcast || die "generate_appcast failed"
    else
        generate_appcast || die "generate_appcast failed (no Sparkle private key? Set SPARKLE_PRIVATE_KEY or SPARKLE_KEY_FILE)"
    fi
    cp "$WORK/updates/appcast.xml" "$APPCAST"

    # Read the feed back the way the app will: the right version, URL and size, and a signature
    # that verifies with the public key inside the app.
    xpath() { xmllint --xpath "string($1)" "$APPCAST"; }
    ENCLOSURE="//*[local-name()='item'][1]/*[local-name()='enclosure']"
    FEED_BUILD="$(xpath "//*[local-name()='item'][1]/*[local-name()='version']")"
    FEED_VERSION="$(xpath "//*[local-name()='item'][1]/*[local-name()='shortVersionString']")"
    FEED_URL="$(xpath "$ENCLOSURE/@url")"
    FEED_LENGTH="$(xpath "$ENCLOSURE/@length")"
    FEED_SIGNATURE="$(xpath "$ENCLOSURE/@*[local-name()='edSignature']")"
    [[ "$FEED_BUILD" == "$BUILD" && "$FEED_VERSION" == "$RELEASE_VERSION" ]] \
        || die "appcast says $FEED_VERSION ($FEED_BUILD), expected $RELEASE_VERSION ($BUILD)"
    [[ "$FEED_URL" == "https://github.com/$REPO/releases/download/v$RELEASE_VERSION/CopyPasta.dmg" ]] \
        || die "appcast download URL is $FEED_URL"
    [[ "$FEED_LENGTH" == "$(stat -f %z "$DMG")" ]] || die "appcast length $FEED_LENGTH isn't the DMG's size"
    APP_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
    "$WORK/sparkle_key" verify "$APP_KEY" "$FEED_SIGNATURE" "$DMG" \
        || die "the appcast's EdDSA signature doesn't verify with the app's SUPublicEDKey"
    echo "EdDSA signature verifies with the app's SUPublicEDKey"
fi

# --- Summary -----------------------------------------------------------------------------------
SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    { echo "version=$RELEASE_VERSION"; echo "build=$BUILD"; echo "sha256=$SHA256"; echo "notarized=$NOTARIZED"; } >>"$GITHUB_OUTPUT"
fi
step "Done: CopyPasta $RELEASE_VERSION (build $BUILD)"
echo "  $DMG  sha256 $SHA256"
if [[ $SPARKLE_READY == 1 ]]; then echo "  $APPCAST"; else echo "  (no appcast: no Sparkle key)"; fi
if [[ $NOTARIZED == 1 ]]; then
    echo "  Developer ID signed and notarized, tickets stapled."
else
    cat >&2 <<EOF

  *********************************************************************************
  NOT NOTARIZED$( [[ -z "$DEVELOPER_ID" ]] && echo " (ad-hoc signed)" ). Don't publish this one: on other Macs Gatekeeper
  blocks it until the user allows it in System Settings › Privacy & Security, and
  macOS ties privacy permissions to the signature, so an ad-hoc build loses them
  on every update. README › Releasing sets up Developer ID signing.
  *********************************************************************************
EOF
    if [[ $REQUIRE_NOTARIZATION == 1 ]]; then exit 1; fi
fi
