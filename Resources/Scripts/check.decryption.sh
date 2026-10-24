#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
kit=${FAIRDECKIT_PATH:-"$root/build/SourcePackages/checkouts/FairDecKit"}
if [[ ! -f "$kit/Package.swift" ]]; then
    echo 'Resolve workspace packages into build/SourcePackages first, or set FAIRDECKIT_PATH.' >&2
    exit 1
fi
checks="$root/build/DecryptionChecks"
mkdir -p "$checks/Sources/DecryptionChecks"
cp "$root/Asspp/Extension/KeychainStorage.swift" \
   "$root/Asspp/Extension/PublishedPersist.swift" \
   "$root/Asspp/Backend/Downloader/DecryptionService.swift" \
   "$root/Resources/Tests/DecryptionChecks.swift" "$checks/Sources/DecryptionChecks/"
export FAIRDECKIT_REFERENCE="$kit/Tests/FairDecKitTests/Fixtures/reference.json"
export FAIRDECKIT_PACKAGE_PATH="$kit"
python3 - "$checks/Package.swift" <<'PY'
import json, os, sys
from pathlib import Path
path = json.dumps(os.environ['FAIRDECKIT_PACKAGE_PATH'])
Path(sys.argv[1]).write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "DecryptionChecks", platforms: [.macOS("15.0")], dependencies: [
    .package(name: "fairdeckit", path: KIT),
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
], targets: [.executableTarget(name: "DecryptionChecks", dependencies: [
    .product(name: "FairDecKit", package: "fairdeckit"),
    .product(name: "ZIPFoundation", package: "ZIPFoundation"),
])])
'''.replace('KIT', path))
PY
swift run --package-path "$checks" DecryptionChecks
python3 "$root/Resources/Tests/LocalizationChecks.py" \
    Asspp/Backend/Downloader/DecryptionService.swift \
    Asspp/Interface/Download/DecryptionSection.swift \
    Asspp/Interface/Setting/DecryptionSettingsSection.swift
