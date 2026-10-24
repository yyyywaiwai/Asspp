import CryptoKit
import Foundation
import Security
import ZIPFoundation

// The executable compiles the production service/storage without starting the app or using real accounts.
let documentsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("AssppChecks-\(UUID())")
struct CheckLogger { func error(_: String) {} }
let logger = CheckLogger()

final class MemoryStorage: PersistProvider {
    var data: Data?
    var failWrites = false
    func data(forKey _: String) -> Data? { data }
    func set(_ data: Data?, forKey _: String) throws {
        if failWrites { throw CocoaError(.fileWriteNoPermission) }
        self.data = data
    }
}

// Only the manifest fields consumed by the service; real manifest/UI compilation is checked by xcodebuild.
final class PackageManifest {
    var completed = true
    var isDecrypting = false
    let targetLocation: URL
    var decryptedLocation: URL { targetLocation.appendingPathExtension("decrypted.ipa") }
    init(_ url: URL) { targetLocation = url }
}

@main
struct DecryptionChecks {
    static func fails(_ body: () throws -> Void) {
        do { try body() } catch { return }
        preconditionFailure("Expected an error")
    }

    @MainActor
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--read-keychain" {
            let data = try KeychainStorage(service: CommandLine.arguments[2]).data(forKey: "test")
            precondition(data == Data([1, 2, 3]), "Keychain value did not survive a fresh process")
            return
        }
        let fm = FileManager.default
        let root = documentsDirectory
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let storage = MemoryStorage()
        let service = DecryptionService(storage: storage)
        let credential = root.appendingPathComponent("credential.bin")
        precondition(!service.hasCredential)
        for size in [0, 15, 17, 1024] {
            try Data(repeating: 0, count: size).write(to: credential)
            fails { try service.importCredential(from: credential) }
            precondition(!service.hasCredential && storage.data == nil)
        }
        let valid = Data(0..<16)
        try valid.write(to: credential)
        storage.failWrites = true
        fails { try service.importCredential(from: credential) }
        precondition(!service.hasCredential)
        storage.failWrites = false
        try service.importCredential(from: credential)
        precondition(service.hasCredential && storage.data == valid)
        precondition(DecryptionService(storage: storage).hasCredential)
        try Data([0]).write(to: credential)
        fails { try service.importCredential(from: credential) }
        precondition(service.hasCredential && storage.data == valid)
        storage.failWrites = true
        fails { try service.removeCredential() }
        precondition(service.hasCredential)
        storage.failWrites = false

        let package = PackageManifest(root.appendingPathComponent("fixture.ipa"))
        try makeIPA(at: package.targetLocation)
        let original = try Data(contentsOf: package.targetLocation)
        let output = try await service.decrypt(package)
        precondition(!package.isDecrypting)
        let archive = try Archive(url: output, accessMode: .read)
        var binary = Data()
        _ = try archive.extract(archive["Payload/Fixture.app/Fixture"]!) { binary.append($0) }
        precondition(Array(binary[48..<52]) == [0, 0, 0, 0], "cryptid must be zero")
        let expected = try fixture()["clear"] as! String
        precondition(SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined() == expected)
        let decrypted = try Data(contentsOf: output)
        do { _ = try await service.decrypt(package); preconditionFailure("Existing output was overwritten") } catch {}
        let preservedOutput = try Data(contentsOf: output)
        precondition(preservedOutput == decrypted && !package.isDecrypting)
        try fm.removeItem(at: output)
        try Data(repeating: 0xff, count: 16).write(to: credential)
        try service.importCredential(from: credential)
        do { _ = try await service.decrypt(package); preconditionFailure("Wrong credential was accepted") } catch {}
        let preservedInput = try Data(contentsOf: package.targetLocation)
        precondition(preservedInput == original && !package.isDecrypting)
        precondition(!fm.fileExists(atPath: output.path))
        try service.removeCredential()
        precondition(!service.hasCredential && storage.data == nil)
        do { _ = try await service.decrypt(package); preconditionFailure("Missing credential was accepted") } catch {}
        precondition(!fm.fileExists(atPath: output.path))
        storage.data = Data([1])
        let corrupt = DecryptionService(storage: storage)
        precondition(!corrupt.hasCredential && corrupt.credentialError != nil)

        try checkKeychain()
        print("Credential validation/persistence, decryption, cryptid, original/output protection and macOS Keychain checks passed.")
    }

    static func checkKeychain() throws {
        let service = "wiki.qaq.Asspp.Checks.\(UUID())"
        let store = KeychainStorage(service: service)
        defer { try? store.set(nil, forKey: "test") }
        try store.set(Data([1, 2, 3]), forKey: "test")
        let saved = try KeychainStorage(service: service).data(forKey: "test")
        precondition(saved == Data([1, 2, 3]))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--read-keychain", service]
        try child.run()
        child.waitUntilExit()
        precondition(child.terminationStatus == 0)
        try store.set(Data([4]), forKey: "test")
        let updated = try store.data(forKey: "test")
        precondition(updated == Data([4]))
        try store.set(nil, forKey: "test")
        let removed = try store.data(forKey: "test")
        precondition(removed == nil)
    }

    static func fixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FAIRDECKIT_REFERENCE"]!)
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return (reference["binaries"] as! [[String: Any]])[0]
    }

    static func hex(_ string: String) -> Data {
        let bytes = Array(string.utf8)
        return Data(stride(from: 0, to: bytes.count, by: 2).map {
            UInt8(String(bytes: bytes[$0..<$0 + 2], encoding: .utf8)!, radix: 16)!
        })
    }

    static func makeIPA(at url: URL) throws {
        let reference = try fixture()
        var source = hex(reference["header"] as! String)
        source.append(Data(repeating: 0, count: 4096 - source.count))
        source.append(hex(reference["ciphertext"] as! String))
        let archive = try Archive(url: url, accessMode: .create)
        for (name, data) in [
            ("Fixture", source),
            ("SC_Info/Fixture.sinf", hex(reference["sinf"] as! String)),
            ("SC_Info/Fixture.supf", hex(reference["supf"] as! String)),
            ("resource.txt", Data("preserved".utf8)),
        ] {
            try archive.addEntry(with: "Payload/Fixture.app/" + name, type: .file,
                                 uncompressedSize: Int64(data.count), compressionMethod: .deflate) { offset, size in
                data.subdata(in: Int(offset)..<Int(offset) + size)
            }
        }
    }
}
