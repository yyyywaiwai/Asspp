import FairDecKit
import Foundation
import Observation

@Observable
@MainActor
final class DecryptionService {
    static let this = DecryptionService()

    @ObservationIgnored private let storage: PersistProvider
    private var credential: Data?
    private(set) var credentialError: String?

    var hasCredential: Bool { credential?.count == 16 }

    private static var invalidCredential: NSError {
        NSError(domain: "Asspp.Decryption", code: 1, userInfo: [
            NSLocalizedDescriptionKey: String(localized: "credential.bin must contain exactly 16 bytes."),
        ])
    }

    init(storage: PersistProvider = KeychainStorage(service: "wiki.qaq.Asspp.FairPlay", synchronizable: false)) {
        self.storage = storage
        do {
            if let data = try storage.data(forKey: "Credential") {
                guard data.count == 16 else { throw Self.invalidCredential }
                credential = data
            }
        } catch {
            credentialError = error.localizedDescription
        }
    }

    func importCredential(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 17) ?? Data()
        guard data.count == 16 else { throw Self.invalidCredential }
        try storage.set(data, forKey: "Credential")
        credential = data
        credentialError = nil
    }

    func removeCredential() throws {
        try storage.set(nil, forKey: "Credential")
        credential = nil
        credentialError = nil
    }

    func decrypt(_ package: PackageManifest) async throws -> URL {
        guard let credential, hasCredential else {
            throw Self.invalidCredential
        }
        guard package.completed, !package.isDecrypting else {
            throw CocoaError(.fileReadUnknown)
        }
        package.isDecrypting = true
        defer { package.isDecrypting = false }
        let input = package.targetLocation
        let output = package.decryptedLocation
        // Keep the installable original and perform the synchronous work off the main actor.
        return try await Task.detached(priority: .userInitiated) {
            try FairDecKit.decryptIPA(at: input, to: output, credential: credential, mode: .lowMemory)
        }.value
    }
}
