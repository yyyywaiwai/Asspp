#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
package="$root/Packages/StoreKBSync"
work="$root/build/KBSync"
commit=53471ef9cf480fab094bf13db3e5d2f9e2c30dc5
for tool in go cmake ninja xcodebuild xcbeautify; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
mkdir -p "$work" "$package/Frameworks"
python3 "$root/Resources/Scripts/prepare.kbsync.assets.py"
if [[ ! -d "$work/unicorn-tci/.git" ]]; then
    git clone --quiet https://github.com/Naville/unicorn.git "$work/unicorn-tci"
fi
git -C "$work/unicorn-tci" checkout --quiet "$commit"
[[ $(git -C "$work/unicorn-tci" rev-parse HEAD) == "$commit" ]]

build_slice() {
    local name=$1 sdk=$2 arch=$3 goos=$4 goarch=$5 triple=$6
    local output="$work/$name" sysroot compiler
    mkdir -p "$output/Headers"
    sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
    compiler=$(xcrun --sdk "$sdk" --find clang)
    local options=(-DCMAKE_OSX_SYSROOT="$sysroot" -DCMAKE_OSX_ARCHITECTURES="$arch"
        -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0)
    if [[ "$sdk" != macosx ]]; then
        options=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sysroot"
            -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0)
    fi
    cmake -S "$work/unicorn-tci" -B "$output/unicorn" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="-ffile-prefix-map=$root=." \
        -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$root=." -DBUILD_SHARED_LIBS=OFF -DUNICORN_ARCH=x86 \
        -DUNICORN_INTERPRETER=ON -DUNICORN_BUILD_TESTS=OFF -DUNICORN_INSTALL=OFF \
        "${options[@]}" > "$output/build.log" 2>&1
    # Upstream's merged archive lacks object dependencies; never reuse a stale merge.
    rm -f "$output/unicorn/libunicorn.a"
    cmake --build "$output/unicorn" --parallel 8 >> "$output/build.log" 2>&1
    (
        cd "$package/Native"
        env GOOS="$goos" GOARCH="$goarch" CGO_ENABLED=1 \
            CC="$compiler -target $triple -isysroot $sysroot" CGO_CFLAGS="-O2 -ffile-prefix-map=$root=." \
            go build -trimpath -buildmode=c-archive -o "$output/libStoreKBSyncNative.a" .
    ) >> "$output/build.log" 2>&1
    cp "$output/libStoreKBSyncNative.h" "$output/Headers/StoreKBSyncNative.h"
    printf 'module StoreKBSyncNative { header "StoreKBSyncNative.h" export * }\n' > "$output/Headers/module.modulemap"
    printf 'Built %s\n' "$name"
}

build_slice macos-arm64 macosx arm64 darwin arm64 arm64-apple-macos15.0
build_slice macos-x86_64 macosx x86_64 darwin amd64 x86_64-apple-macos15.0
build_slice ios-arm64 iphoneos arm64 ios arm64 arm64-apple-ios17.0
build_slice simulator-arm64 iphonesimulator arm64 ios arm64 arm64-apple-ios17.0-simulator
build_slice simulator-x86_64 iphonesimulator x86_64 ios amd64 x86_64-apple-ios17.0-simulator

for group in macos simulator; do
    mkdir -p "$work/$group"
    lipo -create "$work/$group-arm64/libStoreKBSyncNative.a" "$work/$group-x86_64/libStoreKBSyncNative.a" -output "$work/$group/libStoreKBSyncNative.a"
    lipo -create "$work/$group-arm64/unicorn/libunicorn.a" "$work/$group-x86_64/unicorn/libunicorn.a" -output "$work/$group/libunicorn.a"
done
rm -rf "$package/Frameworks/StoreKBSyncNative.xcframework" "$package/Frameworks/UnicornTCI.xcframework"
xcodebuild -create-xcframework \
    -library "$work/macos/libStoreKBSyncNative.a" -headers "$work/macos-arm64/Headers" \
    -library "$work/ios-arm64/libStoreKBSyncNative.a" -headers "$work/ios-arm64/Headers" \
    -library "$work/simulator/libStoreKBSyncNative.a" -headers "$work/simulator-arm64/Headers" \
    -output "$package/Frameworks/StoreKBSyncNative.xcframework" | xcbeautify
xcodebuild -create-xcframework \
    -library "$work/macos/libunicorn.a" -headers "$work/unicorn-tci/include" \
    -library "$work/ios-arm64/unicorn/libunicorn.a" -headers "$work/unicorn-tci/include" \
    -library "$work/simulator/libunicorn.a" -headers "$work/unicorn-tci/include" \
    -output "$package/Frameworks/UnicornTCI.xcframework" | xcbeautify
