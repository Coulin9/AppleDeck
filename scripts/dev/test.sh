#!/bin/bash
# Run the existing host-side test suites of changed repositories.
# (Suite functions return explicitly on failure: they run inside `if`, where
# errexit is suspended.)
# A repository counts as changed when its working tree is dirty or HEAD
# differs from its upstream branch.
#
#   scripts/dev/test.sh                 changed repositories only
#   scripts/dev/test.sh --all           every repository
#   scripts/dev/test.sh REPO...         named repositories (AppleDeck,
#                                       neptune-protocol, virglrenderer,
#                                       d3dmetal-native, virtio-win-mesa)
source "$(dirname "$0")/lib.sh"

REPOS=(AppleDeck neptune-protocol virglrenderer d3dmetal-native virtio-win-mesa)
TB="$DEV_ROOT/.build/test"
export PATH="$DEV_ROOT/.build/toolchain/venv/bin:/opt/homebrew/bin:$PATH"

changed() {
    local repo="$WORKSPACE/$1"
    [[ -n "$(git -C "$repo" status --porcelain)" ]] && return 0
    local up; up="$(git -C "$repo" rev-parse -q --verify '@{upstream}' 2>/dev/null)" || return 1
    [[ "$(git -C "$repo" rev-parse HEAD)" != "$up" ]]
}

meson_suite() { # NAME SRC [SETUP ARGS...]
    local name="$1" b="$TB/$1" src="$2"; shift 2
    local log="$TB/$name.build.log"
    mkdir -p "$TB"
    # Build everything first: some tests spawn binaries they do not depend on.
    if ! { [[ -f "$b/build.ninja" ]] || meson setup "$b" "$src" "$@"; } >"$log" 2>&1 \
            || ! meson compile -C "$b" >>"$log" 2>&1; then
        grep -E -B2 -A6 'error|FAILED|Undefined' "$log" | tail -25 >&2
        say "build failed, full log: $log"
        return 1
    fi
    # Meson records the inherited environment in its test log; pass only what
    # the suites need so tokens in the caller's environment are not written out.
    env -i HOME="$HOME" USER="${USER:-}" TMPDIR="${TMPDIR:-/tmp}" LANG="${LANG:-C}" PATH="$PATH" \
        PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}" D3DMETAL_FRAMEWORK_PATH="${D3DMETAL_FRAMEWORK_PATH:-}" \
        meson test -C "$b" --print-errorlogs -q
}

t_AppleDeck() {
    (cd "$DEV_ROOT" && python3 -B -m unittest discover -s Tests/GuestIntegrationTests -p 'test_*.py') || return 1
    local swift_paths=(Sources Tests/AppleDeckCoreTests Tests/AppleDeckDisplayTests Tests/AppleDeckVMTests Package.swift)
    local swift_changed
    swift_changed="$(git -C "$DEV_ROOT" status --porcelain -- "${swift_paths[@]}")"
    if git -C "$DEV_ROOT" rev-parse -q --verify '@{upstream}' >/dev/null 2>&1; then
        swift_changed+="$(git -C "$DEV_ROOT" diff --name-only '@{upstream}...HEAD' -- "${swift_paths[@]}")"
    fi
    if [[ -n "$swift_changed" || -n "${ALL:-}" ]]; then
        # XCTest needs full Xcode even when Command Line Tools are selected.
        local developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
        [[ "$developer_dir" != /Library/Developer/CommandLineTools ]] \
            || developer_dir=/Applications/Xcode.app/Contents/Developer
        (cd "$DEV_ROOT" && DEVELOPER_DIR="$developer_dir" APPLEDECK_LIBKRUN_DIR="$DEV_OUT/libkrun" \
            APPLEDECK_LIBKRUN_INCLUDE="$WORKSPACE/libkrun/include" \
            swift test --scratch-path "$TB/swift")
    fi
}
t_neptune-protocol() { meson_suite neptune-protocol "$WORKSPACE/neptune-protocol"; }
t_virglrenderer() {
    PKG_CONFIG_PATH="$DEV_OUT/libepoxy/prefix/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
        meson_suite virglrenderer "$WORKSPACE/virglrenderer" --buildtype=debugoptimized \
        -Dvenus=true -Dneptune=true -Dvulkan-dload=true -Dplatforms=[] \
        -Drender-server-mode=process -Drender-server-worker=process \
        -Dvtest=false -Dtests=true -Dvideo=false -Dcheck-gl-errors=false
}
t_d3dmetal-native() {
    local fw
    fw="$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/Library/Application Support/AppleDeck/configuration.json"))).get("d3dMetalFrameworkPath",""))' 2>/dev/null || true)"
    D3DMETAL_FRAMEWORK_PATH="${D3DMETAL_FRAMEWORK_PATH:-$fw}" \
        meson_suite d3dmetal-native "$WORKSPACE/d3dmetal-native" \
        --cross-file "$WORKSPACE/d3dmetal-native/build-macos-x86_64.txt" -Dtests=enabled
}
t_virtio-win-mesa() {
    local t
    for t in test_pipeline_library_ring.py test_present_resource_creation.py; do
        python3 "$WORKSPACE/virtio-win-mesa/src/virtio/neptune/tests/$t" || return 1
    done
}

selected=()
case "${1:-}" in
    --all) ALL=1; selected=("${REPOS[@]}") ;;
    "") for r in "${REPOS[@]}"; do changed "$r" && selected+=("$r"); done ;;
    *) selected=("$@") ;;
esac
[[ ${#selected[@]} -gt 0 ]] || { say "no changed repositories"; exit 0; }

failed=()
for r in "${selected[@]}"; do
    declare -F "t_$r" >/dev/null || fail "unknown repository: $r"
    if step "test $r" "t_$r"; then :; else failed+=("$r"); fi
done
if [[ ${#failed[@]} -gt 0 ]]; then
    printf '\033[1;31m[dev]\033[0m FAILED: %s\n' "${failed[*]}" >&2
    exit 1
fi
say "all passed: ${selected[*]}"
