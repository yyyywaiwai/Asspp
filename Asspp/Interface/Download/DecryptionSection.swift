import ButtonKit
import SwiftUI

struct DecryptionSection: View {
    let package: PackageManifest

    @State private var service = DecryptionService.this
    @State private var decryptedURL: URL?
    @State private var errorMessage = ""

    var body: some View {
        Section {
            AsyncButton {
                errorMessage = ""
                do {
                    decryptedURL = try await service.decrypt(package)
                } catch {
                    errorMessage = error.localizedDescription
                }
            } label: {
                Text("Decrypt IPA")
            }
            .disabledWhenLoading()
            .disabled(!service.hasCredential || package.isDecrypting || decryptedURL != nil)

            if package.isDecrypting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Decrypting IPA…")
                }
            }
            if let decryptedURL {
                ShareLink(item: decryptedURL) {
                    Label("Share Decrypted IPA", systemImage: "square.and.arrow.up")
                }
                #if os(macOS)
                    Button("Show Decrypted IPA in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([decryptedURL])
                    }
                #endif
            }
        } header: {
            Text("FairPlay Decryption")
        } footer: {
            VStack(alignment: .leading) {
                if !service.hasCredential {
                    Text("Import credential.bin in Settings to enable decryption.")
                }
                Text("The original IPA is preserved. Decrypted copies need signing before installation. Keep the app open until decryption finishes.")
                if !errorMessage.isEmpty {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .onAppear(perform: refreshOutput)
        .onChange(of: package.isDecrypting) { refreshOutput() }
    }

    private func refreshOutput() {
        decryptedURL = FileManager.default.fileExists(atPath: package.decryptedLocation.path)
            ? package.decryptedLocation : nil
    }
}
