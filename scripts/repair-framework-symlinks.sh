#!/bin/sh
# Repairs macOS .framework bundles inside SwiftPM binary artifacts whose
# internal symlinks were mangled during archive extraction. Seen in the field
# with the onnxruntime xcframework (sherpa-onnx's dependency): the artifact
# lands with a broken `Versions/Current`, xcodebuild warns
# "Couldn't resolve framework symlink … Versions/Current", and the final
# app signing fails with
#   "code object is not signed at all — In subcomponent: onnxruntime.framework"
# (docs/10 troubleshooting). CI never catches this because its builds run
# with CODE_SIGNING_ALLOWED=NO — the failing step only exists on a real Mac.
#
# Idempotent and conservative: touches only entries that are NOT already
# valid symlinks, only inside the given artifacts directory. Healthy
# frameworks pass through untouched, so running this on every build is free.
set -eu

root="${1:-build/SourcePackages/artifacts}"
[ -d "$root" ] || exit 0

find "$root" -type d -name "*.framework" | while IFS= read -r fw; do
    versions="$fw/Versions"
    # Flat (iOS-style) frameworks have no Versions directory and no symlinks.
    [ -d "$versions" ] || continue

    # The real payload directory, e.g. Versions/A.
    payload=""
    for candidate in "$versions"/*; do
        name=$(basename "$candidate")
        [ "$name" = "Current" ] && continue
        if [ -d "$candidate" ] && [ ! -L "$candidate" ]; then
            payload="$name"
            break
        fi
    done
    [ -n "$payload" ] || continue

    # Versions/Current must be a symlink to the payload directory. After a
    # mangled extraction it is a regular file, a broken link, or missing.
    if [ ! -L "$versions/Current" ]; then
        rm -rf "$versions/Current"
        ln -s "$payload" "$versions/Current"
        echo "repaired: $versions/Current -> $payload"
    fi

    # Top-level entries (the binary, Resources, …) must be symlinks through
    # Versions/Current, one per payload entry.
    for entry in "$versions/$payload"/*; do
        [ -e "$entry" ] || continue
        name=$(basename "$entry")
        if [ ! -L "$fw/$name" ]; then
            rm -rf "$fw/$name"
            ln -s "Versions/Current/$name" "$fw/$name"
            echo "repaired: $fw/$name -> Versions/Current/$name"
        fi
    done
done
