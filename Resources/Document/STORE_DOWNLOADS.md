# Store downloads and diagnostics

## Preferred protocol

All three entry points (`download`, version history and version metadata) now use
`https://downloaddispatch.itunes.apple.com/WebObjects/DownloadDispatch.woa/wa/ent/download`.
The request matches the primary [ipatool implementation](https://github.com/majd/ipatool/blob/3411d57f451f5111ae115641c22f7ed17bbd5fbe/pkg/appstore/appstore_kbsync.go):
XML plist body, Configurator User-Agent, storefront and X-Token headers, DSID,
session cookies, device GUID, generated kbsync and a nine-byte encoded serial.

For latest downloads, catalog lookup first pins the current external version ID
for the selected platform/storefront. Historical requests retain their exact ID.
An unresolved catalog version stops the request rather than allowing the server
to choose an unrelated platform build. Package response bundle/version checks and
the main IPA's Info.plist platform/bundle checks run before signature injection.

`Packages/StoreKBSync` statically links a no-JIT interpreter and generates kbsync
locally, off the main actor. It works independently of FairDecKit's 16-byte
`credential.bin`; no decryption credential is needed to download encrypted IPAs.
See its README for preparation, pinned sources, notices and distribution caveats.
Successful blobs are cached only in memory, keyed by DSID + GUID. Concurrent
requests share generation. A cached blob rejected with HTTP 401/403 is discarded
and regenerated once. Fresh blobs, license errors, dialogs, redirect errors and
transport failures are not automatically retried. Passwords are never rotated
by download code. Account/license errors retain the explicit acquisition UI.

The authenticated session uses Foundation TLS verification even in Debug, no
ambient cookie jar/credential storage/cache and no redirects (including same-host
redirects). X-Token is never forwarded. Cookies set by Apple are merged into the
account for the existing persistence flow.

## Diagnostics

Xcode and Settings > Logs show `Store download [request ID]` entries with app ID,
platform, storefront, requested/pinned version, endpoint, HTTP status, response
size, item count, numeric error/status codes, and cache-hit booleans. Headers,
raw bodies, customer messages, emails, DSIDs, GUIDs, kbsync, signatures and signed
asset URLs are not logged. ApplePackage verbose logging stays disabled.

```sh
bash Resources/Scripts/check.downloads.sh
python3 Resources/Tests/KBSyncAssetChecks.py
swift test --package-path Packages/StoreKBSync
```

Protocol checks cover ent payload/types, the nine-byte serial, GUID/DSID/version
validation, header/redirect restrictions, bounded cache refresh classification,
response redaction and package validation. Legacy fallback helpers remain covered
as historical protocol regression fixtures; they are no longer the live transport.

## Live verification (2026-10-25)

Before this change, macOS volumeStore returned HTTP 200 with an empty songList;
redownload and a temporary update fallback both returned bodyless HTTP 403.
The user confirmed the same error after token rotation and an existing license.
Those results did not establish a service-wide outage.

With local kbsync + ent/download, the macOS app downloaded YouTube 21.42.4 to a
270,245,604-byte IPA. ZIP integrity, `com.google.ios.youtube`, `iPhoneOS` platform
and inserted SINF were verified. This proves the new download path for that
account/app, not every app, historical version, storefront or tvOS combination.

On iPad Air M2 (iPadOS 27.0.1), the signed device build was installed and the user
signed in and initiated the same download on the device. The completed IPA was
retrieved from that app's container and independently checked: 270,245,618 bytes,
YouTube 21.42.4, matching bundle ID and iPhoneOS platform, ZIP integrity passed,
and one SINF present. No Mac-generated kbsync or account export was supplied to
the iPad. Initial GUI automation readiness probes timed out; CoreDevice file
transfer and on-device user interaction provided the end-to-end evidence instead.

The asset preparation script was also exercised without using a local cache:
all five files fetched from Apple's official package matched their pinned sizes
and SHA-256 digests. Mac and signed iPad Debug builds passed. This does not verify
GitHub-hosted CI, redistributed release builds or App Store submission.

The macOS Version History screen also populated the current version and the
21.41.5 / 21.40.5 metadata through the shared service. Historical IPA transfers
were not performed. After verification, the final signed build (with deadline
bounds and notices) was reinstalled on the iPad without removing its app data.
