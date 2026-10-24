# StoreKBSync

Local, statically linked kbsync generation for Asspp's `ent/download` requests.
A six-byte device GUID and numeric account DSID are processed on the device.
No password/token, remote generation service, JIT entitlement, helper process or
runtime executable download is required. The FairDecKit `credential.bin` is not
used by this protocol and remains a separate setting.

## Prepare before opening the Xcode workspace

Requires Xcode, Go 1.25+, CMake, Ninja and xcbeautify:

```sh
brew install go cmake ninja xcbeautify
bash Resources/Scripts/prepare.kbsync.sh
```

The script produces ignored XCFrameworks for macOS arm64/x86_64, iOS arm64 and
simulator arm64/x86_64. It also prepares five size/SHA-256 pinned Apple images
from a matching local cache or Apple's official OS X 10.9 update package. Only
those five paths are extracted; no credentials are involved in preparation.
Generated files are not committed. CI compile scripts prepare after their clean
step; do not run those destructive release scripts in a dirty working tree.

```sh
python3 Resources/Tests/KBSyncAssetChecks.py
(cd Packages/StoreKBSync/Native && go test ./...)
swift test --package-path Packages/StoreKBSync
```

The Swift smoke test uses synthetic identifiers, verifies real generation and
makes no network requests. Guest calls are bounded at two minutes, additionally
limited by a three-minute overall generation deadline. UI cancellation prevents
subsequent network requests; native work already in progress can continue until
its bound. Generation is serialized and happens off the main actor.

## Provenance and distribution

- The minimal StoreAgent/x86 runtime sources are adapted from
  [ipatool 3411d57f451f5111ae115641c22f7ed17bbd5fbe](https://github.com/majd/ipatool/tree/3411d57f451f5111ae115641c22f7ed17bbd5fbe/internal/sap)
  (MIT). Static function registration and bundled image loading replace its
  dynamic-library loader and runtime downloads.
- The interpreter is [Naville/unicorn feature/tci, 53471ef9cf480fab094bf13db3e5d2f9e2c30dc5](https://github.com/Naville/unicorn/tree/53471ef9cf480fab094bf13db3e5d2f9e2c30dc5),
  built with `UNICORN_INTERPRETER=ON` and only the x86 guest architecture. This
  profile uses TCI bytecode in non-executable memory, not a native-code JIT.
- Go dependencies and their checksums are pinned by `Native/go.mod` / `go.sum`.
  License texts are bundled in `Resources/Notices`.
- Apple runtime images remain Apple's software; the preparation URL, sizes and
  SHA-256 digests are recorded in `prepare.kbsync.assets.py` and checked again by
  the native loader before use.

**Distribution review is required:** Unicorn carries GPLv2 code, while purego
carries Apache-2.0 terms and the Apple images have separate proprietary terms.
This local integration does not establish license compatibility or redistribution
rights. Do not treat the combined application as MIT-only or assume an App Store
submission/distributed binary has been cleared. Upstream license notices and
reproducible source/build references are retained, not replaced by Asspp's license.
