# Shared, project-local Swift caches. Nothing is changed in the system toolchain.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift_build_flags=()
swift_compiler_flags=()

# Some Command Line Tools upgrades leave a Swift 5 private manifest interface
# beside the Swift 6 library. Prefer the matching public interface in that case.
manifest="$(xcode-select -p)/usr/lib/swift/pm/ManifestAPI"
interfaces="$manifest/PackageDescription.swiftmodule"
if [[ -f "$interfaces/arm64-apple-macos.private.swiftinterface" ]] &&
   grep -q 'swiftLanguageModes:' "$interfaces/arm64-apple-macos.swiftinterface" &&
   ! grep -q 'swiftLanguageModes:' "$interfaces/arm64-apple-macos.private.swiftinterface"; then
    export SWIFTPM_CUSTOM_LIBS_DIR="$PWD/.build/toolchain"
    mkdir -p "$SWIFTPM_CUSTOM_LIBS_DIR/ManifestAPI/PackageDescription.swiftmodule"
    cp "$interfaces/"*-apple-macos.swiftinterface "$SWIFTPM_CUSTOM_LIBS_DIR/ManifestAPI/PackageDescription.swiftmodule/"
    ln -sf "$manifest/libPackageDescription.dylib" "$SWIFTPM_CUSTOM_LIBS_DIR/ManifestAPI/libPackageDescription.dylib"
fi

stale_map="$(xcode-select -p)/usr/include/swift/module.modulemap"
if [[ -f "$stale_map" && -f "${stale_map:h}/bridging.modulemap" ]]; then
    # Hide only the obsolete duplicate header map through a local VFS overlay.
    python3 - "$stale_map" "$PWD/.build/toolchain" <<'PY'
import json, pathlib, sys
folder = pathlib.Path(sys.argv[2])
folder.mkdir(parents=True, exist_ok=True)
empty = folder / "empty.modulemap"
empty.write_text("")
(folder / "overlay.yaml").write_text(json.dumps({"version": 0, "roots": [
    {"type": "file", "name": sys.argv[1], "external-contents": str(empty)}
]}))
PY
    swift_compiler_flags=(-vfsoverlay "$PWD/.build/toolchain/overlay.yaml")
    swift_build_flags=(-Xswiftc -vfsoverlay -Xswiftc "$PWD/.build/toolchain/overlay.yaml")
fi
