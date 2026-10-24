import SwiftUI
import UniformTypeIdentifiers

struct DecryptionSettingsSection: View {
    @State private var service = DecryptionService.this
    @State private var importing = false
    @State private var errorMessage = ""
    @State private var showError = false

    var body: some View {
        Section {
            Label {
                if service.hasCredential {
                    Text("Credential imported")
                } else {
                    Text("No credential imported")
                }
            } icon: {
                Image(systemName: service.hasCredential ? "checkmark.shield" : "lock.shield")
            }
            Button("Import credential.bin") { importing = true }
            if service.hasCredential {
                Button("Remove Credential", role: .destructive) {
                    do {
                        try service.removeCredential()
                    } catch {
                        present(error)
                    }
                }
            }
        } header: {
            Text("FairPlay Decryption")
        } footer: {
            VStack(alignment: .leading) {
                Text("Import the 16-byte credential.bin for your IPA. It is stored in Keychain on this device, not synced. Decryption is disabled without a credential.")
                if let error = service.credentialError {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            do {
                try service.importCredential(from: result.get())
            } catch {
                present(error)
            }
        }
        .alert("Credential Import Failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}
