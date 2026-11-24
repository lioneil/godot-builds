#!/usr/bin/env bash
# Builds the Godot editor from its source with the patches in scripts/godot/patches/.
#
#   build.sh stamp                         print the engine's stamp: the version and a hash of this script,
#                                          the SCons pin and the patches
#   build.sh build <src dir> <install dir> build the editor in <src dir> (downloading the source when it
#                                          is missing) and install it as <install dir>/godot with its STAMP
#   build.sh fetch <install dir>           install the prebuilt editor of the current stamp from the
#                                          mirror's releases, with its STAMP
set -euo pipefail

GODOT_VERSION=4.7.2
GODOT_TARBALL="godot-${GODOT_VERSION}-stable.tar.xz"
GODOT_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/${GODOT_TARBALL}"
GODOT_SHA512=15e23f8423003f5d32da07c34a8651e43af23b050cc0dea2d4fba6944ca445d079edb52b66fdf82b6d5739bba1fe707b9e27b8836b19f09f64f313966160f8fc
SCONS_ARGS=(platform=linuxbsd target=editor production=yes)
RELEASES="https://github.com/lioneil/godot-builds/releases/download"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: build.sh stamp | build <src dir> <install dir> | fetch <install dir>" >&2
    exit 2
}

stamp() {
    local files=()
    local f
    while IFS= read -r f; do
        files+=("$f")
    done < <(cd "$HERE" && LC_ALL=C ls -1 build.sh requirements.txt patches/*.patch 2>/dev/null | LC_ALL=C sort)
    local sum
    sum="$(cd "$HERE" && for f in "${files[@]}"; do
        printf '%s\n' "$f"
        cat "$f"
    done | sha256sum | cut -c1-12)"
    echo "${GODOT_VERSION}-${sum}"
}

command_build() {
    local src="$1" install="$2"
    local missing=() cmd
    for cmd in g++ pkg-config git xz curl scons; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Missing prerequisites: ${missing[*]}" >&2
        echo "On Ubuntu: sudo apt install build-essential git xz-utils pkg-config curl, and pip install -r scripts/godot/requirements.txt" >&2
        exit 1
    fi

    if [ ! -e "$src/.git" ] || [ "$(cat "$src/.godot-version" 2>/dev/null)" != "$GODOT_VERSION" ]; then
        local tarball="$src.tar.xz"
        rm -rf "$src"
        mkdir -p "$src"
        curl --fail --location --silent --show-error --output "$tarball" "$GODOT_URL"
        if ! echo "$GODOT_SHA512  $tarball" | sha512sum --check --status; then
            rm -f "$tarball"
            echo "Godot source download failed its SHA-512 check; the tarball was deleted." >&2
            exit 1
        fi
        tar -xJf "$tarball" -C "$src" --strip-components=1
        rm -f "$tarball"
        echo "$GODOT_VERSION" > "$src/.godot-version"
        git -C "$src" init -q
        git -C "$src" add -A
        git -C "$src" -c user.name=build -c user.email=build@localhost commit -q -m "Godot $GODOT_VERSION source"
    fi

    git -C "$src" checkout -q -- .
    local patch
    for patch in "$HERE"/patches/*.patch; do
        if ! git -C "$src" apply "$patch"; then
            echo "Patch $(basename "$patch") does not apply to Godot $GODOT_VERSION: rebase it with the steps in docs/wiki/godot-notes.md (The patched engine)." >&2
            exit 1
        fi
    done

    (cd "$src" && scons "${SCONS_ARGS[@]}" -j"$(nproc)")

    mkdir -p "$install"
    rm -f "$install/STAMP"
    cp "$src/bin/godot.linuxbsd.editor.x86_64" "$install/godot"
    chmod 755 "$install/godot"
    stamp > "$install/STAMP"
}

command_fetch() {
    local install="$1"
    local current archive
    current="$(stamp)"
    archive="$install/godot.tar.xz"
    mkdir -p "$install"
    rm -f "$install/STAMP"
    if ! curl --fail --location --silent --show-error --output "$archive" "$RELEASES/$current/godot.tar.xz"; then
        rm -f "$archive"
        echo "No prebuilt engine for $current: publish the patch set with scripts/godot/publish.sh and wait for its build." >&2
        exit 1
    fi
    tar -xJf "$archive" -C "$install" godot
    rm -f "$archive"
    chmod 755 "$install/godot"
    echo "$current" > "$install/STAMP"
}

case "${1:-}" in
    stamp) [ "$#" -eq 1 ] || usage; stamp ;;
    build) [ "$#" -eq 3 ] || usage; command_build "$2" "$3" ;;
    fetch) [ "$#" -eq 2 ] || usage; command_fetch "$2" ;;
    *) usage ;;
esac
