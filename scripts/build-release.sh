#!/usr/bin/env bash
#
# build-release.sh — Cross-compile Grok CLI for Linux (x86_64, aarch64) and
# Windows (x86_64), then package each target as a versioned .zip.
#
# Targets:
#   linux-x86_64   glibc >= 2.31  (Ubuntu 20.04+)
#   linux-aarch64  glibc >= 2.31  (Ubuntu 20.04+)
#   windows-x86_64 Win7+           (MinGW-w64 static CRT)
#
# Output:
#   dist/grok-{version}-linux-x86_64.zip
#   dist/grok-{version}-linux-aarch64.zip
#   dist/grok-{version}-windows-x86_64.zip
#
# Each zip contains a single binary named `grok` (Linux) or `grok.exe` (Windows).
#
# Prerequisites (auto-checked):
#   - Rust toolchain (rustup manages targets automatically)
#   - Zig (cargo-zigbuild uses it as the C linker for cross-compilation)
#   - cargo-zigbuild  (cargo install cargo-zigbuild)
#   - zip
#   - protoc / DotSlash  (for proto codegen build scripts)
#
# Usage:
#   ./scripts/build-release.sh                  # build ALL targets
#   ./scripts/build-release.sh linux-x86_64     # build one target
#   ./scripts/build-release.sh linux-aarch64
#   ./scripts/build-release.sh windows-x86_64
#   GROK_VERSION=1.0.0 ./scripts/build-release.sh  # override version
#   STRIP_BIN=1 ./scripts/build-release.sh         # strip debug symbols
#
set -euo pipefail

# ─── colour helpers ──────────────────────────────────────────────────────────
if [ -t 2 ]; then
    C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'; C_CYAN=$'\033[36m'; C_RESET=$'\033[0m'
else
    C_BOLD=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''; C_RESET=''
fi

info()  { printf '%s==>%s %s\n' "$C_CYAN" "$C_RESET" "$*" >&2; }
ok()    { printf '%s✓%s  %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn()  { printf '%s!%s  %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%s✗%s  %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# ─── paths ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
STAGE_DIR="$REPO_ROOT/target/stage"

# ─── version ─────────────────────────────────────────────────────────────────
# Priority: GROK_VERSION env var > Cargo.toml [package].version of xai-grok-version
VERSION="${GROK_VERSION:-}"
if [ -z "$VERSION" ]; then
    VERSION=$(awk -F'"' '/^version[[:space:]]*=/{print $2}' \
        "$REPO_ROOT/crates/codegen/xai-grok-version/Cargo.toml" | head -1)
fi
[ -n "$VERSION" ] || die "Could not determine version. Set GROK_VERSION or check Cargo.toml."
info "Version: $VERSION"

# ─── build configuration ─────────────────────────────────────────────────────
BIN_NAME="xai-grok-pager"          # cargo artifact name
SHIP_NAME="grok"                   # shipped binary name
PROFILE="release-dist"             # distribution profile from Cargo.toml
GLIBC_MIN="2.31"                   # minimum glibc for Linux targets
PACKAGE_NAME="${PACKAGE_NAME:-$SHIP_NAME}"

# ─── prerequisite checks ─────────────────────────────────────────────────────
check_prereqs() {
    local missing=()

    command -v cargo >/dev/null 2>&1 || missing+=("cargo (Rust)")
    command -v zip >/dev/null 2>&1   || missing+=("zip")

    # cargo-zigbuild is required for cross-compilation with glibc pinning
    if ! cargo zigbuild --version >/dev/null 2>&1; then
        missing+=("cargo-zigbuild (cargo install cargo-zigbuild)")
    fi

    # Zig is the C compiler / linker backend for cargo-zigbuild
    command -v zig >/dev/null 2>&1 || missing+=("zig (https://ziglang.org/download/)")

    # protoc — needed by build.rs proto codegen
    if ! command -v protoc >/dev/null 2>&1; then
        if [ -x "$REPO_ROOT/bin/protoc" ] && command -v dotslash >/dev/null 2>&1; then
            export PATH="$REPO_ROOT/bin:$PATH"
        else
            warn "protoc not found. Install DotSlash + bin/protoc or system protoc."
        fi
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing prerequisites:\n  - ${missing[*]}"
    fi
    ok "All prerequisites satisfied."
}

# ─── target definitions ──────────────────────────────────────────────────────
# Each target: zigbuild_target | rust_target | output_dir | binary_ext | platform_tag
TARGETS=(
    "linux-x86_64|x86_64-unknown-linux-gnu.$GLIBC_MIN|x86_64-unknown-linux-gnu||linux-x86_64"
    "linux-aarch64|aarch64-unknown-linux-gnu.$GLIBC_MIN|aarch64-unknown-linux-gnu||linux-aarch64"
    "windows-x86_64|x86_64-pc-windows-gnu|x86_64-pc-windows-gnu|.exe|windows-x86_64"
)

# ─── rustup target management ────────────────────────────────────────────────
ensure_rust_targets() {
    info "Ensuring Rust targets are installed..."
    # zigbuild uses the plain target triple for rustup; the .GLIBC suffix is
    # only a cargo-zigbuild extension that selects the Zig glibc version.
    local plain_targets=(
        "x86_64-unknown-linux-gnu"
        "aarch64-unknown-linux-gnu"
        "x86_64-pc-windows-gnu"
    )
    for t in "${plain_targets[@]}"; do
        if ! rustup target list --installed 2>/dev/null | grep -q "$t"; then
            rustup target add "$t"
        fi
    done
    ok "Rust targets ready."
}

# ─── build a single target ───────────────────────────────────────────────────
# Args: zigbuild_target  rust_target  output_subdir  binary_ext  platform_tag
build_target() {
    local zig_target="$1"
    local rust_target="$2"
    local out_subdir="$3"
    local bin_ext="$4"
    local platform_tag="$5"

    local bin_artifact="${BIN_NAME}${bin_ext}"
    local ship_artifact="${SHIP_NAME}${bin_ext}"

    info "Building $platform_tag (target: $zig_target)..."

    # ── compile ──────────────────────────────────────────────────────────────
    # Environment:
    #   GROK_VERSION — baked into the binary at compile time
    #   CARGO_PROFILE_* — override profile settings for smaller binaries
    export GROK_VERSION="$VERSION"

    # For Windows GNU target, ensure static CRT linking.
    local extra_rustflags=""
    case "$rust_target" in
        *windows-gnu*)
            # Static CRT + strip exception tables for smaller binaries
            extra_rustflags="-C target-feature=+crt-static"
            ;;
    esac

    # Build the binary. We pass --profile release-dist for optimised LTO builds.
    # The .GLIBC suffix on the target tells cargo-zigbuild to pin glibc.
    if [ -n "$extra_rustflags" ]; then
        RUSTFLAGS="$RUSTFLAGS $extra_rustflags" \
            cargo zigbuild \
                --profile "$PROFILE" \
                --target "$zig_target" \
                -p xai-grok-pager-bin
    else
        cargo zigbuild \
            --profile "$PROFILE" \
            --target "$zig_target" \
            -p xai-grok-pager-bin
    fi

    # ── locate the built binary ──────────────────────────────────────────────
    # cargo-zigbuild puts output under target/<rust_target>/<profile>/
    local profile_dir="$PROFILE"
    # release-dist profile maps to target/.../release-dist/
    local bin_path="$REPO_ROOT/target/$rust_target/$profile_dir/$bin_artifact"

    [ -f "$bin_path" ] || die "Built binary not found at: $bin_path"

    local file_size
    file_size=$(du -h "$bin_path" | cut -f1)
    ok "Built $bin_artifact ($file_size) → $bin_path"

    # ── stage ────────────────────────────────────────────────────────────────
    local stage="$STAGE_DIR/$platform_tag"
    rm -rf "$stage"
    mkdir -p "$stage"

    cp "$bin_path" "$stage/$ship_artifact"

    # Optionally strip debug symbols for smaller distribution size.
    # release-dist keeps debug=1 (line tables) by default; stripping removes
    # them for end-user binaries. Debug sidecars can be extracted separately.
    if [ "${STRIP_BIN:-0}" = "1" ]; then
        case "$rust_target" in
            *windows*)
                # Use llvm-strip if available (comes with Rust toolchain)
                local strip_tool
                strip_tool=$(find "$(rustc --print sysroot)" -name 'llvm-strip' 2>/dev/null | head -1)
                if [ -n "$strip_tool" ] && [ -x "$strip_tool" ]; then
                    "$strip_tool" "$stage/$ship_artifact"
                    ok "Stripped debug symbols (llvm-strip)."
                else
                    warn "llvm-strip not found; skipping strip for Windows binary."
                fi
                ;;
            *linux*)
                if command -v strip >/dev/null 2>&1; then
                    strip "$stage/$ship_artifact" || warn "strip failed (non-fatal)."
                    ok "Stripped debug symbols (strip)."
                else
                    warn "strip not found; skipping."
                fi
                ;;
        esac
    fi

    # ── zip ──────────────────────────────────────────────────────────────────
    local zip_name="${PACKAGE_NAME}-${VERSION}-${platform_tag}.zip"
    local zip_path="$DIST_DIR/$zip_name"

    mkdir -p "$DIST_DIR"

    # Create zip from the staging directory so the archive contains only the
    # binary at the root level (no parent directory wrapper).
    (
        cd "$stage"
        rm -f "$zip_path"
        zip -j -X "$zip_path" "$ship_artifact"
    )

    local zip_size
    zip_size=$(du -h "$zip_path" | cut -f1)
    ok "Packaged: dist/$zip_name ($zip_size)"
}

# ─── main ────────────────────────────────────────────────────────────────────
main() {
    cd "$REPO_ROOT"

    check_prereqs
    ensure_rust_targets

    # Determine which targets to build
    local requested="${1:-all}"
    local to_build=()

    if [ "$requested" = "all" ]; then
        to_build=("${TARGETS[@]}")
    else
        # Filter targets by the requested platform tag
        for t in "${TARGETS[@]}"; do
            local tag="${t%%|*}"
            if [ "$tag" = "$requested" ]; then
                to_build=("$t")
                break
            fi
        done
        [ ${#to_build[@]} -gt 0 ] || die "Unknown target: $requested\nValid: linux-x86_64, linux-aarch64, windows-x86_64, all"
    fi

    info "Building ${#to_build[@]} target(s) for version $VERSION"

    # Build each target sequentially (parallel builds would contend for CPU).
    local built=()
    local failed=()
    for target_def in "${to_build[@]}"; do
        IFS='|' read -r tag zig_target rust_target bin_ext platform_tag <<< "$target_def"
        if build_target "$zig_target" "$rust_target" "$rust_target" "$bin_ext" "$platform_tag"; then
            built+=("$platform_tag")
        else
            failed+=("$platform_tag")
            warn "Build failed for $platform_tag (continuing to next target)..."
        fi
    done

    # ─── summary ─────────────────────────────────────────────────────────────
    echo "" >&2
    printf '%s══════════════════════════════════════════════════════%s\n' "$C_BOLD" "$C_RESET" >&2
    printf '%s  Grok %s — Build Summary%s\n' "$C_BOLD" "$VERSION" "$C_RESET" >&2
    printf '%s══════════════════════════════════════════════════════%s\n' "$C_BOLD" "$C_RESET" >&2
    for tag in "${built[@]}"; do
        local zip_file="${PACKAGE_NAME}-${VERSION}-${tag}.zip"
        if [ -f "$DIST_DIR/$zip_file" ]; then
            local sz; sz=$(du -h "$DIST_DIR/$zip_file" | cut -f1)
            printf '  %s✓%s  %-20s %s (%s)\n' "$C_GREEN" "$C_RESET" "$tag" "dist/$zip_file" "$sz" >&2
        fi
    done
    for tag in "${failed[@]}"; do
        printf '  %s✗%s  %-20s FAILED\n' "$C_RED" "$C_RESET" "$tag" >&2
    done
    printf '%s══════════════════════════════════════════════════════%s\n' "$C_BOLD" "$C_RESET" >&2

    [ ${#failed[@]} -eq 0 ] || die "${#failed[@]} target(s) failed."
    ok "All targets built successfully."
}

main "$@"
