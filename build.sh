#!/bin/bash
# Build CopyPasta.app from the Swift package. Usage: ./build.sh [run|install]
#   run      relaunch the freshly built dist/CopyPasta.app
#   install  copy it to /Applications (where Spotlight and Raycast find it) and launch it
#
# Optional environment (scripts/release.sh sets most of these for release builds):
#   COPYPASTA_SIGN_IDENTITY        certificate to sign with (default: your Developer ID, else Apple Development, else ad-hoc)
#   COPYPASTA_VERSION              CFBundleShortVersionString (default: the latest vX.Y.Z tag's,
#                                  else Info.plist's)
#   COPYPASTA_BUILD                CFBundleVersion, what Sparkle compares to find newer versions
#                                  (default: the number of commits, which only goes up)
#   COPYPASTA_UNIVERSAL=1          build for both Apple silicon and Intel
#   COPYPASTA_HARDENED_RUNTIME=1   hardened runtime + secure timestamp, as notarization requires
#                                  (needs a real certificate)
#   COPYPASTA_SPARKLE_PUBLIC_KEY   the SUPublicEDKey to build in, instead of Info.plist's
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=()
[[ "${COPYPASTA_UNIVERSAL:-}" == 1 ]] && ARCHS=(--arch arm64 --arch x86_64)
# ${ARCHS[@]+…}: bash 3.2 (macOS's) treats an empty array as unset under `set -u`.
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

# Version: the release tag (vX.Y.Z → X.Y.Z) and the commit count. A build from source is then
# never older than the release it contains, so Sparkle doesn't offer to "update" it to that.
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" Info.plist; }
if [[ -z "${COPYPASTA_VERSION:-}" ]]; then
    TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
    COPYPASTA_VERSION="${TAG#v}"
fi
VERSION="${COPYPASTA_VERSION:-$(plist_value CFBundleShortVersionString)}"
BUILD="${COPYPASTA_BUILD:-$(git rev-list --count HEAD 2>/dev/null || plist_value CFBundleVersion)}"

APP="dist/CopyPasta.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/CopyPasta" "$APP/Contents/MacOS/CopyPasta"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" # scripts/make_icon.sh makes it
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"
if [[ -n "${COPYPASTA_SPARKLE_PUBLIC_KEY:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $COPYPASTA_SPARKLE_PUBLIC_KEY" "$PLIST"
fi

# Sparkle (self-updates), where the binary's rpath @executable_path/../Frameworks finds it.
# ditto keeps the framework's symlinks. Its XPC services are for sandboxed apps only
# (sparkle-project.org/documentation/sandboxing): CopyPasta isn't sandboxed, so they go.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$BIN/Sparkle.framework" "$SPARKLE"
rm -rf "$SPARKLE/XPCServices" "$SPARKLE/Versions/B/XPCServices"

# Auto-paste, Copy Tricks and dictation need Accessibility (and dictation the Microphone),
# permissions macOS ties to the signature. An ad-hoc signature changes on every build, so
# they're lost on each rebuild. Signing with a certificate (COPYPASTA_SIGN_IDENTITY, see
# README) keeps them.
# Don't pin the requirement to the bundle identifier alone to get around this: any app
# signed with that identifier would then inherit CopyPasta's Accessibility access.
# None given: a valid Developer ID Application certificate from the keychain, else an Apple
# Development one (by hash: two certificates can share a name; revoked ones skipped). Else ad-hoc.
if [[ -z "${COPYPASTA_SIGN_IDENTITY:-}" ]]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null | grep -v -e REVOKED -e EXPIRED || true)"
    for KIND in "Developer ID Application" "Apple Development"; do
        COPYPASTA_SIGN_IDENTITY="$(sed -nE "s/^ *[0-9]+\) ([0-9A-F]{40}) \"$KIND: .*/\1/p" <<<"$IDENTITIES" | head -1)"
        [[ -n "$COPYPASTA_SIGN_IDENTITY" ]] && break
    done
fi
IDENTITY="${COPYPASTA_SIGN_IDENTITY:--}"
SIGN=(codesign --force --sign "$IDENTITY")
if [[ "${COPYPASTA_HARDENED_RUNTIME:-}" == 1 ]]; then
    # The hardened runtime only loads libraries signed by the same team (library validation),
    # and an ad-hoc signature has no team: Sparkle wouldn't load.
    [[ "$IDENTITY" != "-" ]] || { echo "error: the hardened runtime needs COPYPASTA_SIGN_IDENTITY" >&2; exit 1; }
    SIGN+=(--options runtime --timestamp)
fi
# Inside out, innermost code first; never --deep (it signs everything alike, e.g. would give
# Sparkle's helpers CopyPasta's entitlements).
"${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
"${SIGN[@]}" "$SPARKLE"
"${SIGN[@]}" --identifier com.marclamy.copypasta --entitlements CopyPasta.entitlements "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP ($VERSION, build $BUILD)"
if [[ "$IDENTITY" == "-" ]]; then
    echo "Note: ad-hoc signed, so macOS forgets CopyPasta's Accessibility and Microphone"
    echo "      permissions on every rebuild. Set COPYPASTA_SIGN_IDENTITY to keep them (see README)."
fi

if [[ "${1:-}" == "run" ]]; then
    pkill -x CopyPasta 2>/dev/null || true
    sleep 0.3
    open "$APP"
    echo "Launched"
fi

if [[ "${1:-}" == "install" ]]; then
    pkill -x CopyPasta 2>/dev/null || true
    sleep 0.3
    # The app used to be called Pastey: CopyPasta replaces it (and moves its history
    # and settings over on first launch).
    rm -rf /Applications/Pastey.app
    rm -rf /Applications/CopyPasta.app
    ditto "$APP" /Applications/CopyPasta.app
    # Register it now, so Spotlight and Raycast list it without waiting for a reindex.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/CopyPasta.app
    open /Applications/CopyPasta.app
    echo "Installed /Applications/CopyPasta.app and launched it"
fi
