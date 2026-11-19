#!/bin/bash
# AppleDeck build entry point.
#
#   ./build.sh                          full build
#   ./build.sh --reuse kernel,layer     reuse only the named artifacts
#   ./build.sh --reuse all              reuse every native/guest artifact
#   ./build.sh --list-components
#   ./build.sh --component NAME
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

COMPONENTS=(
    kernel
    libepoxy
    virglrenderer
    d3dmetal
    mullion
    libkrun
    kosmicrisp
    moltenvk
    gvproxy
    macmon
    initramfs
    mesa
    agent
    uu-runtime
    fex-eac
    mangoapp
    guest-integration
    neptune-probe
    neptune
    layer
    swift
)

REUSE=""
ONLY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reuse)
            [[ $# -ge 2 ]] || die "--reuse requires a list or 'all'"
            REUSE="$2"; shift 2 ;;
        --reuse=*) REUSE="${1#*=}"; shift ;;
        --component)
            [[ $# -ge 2 ]] || die "--component requires a name"
            ONLY="$2"; shift 2 ;;
        --list-components) printf '%s\n' "${COMPONENTS[@]}"; exit 0 ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

if [[ -n "$REUSE" ]]; then
    if [[ "$REUSE" != "all" ]]; then
        IFS=',' read -r -a requested <<< "$REUSE"
        for name in "${requested[@]}"; do
            found=0
            for known in "${COMPONENTS[@]}"; do [[ "$name" == "$known" ]] && found=1; done
            [[ $found -eq 1 ]] || die "unknown component in --reuse: $name"
        done
    fi
    export APPLEDECK_REUSE="$REUSE"
    log "explicit reuse: $REUSE"
else
    export APPLEDECK_REUSE=""
    log "full build"
    if [[ -z "$ONLY" ]]; then
        rm -rf "$OUT"
        mkdir -p "$OUT"
    fi
fi

run_component() {
    local name="$1"
    local script="$ROOT/scripts/components/$name.sh"
    [[ -f "$script" ]] || die "missing component script: ${script#"$ROOT"/}"
    log "component: $name"
    # Run the component in its own process so a reuse path's `exit 0` does not
    # terminate the build loop before packaging.
    bash "$script"
}

if [[ -n "$ONLY" ]]; then
    found=0
    for known in "${COMPONENTS[@]}"; do [[ "$ONLY" == "$known" ]] && found=1; done
    [[ $found -eq 1 ]] || die "unknown component: $ONLY"
    run_component "$ONLY"
    exit 0
fi

START=$(date +%s)
for name in "${COMPONENTS[@]}"; do
    run_component "$name"
done
"$ROOT/scripts/package.sh"
log "build complete in $(( $(date +%s) - START ))s: ${APP#"$ROOT"}"
