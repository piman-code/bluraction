#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
build_only=0
install_app=1
for arg in "$@"; do
    case "$arg" in
        --build-only) build_only=1 ;;
        --no-install) install_app=0 ;;
        *) printf 'Unknown option: %s (use --build-only or --no-install)\n' "$arg" >&2; exit 64 ;;
    esac
done
export CLANG_MODULE_CACHE_PATH="$repo_root/.build/clang-cache"
swift build --disable-sandbox --cache-path "$repo_root/.build/cache" -c release
binary_dir="$(swift build --disable-sandbox --cache-path "$repo_root/.build/cache" -c release --show-bin-path)"
bundle="$repo_root/.build/BlurAction.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_dir/BlurAction" "$bundle/Contents/MacOS/BlurAction"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
# Local ad-hoc signature; this does not publish or notarize the app.
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
plutil -lint "$bundle/Contents/Info.plist"
# Keep the project app the user actually opens in sync with the verified build.
# --build-only is useful while testing a candidate without replacing that app.
if [[ $build_only -eq 0 ]]; then
    target="$repo_root/BlurAction.app"
    staged="$(mktemp -d "$repo_root/.build/app-stage.XXXXXX")/BlurAction.app"
    ditto "$bundle" "$staged"
    codesign --verify --strict "$staged"
    backup="$repo_root/.build/backups/BlurAction-$(date '+%Y%m%d-%H%M%S')-$$.bundle-backup"
    mkdir -p "$(dirname "$backup")"
    swapped=0
    restore_on_failure() {
        status=$?
        trap - EXIT INT TERM
        if [[ $status -ne 0 && -e "$backup" ]]; then
            if [[ -e "$target" ]]; then
                mv "$target" "${backup}.failed-candidate" || exit 1
            fi
            mv "$backup" "$target" || exit 1
            codesign --verify --strict "$target" || exit 1
            printf '%s\n' "Build failed; restored previous app: $target" >&2
        elif [[ $status -ne 0 && $swapped -eq 1 && -e "$target" ]]; then
            mv "$target" "${backup}.failed-candidate" || exit 1
        fi
        exit "$status"
    }
    trap restore_on_failure EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ -e "$target" ]]; then mv "$target" "$backup"; fi
    mv "$staged" "$target"
    swapped=1
    rmdir "$(dirname "$staged")"
    codesign --verify --strict "$target"
    cmp "$bundle/Contents/MacOS/BlurAction" "$target/Contents/MacOS/BlurAction"
    cmp "$bundle/Contents/Info.plist" "$target/Contents/Info.plist"
    cmp "$bundle/Contents/Resources/AppIcon.icns" "$target/Contents/Resources/AppIcon.icns"
    trap - EXIT INT TERM
    printf '%s\n' "$target"
    # Also refresh /Applications so Spotlight and Launchpad open this build (skip with --no-install).
    # The previous copy moves to .build/backups; an unrelated app at that path is left alone.
    installed="/Applications/BlurAction.app"
    installed_id=""
    if [[ -e "$installed" ]]; then
        installed_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed/Contents/Info.plist" 2>/dev/null || true)"
    fi
    if [[ $install_app -eq 1 && -e "$installed" && "$installed_id" != "local.piman.BlurAction" ]]; then
        printf 'Not installed: %s is another app (%s)\n' "$installed" "${installed_id:-unknown}" >&2
    elif [[ $install_app -eq 1 ]]; then
        install_stage="$(mktemp -d "$repo_root/.build/install-stage.XXXXXX")"
        ditto "$bundle" "$install_stage/BlurAction.app"
        codesign --verify --strict "$install_stage/BlurAction.app"
        if [[ -e "$installed" ]]; then
            mv "$installed" "$repo_root/.build/backups/Applications-BlurAction-$(date '+%Y%m%d-%H%M%S')-$$.bundle-backup"
        fi
        mv "$install_stage/BlurAction.app" "$installed"
        rmdir "$install_stage"
        codesign --verify --strict "$installed"
        cmp "$bundle/Contents/MacOS/BlurAction" "$installed/Contents/MacOS/BlurAction"
        printf 'Installed: %s\n' "$installed"
    fi
else
    printf '%s\n' "$bundle"
fi
