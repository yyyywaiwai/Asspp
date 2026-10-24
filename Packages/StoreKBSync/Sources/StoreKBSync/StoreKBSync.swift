import CStoreKBSync
import Darwin
import Foundation
import StoreKBSyncNative

/// Synchronous, CPU-intensive work. Call off the main actor; no JIT or network access is used.
public enum StoreKBSync {
    public static func generate(guid: String, dsid: UInt64) throws -> String {
        guard guid.utf8.count == 12, guid.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }), dsid != 0 else { throw NSError(domain: "Asspp.KBSync", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid device or account identifier"]) }
        guard let directory = Bundle.module.resourceURL?.appendingPathComponent("Assets") else {
            throw CocoaError(.fileNoSuchFile)
        }
        var failure: UnsafeMutablePointer<CChar>?
        let blob = directory.path.withCString { path in
            guid.withCString { guid in
                AssppGenerateKBSync(
                    UnsafeMutablePointer(mutating: path), UnsafeMutablePointer(mutating: guid), dsid,
                    UnsafeMutablePointer(mutating: StoreKBSyncUnicornAPI()), &failure
                )
            }
        }
        defer { free(failure); free(blob) }
        guard let blob else {
            throw NSError(domain: "Asspp.KBSync", code: 1, userInfo: [
                NSLocalizedDescriptionKey: failure.map { String(cString: $0) } ?? "kbsync generation failed",
            ])
        }
        let value = String(cString: blob)
        guard let decoded = Data(base64Encoded: value), !decoded.isEmpty, decoded.count <= 64 * 1024 else {
            throw CocoaError(.coderReadCorrupt)
        }
        return value
    }
}
