#!/bin/sh
set -eu

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir="$source_dir/.build"
bundle="$build_dir/Windows File Launcher.app"
resources="$bundle/Contents/Resources"

mkdir -p "$bundle/Contents/MacOS" "$resources" "$build_dir/module-cache" "$build_dir/go-cache"
cp "$source_dir/Info.plist" "$bundle/Contents/Info.plist"

xcrun --sdk macosx swiftc -O -target arm64-apple-macosx14.0 \
    -module-cache-path "$build_dir/module-cache" \
    "$source_dir/Sources/WindowsFileLauncher.swift" \
    "$source_dir/Sources/WineLaunch.swift" \
    "$source_dir/Sources/WineRuntime.swift" \
    -o "$bundle/Contents/MacOS/WindowsFileLauncher"

build_wine_check() {
    GOCACHE="$build_dir/go-cache" CGO_ENABLED=0 GOOS=windows GOARCH="$1" \
        go build -trimpath -o "$resources/$2.exe" "$source_dir/Fixtures/WineCheck/main.go"
}

build_wine_check 386 WineTest32
build_wine_check amd64 WineTest64
codesign --force --sign - "$bundle"
printf '\nBuilt %s\n' "$bundle"
