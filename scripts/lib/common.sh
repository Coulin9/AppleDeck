#!/bin/bash
# Shared helpers for the AppleDeck component build graph.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_ROOT="$ROOT/.build"
CACHE="$BUILD_ROOT/cache"
SRC="$BUILD_ROOT/src"
OUT="$BUILD_ROOT/out"
STAMPS="$BUILD_ROOT/stamps"
LOGS="$BUILD_ROOT/logs"
APP="$ROOT/build/AppleDeck.app"
MANIFEST="$ROOT/build/manifest.json"

mkdir -p "$CACHE" "$SRC" "$OUT" "$STAMPS" "$LOGS" "$ROOT/build"

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1762377600}"
export LC_ALL="${LC_ALL:-C}"

PODMAN_BIN="${PODMAN_BIN:-$(command -v podman || true)}"
[[ -n "$PODMAN_BIN" ]] || PODMAN_BIN=/opt/podman/bin/podman
PODMAN_CONNECTION="${APPLEDECK_BUILDER_CONNECTION:-appledeck-builder}"
BUILDER_IMAGE="${APPLEDECK_BUILDER_IMAGE:-debian:trixie}"

log()  { printf '\033[1;34m[appleDeck]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[appleDeck]\033[0m warning: %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[appleDeck]\033[0m error: %s\n' "$*" >&2; exit 1; }

require_cmd() {
    local name
    for name in "$@"; do
        command -v "$name" >/dev/null 2>&1 || die "required command not found: $name"
    done
}

sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }

fetch_verified() { # URL DEST SHA256
    local url="$1" dest="$2" want="$3"
    if [[ -f "$dest" ]] && [[ "$(sha256_file "$dest")" == "$want" ]]; then
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    log "download $url"
    curl -fL --retry 3 --retry-delay 2 -o "$dest.part" "$url" || die "download failed: $url"
    local got; got="$(sha256_file "$dest.part")"
    [[ "$got" == "$want" ]] || { rm -f "$dest.part"; die "checksum mismatch for $url (got $got, want $want)"; }
    mv "$dest.part" "$dest"
}

input_digest() { # NAME KEY VALUE [KEY VALUE ...]
    local name="$1"; shift
    {
        printf 'name=%s\n' "$name"
        while [[ $# -gt 0 ]]; do
            printf '%s=%s\n' "$1" "$2"
            shift 2
        done
    } | shasum -a 256 | awk '{print $1}'
}

# Build and package must agree on which inputs produced the Swift frontend.
swift_input_digest() {
    input_digest swift \
        swift_sources "$(find "$ROOT/Sources" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')" \
        package "$(sha256_file "$ROOT/Package.swift")" \
        info "$(sha256_file "$ROOT/Info.plist")" \
        entitlements "$(sha256_file "$ROOT/AppleDeckVM.entitlements")" \
        libkrun "$(sha256_file "$OUT/libkrun/libkrun.1.dylib")"
}

git_state_digest() { # REPO
    local repo="$1"
    {
        git -C "$repo" rev-parse HEAD
        git -C "$repo" diff --binary --no-ext-diff
        git -C "$repo" diff --cached --binary --no-ext-diff
        git -C "$repo" ls-files --others --exclude-standard -z | while IFS= read -r -d '' f; do
            printf 'untracked %s\n' "$f"
            shasum -a 256 "$repo/$f"
        done
    } | shasum -a 256 | awk '{print $1}'
}

stamp_path() { printf '%s/%s.json\n' "$STAMPS" "$1"; }

stamp_write() { # NAME INPUT_DIGEST OUTPUT...
    local name="$1" input="$2"; shift 2
    local path; path="$(stamp_path "$name")"
    {
        printf '{\n  "name": "%s",\n  "input": "%s",\n  "outputs": {\n' "$name" "$input"
        local first=1 out
        for out in "$@"; do
            [[ $first -eq 1 ]] || printf ',\n'
            first=0
            printf '    "%s": "%s"' "${out#"$ROOT"/}" "$(sha256_file "$out")"
        done
        printf '\n  }\n}\n'
    } > "$path"
    log "stamp $name"
}

reuse_requested() {
    local name="$1"
    [[ -n "${APPLEDECK_REUSE:-}" ]] || return 1
    case " ${APPLEDECK_REUSE//,/ } " in
        *" all "*) return 0 ;;
        *" $name "*) return 0 ;;
    esac
    return 1
}

verify_component_artifacts() { # NAME INPUT OUTPUT... (empty INPUT checks outputs only)
    local name="$1" input="$2"; shift 2
    local path; path="$(stamp_path "$name")"
    [[ -f "$path" ]] || die "no build stamp for '$name'; run ./build.sh --component $name"
    local recorded
    recorded="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["input"])' "$path")"
    [[ -z "$input" || "$recorded" == "$input" ]] || die "inputs changed for '$name'; run ./build.sh --component $name without --reuse"
    local out expected
    for out in "$@"; do
        [[ -f "$out" ]] || die "output missing for '$name': ${out#"$ROOT"/}"
        expected="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["outputs"].get(sys.argv[2],""))' "$path" "${out#"$ROOT"/}")"
        [[ "$expected" == "$(sha256_file "$out")" ]] || die "artifact differs from '$name' build stamp: ${out#"$ROOT"/}; run ./build.sh --component $name"
    done
}

require_reuse_artifact() { # NAME INPUT OUTPUT...
    verify_component_artifacts "$@"
    log "reuse $1"
}

component_should_reuse() { # NAME INPUT OUTPUT...
    if reuse_requested "$1"; then
        require_reuse_artifact "$@"
        return 0
    fi
    return 1
}

builder() {
    [[ -x "$PODMAN_BIN" ]] || die "podman not found (set PODMAN_BIN)"
    "$PODMAN_BIN" --connection "$PODMAN_CONNECTION" "$@"
}

require_builder() {
    builder info --format '{{.Host.OS}}/{{.Host.Arch}}' >/dev/null 2>&1 \
        || die "Linux builder '$PODMAN_CONNECTION' is unavailable; run: podman machine start $PODMAN_CONNECTION"
}

sign() { codesign --force --sign - "$1"; }

install_name() { install_name_tool -id "@rpath/$2" "$1"; }

ensure_meson() {
    local toolchain="$BUILD_ROOT/toolchain" venv="$BUILD_ROOT/toolchain/venv"
    if [[ ! -x "$venv/bin/meson" ]] || ! "$venv/bin/python3" -c 'import yaml, mako, packaging' >/dev/null 2>&1; then
        mkdir -p "$toolchain"
        [[ -x "$venv/bin/pip" ]] || python3 -m venv "$venv"
        "$venv/bin/pip" install --quiet --upgrade pip
        "$venv/bin/pip" install --quiet "meson==1.9.1" pyyaml mako packaging
    fi
    export PATH="$venv/bin:$PATH"
}

ensure_rust() {
    local toolchain="$BUILD_ROOT/toolchain"
    local rustup_home="$toolchain/rustup" cargo_home="$toolchain/cargo"
    if [[ ! -x "$cargo_home/bin/cargo" ]]; then
        mkdir -p "$toolchain"
        if [[ ! -x "$toolchain/rustup-init" ]]; then
            curl -fL -o "$toolchain/rustup-init" \
                https://static.rust-lang.org/rustup/dist/aarch64-apple-darwin/rustup-init \
                || die "cannot download rustup-init"
            chmod +x "$toolchain/rustup-init"
        fi
        RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
            "$toolchain/rustup-init" -y --profile minimal --default-toolchain stable --no-modify-path
    fi
    export RUSTUP_HOME="$rustup_home"
    export CARGO_HOME="$cargo_home"
    export PATH="$cargo_home/bin:$PATH"
}

ensure_git_commit() { # URL DIR COMMIT
    local url="$1" dir="$2" commit="$3"
    if [[ ! -d "$dir/.git" ]]; then
        mkdir -p "$(dirname "$dir")"
        git init "$dir"
        git -C "$dir" remote add origin "$url"
    fi
    if [[ "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" != "$commit" ]]; then
        git -C "$dir" fetch --depth 1 origin "$commit"
        git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
    fi
    [[ "$(git -C "$dir" rev-parse HEAD)" == "$commit" ]] || die "git checkout mismatch for $url $commit"
}

ensure_git_clone() { # URL DIR TAG
    local url="$1" dir="$2" tag="$3"
    if [[ ! -d "$dir/.git" ]]; then
        mkdir -p "$(dirname "$dir")"
        git clone --depth 1 --branch "$tag" "$url" "$dir"
    fi
}

ensure_brew() {
    local pkg
    for pkg in "$@"; do
        brew list "$pkg" >/dev/null 2>&1 || brew install "$pkg"
    done
}
