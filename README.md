# Asspp

**The Ultimate Multi-Region App Store Manager.**

Asspp is a powerful client designed for users who need to manage **multiple Apple IDs** across **different countries and regions**. Switch stores instantly, download apps from anywhere, and manage your IPA library—all without logging out of your device.

[简体中文 🇨🇳](./Resources/i18n/zh-Hans/README.md)

![Preview](./Resources/Screenshots/Apptisan_Asspp.png)

## ✨ Why Asspp?

- **🌍 Multi-Region Access**: Browse and search the US, Japan, China, or any other App Store region seamlessly. No more switching system accounts just to check an app.
- **👥 Multi-Account Support**: Add unlimited Apple IDs. Asspp automatically uses the correct account for the store you are browsing.
- **📦 IPA Management**: Download official, signed IPAs directly from Apple's servers for backup or sideloading.
- **⏪ History Versions**: Need an older version of an app? Asspp makes it easy to find and download previous releases.
- **📱 Cross-Platform**: Native experience on both **iOS** and **macOS**.

## 📥 Installation

### iOS

#### Option 1: Auto-Build & Sign (Recommended)

Fork this repository to automatically build and sign the app with your own developer certificate. This gives you a permanent **OTA installation link** that stays up-to-date with the latest changes.

👉 **[Setup Guide](./Resources/Document/FORK_AUTOBUILD_GUIDE.md)**

#### Option 2: Manual Install

1.  Download the latest `.ipa` from [Releases](https://github.com/Lakr233/Asspp/releases).
2.  Sign and install using your preferred tool (e.g., SideStore, AltStore, TrollStore, or other signing service).

### macOS

1.  Download the latest `.zip` from [Releases](https://github.com/Lakr233/Asspp/releases).
2.  Unzip and move `Asspp.app` to your Applications folder.
3.  **First Run and Trusting the App (Recommended)**:
    1.  Try double-clicking to open the app. If you see "App can’t be opened because the developer cannot be verified" or a similar message:
        - In Finder, locate `Asspp.app`, **Control-click** (or right-click) the app and choose **Open**, then click **Open** again in the dialog. This will create a one-time trust exception for the app.
    2.  If Control-clicking does not work or the app is still blocked:
        - Open **System Settings** -> **Privacy & Security** (or System Preferences -> Security & Privacy on older macOS). In the General/Security section, look for the blocked app and click **Open Anyway** or **Allow**. You may need to enter an administrator password.
    3.  Recommendation: Download from this repository's Releases and verify the release details to ensure the source is trusted before trusting and opening the app.

    > These steps follow macOS Gatekeeper practices and help minimize security risks while allowing you to run unsigned or self-signed apps.

## FairPlay decryption (iOS and macOS)

1. In **Settings → FairPlay Decryption**, import the matching 16-byte `credential.bin`.
2. Open a completed package in **Downloads** and select **Decrypt IPA**.
3. Use **Share Decrypted IPA** to export the copy; macOS also offers **Show Decrypted IPA in Finder**.

The credential is stored only in this device's Keychain, without iCloud synchronization.
Without a valid imported credential the decryption action is disabled. A 16-byte file still
needs to match the IPA; a mismatch reports an error without changing the original.
The original IPA remains the source for installation. Decrypted copies require separate
signing before installation and are removed together with their download. Keep Asspp open
while decryption runs. Processing uses [FairDecKit](https://github.com/yyyywaiwai/FairDecKit)
in low-memory mode; no external process or credential upload is involved.

Unsigned/ad-hoc macOS builds use the local login Keychain. Builds with a signing team and
Keychain access continue to use the synchronized Data Protection Keychain for accounts.
Changing signing identity/storage mode may require signing in again; existing items are not deleted.

Run the integration/storage checks after resolving the workspace packages:
`Resources/Scripts/check.decryption.sh` (or set `FAIRDECKIT_PATH` to a local FairDecKit checkout).

## 🛠 Requirements

- **iOS**: iOS 17.0 or later.
- **macOS**: macOS 15.0 or later.
- **Apple ID**: Required to communicate with App Store APIs.

## 🚨 Special Notice

Asspp utilizes the same underlying communication protocol as `ipatool`. According to community speculation (unverified), previous outages of this protocol were likely caused by:
1. Widespread usage triggering Apple's risk control mechanisms.
2. Protocol modifications following the patching of an iCloud security vulnerability.
3. Adjustments to Apple's front-end gateways, which now enforce stricter traffic allocation and request validation.

Given the increasingly strict management of these APIs, **if the protocol becomes invalid again in the future, this project may not be able to provide further fixes.**

**⚠️ Important Security Warnings:**
1. **Protect your GUID:** Please treat your device GUID as a highly sensitive password. Never share or leak it to anyone.
2. **Do NOT use your primary Apple ID:** We strongly advise using a secondary or burner account with this tool. If your account is banned by Apple, it could potentially result in an unremovable Activation Lock on your device (while there are no confirmed cases of this happening yet, we cannot make any guarantees).

## ⚠️ Disclaimer

This project is for educational and research purposes only. It is not affiliated with Apple Inc. Use at your own risk.

## 🥰 Acknowledgments

- [ipatool](https://github.com/majd/ipatool)
- [ipatool-ios](https://github.com/dlevi309/ipatool-ios)
- [localhost.direct](https://get.localhost.direct/)

_`ipatool-ios` and `localhost.direct` are no longer used in the project._

## 📄 License

MIT License. See [LICENSE](./LICENSE) for details.

## Sponsor

[LookInside](https://lookinside-app.com/) helps you inspect a running iOS or macOS app UI from your Mac.

---

Copyright © 2025 Lakr Aream. All Rights Reserved.

<img src="./Artworks/fable5.jpg" alt="Fable 5 Verified" width="240">

### Store download protocol / local build preparation

App Store downloads use `ent/download` with locally generated kbsync on macOS and
iOS. This does not require importing a FairDecKit decryption credential. Before
opening `Asspp.xcworkspace`, install Go/CMake/Ninja/xcbeautify and run:

```sh
bash Resources/Scripts/prepare.kbsync.sh
```

See [StoreKBSync](Packages/StoreKBSync/README.md) for pinned runtime sources,
checks and important dependency/Apple-image distribution licensing caveats, and
[download diagnostics](Resources/Document/STORE_DOWNLOADS.md) for the protocol.
