import Foundation
import StoreKBSync

/// Session-only cache: generated account/device blobs are never written to disk or logged.
actor StoreKBSyncCache {
    static let shared = StoreKBSyncCache()
    struct Candidate: Sendable {
        let value: String
        let cached: Bool
    }
    private var accepted: [String: String] = [:]
    private var pending: [String: Task<String, Error>] = [:]

    private func key(guid: String, dsid: UInt64) -> String { "\(dsid):\(guid.uppercased())" }

    func value(guid: String, dsid: UInt64) async throws -> Candidate {
        let key = key(guid: guid, dsid: dsid)
        if let value = accepted[key] { return Candidate(value: value, cached: true) }
        let task: Task<String, Error>
        if let existing = pending[key] {
            task = existing
        } else {
            task = Task.detached(priority: .userInitiated) {
                try StoreKBSync.generate(guid: guid, dsid: dsid)
            }
            pending[key] = task
        }
        do {
            let value = try await task.value
            try Task.checkCancellation()
            return Candidate(value: value, cached: false)
        } catch {
            pending.removeValue(forKey: key)
            throw error
        }
    }

    func accept(_ value: String, guid: String, dsid: UInt64) {
        let key = key(guid: guid, dsid: dsid)
        accepted[key] = value
        pending.removeValue(forKey: key)
    }

    func invalidate(guid: String, dsid: UInt64) {
        let key = key(guid: guid, dsid: dsid)
        accepted.removeValue(forKey: key)
        pending.removeValue(forKey: key)
    }
}
