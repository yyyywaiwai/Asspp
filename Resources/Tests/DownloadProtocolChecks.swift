import Foundation

@main
struct DownloadProtocolChecks {
    static func main() async throws {
        let empty: [String: Any] = ["songList": [], "status": 0, "jingleDocType": "purchaseSuccess"]
        let success: [String: Any] = ["songList": [["metadata": ["softwareVersionBundleId": "example.app"]]]]
        var requests: [(StoreDownloadProtocol.Endpoint, String?)] = []
        var lookups = 0
        let result = try await StoreDownloadProtocol.fetchWithFallback(version: nil) { endpoint, version in
            requests.append((endpoint, version))
            return endpoint == .volumeStore ? empty : success
        } resolveVersion: {
            lookups += 1
            return "890598805"
        } onFallback: { precondition($0 == "empty-songList") }
        precondition(requests.count == 2 && requests[0].0 == .volumeStore && requests[0].1 == nil)
        precondition(requests[1].0 == .redownload && requests[1].1 == "890598805" && lookups == 1)
        _ = try StoreDownloadProtocol.packageItem(result, bundleID: "example.app")

        // Preserve historical IDs on both endpoints; numeric 5002 is retryable.
        requests = []
        _ = try await StoreDownloadProtocol.fetchWithFallback(version: "12345") { endpoint, version in
            requests.append((endpoint, version))
            return endpoint == .volumeStore ? ["failureType": 5002] : success
        } resolveVersion: { fatalError("Replaced the requested historical version") }
            onFallback: { precondition($0 == "failure-5002") }
        precondition(requests.count == 2 && requests.allSatisfy { $0.1 == "12345" })

        // An empty HTTP 500 from redownload gets one update request with the same version.
        requests = []
        _ = try await StoreDownloadProtocol.fetchWithFallback(version: "12345") { endpoint, version in
            requests.append((endpoint, version))
            switch endpoint {
            case .volumeStore: return empty
            case .redownload: throw StoreDownloadError.emptyResponse(500)
            case .update: return success
            case .entDownload: fatalError("Legacy fallback unexpectedly attempted ent/download")
            }
        } resolveVersion: { fatalError("Replaced the requested historical version") } onFallback: { _ in }
        precondition(requests.map(\.0) == [.volumeStore, .redownload, .update])
        precondition(requests.allSatisfy { $0.1 == "12345" })

        // Other failures do not qualify, and a failed update never loops.
        for failure in [StoreDownloadError.response(403), .response(500), .emptyResponse(503), .emptyResponse(403), .emptyResponse(500)] {
            requests = []
            do {
                _ = try await StoreDownloadProtocol.fetchWithFallback(version: "12345") { endpoint, version in
                    requests.append((endpoint, version))
                    if endpoint == .volumeStore {
                        return empty
                    }
                    throw failure
                } resolveVersion: { fatalError("Unexpected lookup") } onFallback: { _ in }
                fatalError("Ignored a failed download response")
            } catch {
                if case StoreDownloadError.emptyResponse(500) = failure {
                    precondition(requests.count == 3 && requests.last?.0 == .update)
                } else {
                    precondition(requests.count == 2)
                }
            }
        }

        // A 403 from the primary endpoint is not a redownload compatibility failure.
        requests = []
        do {
            _ = try await StoreDownloadProtocol.fetchWithFallback(version: "12345") { endpoint, version in
                requests.append((endpoint, version))
                throw StoreDownloadError.emptyResponse(403)
            } resolveVersion: { fatalError("Unexpected lookup") } onFallback: { _ in fatalError("Unexpected fallback") }
            fatalError("Ignored a primary endpoint rejection")
        } catch StoreDownloadError.emptyResponse(403) {}
        precondition(requests.count == 1)

        // A catalog failure never issues an unpinned fallback request.
        requests = []
        do {
            _ = try await StoreDownloadProtocol.fetchWithFallback(version: nil) { endpoint, version in
                requests.append((endpoint, version))
                return empty
            } resolveVersion: { throw StoreDownloadError.catalogUnavailable } onFallback: { _ in }
            fatalError("Ignored catalog failure")
        } catch StoreDownloadError.catalogUnavailable {}
        precondition(requests.count == 1)

        // Successful, rejected and malformed primary responses are not retried.
        for response in [success, ["failureType": "9610"], ["failureType": 2034],
                         ["metrics": ["messageCode": 2042]], ["customerMessage": "Unavailable"],
                         ["songList": [], "dialog": ["kind": "authorization"]],
                         ["action": ["url": "https://example.invalid/termsPage"]],
                         ["status": -1], ["songList": "malformed"]]
        {
            requests = []
            _ = try await StoreDownloadProtocol.fetchWithFallback(version: nil) { endpoint, version in
                requests.append((endpoint, version))
                return response
            } resolveVersion: { fatalError("Unexpected catalog request") }
                onFallback: { _ in fatalError("Unexpected fallback") }
            precondition(requests.count == 1)
        }

        // Even when both endpoints are empty, there is no retry loop.
        requests = []
        let stillEmpty = try await StoreDownloadProtocol.fetchWithFallback(version: "123") { endpoint, version in
            requests.append((endpoint, version))
            return empty
        } resolveVersion: { fatalError("Unexpected lookup") } onFallback: { _ in }
        precondition(requests.count == 2)
        do {
            _ = try StoreDownloadProtocol.packageItem(stillEmpty, bundleID: "example.app")
            fatalError("Accepted an empty package list")
        } catch StoreDownloadError.empty {}
        do {
            _ = try StoreDownloadProtocol.packageItem(success, bundleID: "other.app")
            fatalError("Accepted another app's package")
        } catch StoreDownloadError.invalidPackage {}
        do {
            _ = try StoreDownloadProtocol.packageItem(["failureType": 9610, "customerMessage": "License required"], bundleID: "example.app")
            fatalError("Lost numeric failure code")
        } catch StoreDownloadError.rejected("9610", "License required") {}

        for endpoint in [StoreDownloadProtocol.Endpoint.volumeStore, .redownload, .update] {
            let data = try PropertyListSerialization.data(fromPropertyList: StoreDownloadProtocol.payload(endpoint: endpoint, appID: 123,
                                                                                                          guid: "synthetic", version: "456"), format: .xml, options: 0)
            let payload = StoreProtocol.plist(data)!
            precondition(payload[endpoint.versionKey] as? String == "456")
            precondition(payload[endpoint == .volumeStore ? "appExtVrsId" : "externalVersionId"] == nil)
            precondition(payload["salableAdamId"] as? Int64 == 123)
            precondition(payload["creditDisplay"] as? String == "" && payload["guid"] as? String == "synthetic")
            precondition(payload["serialNumber"] as? String == "0" && payload["kbsync"] == nil && payload.count == 5)
            for version in [nil, ""] as [String?] {
                let unpinned = StoreDownloadProtocol.payload(endpoint: endpoint, appID: 123, guid: "synthetic", version: version)
                precondition(unpinned.count == 4 && unpinned[endpoint.versionKey] == nil)
                precondition(unpinned["salableAdamId"] as? Int64 == 123 && unpinned["serialNumber"] as? String == "0")
            }
        }

        let guid = "001122334455"
        let kbsync = "AAEC/v8=" // Serialization fixture only; not a generated kbsync credential.
        let hardwareID = try StoreDownloadProtocol.hardwareID(guid: guid)
        precondition(hardwareID == Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55]))
        let mixedCaseID = try StoreDownloadProtocol.hardwareID(guid: "aAbBcCdDeEfF")
        precondition(mixedCaseID == Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
        let zeroID = try StoreDownloadProtocol.hardwareID(guid: "000000000000")
        precondition(zeroID == Data(repeating: 0, count: 6))
        for invalid in ["", "00", "0011223344", "00112233445", "0011223344556", "00112233445566",
                        "00112233445g", "+11122334455", "00:11:22:33:44:55", " 001122334455",
                        "001122334455\n", "００１１２２３３４４５５"]
        {
            do {
                _ = try StoreDownloadProtocol.hardwareID(guid: invalid)
                fatalError("Accepted an invalid six-byte GUID")
            } catch StoreDownloadProtocol.EntRequestError.invalidGUID {}
            do {
                _ = try StoreDownloadProtocol.entPayload(appID: 123, guid: invalid, version: "456", kbsync: kbsync)
                fatalError("Built an ent payload with an invalid GUID")
            } catch StoreDownloadProtocol.EntRequestError.invalidGUID {}
        }
        for (text, expected) in [("1", UInt64(1)), ("000123", UInt64(123)), ("18446744073709551615", UInt64.max)] {
            let value = try StoreDownloadProtocol.dsid(text)
            precondition(value == expected)
        }
        for invalid in ["", "0", "000", "-1", "+1", "1.0", "1e3", "0x10", " 1", "1 ", "1\n", "１",
                        "18446744073709551616"]
        {
            do {
                _ = try StoreDownloadProtocol.dsid(invalid)
                fatalError("Accepted an invalid, zero or overflowing DSID")
            } catch StoreDownloadProtocol.EntRequestError.invalidDSID {}
        }

        // XML plist values are strings, including app/version IDs and both base64 fields.
        let entPayload = try StoreDownloadProtocol.entPayload(appID: 123, guid: guid, version: "456", kbsync: kbsync)
        let entData = try PropertyListSerialization.data(fromPropertyList: entPayload, format: .xml, options: 0)
        let ent = StoreProtocol.plist(entData)!
        precondition(ent as? [String: String] == [
            "creditDisplay": "", "guid": guid, "salableAdamId": "123", "externalVersionId": "456",
            "serialNumber": "VMiwqYgiM0RV", "kbsync": kbsync,
        ])
        let serial = Data(base64Encoded: ent["serialNumber"] as! String)!
        precondition(serial.count == 9)
        precondition(serial == Data([0x54, 0xC8, 0xB0, 0xA9, 0x88, 0x22, 0x33, 0x44, 0x55]))
        precondition(StoreDownloadProtocol.Endpoint.entDownload.versionKey == "externalVersionId")
        for blob in ["AA==", "AAE=", "AAEC", kbsync] {
            let payload = try StoreDownloadProtocol.entPayload(appID: Int64.max, guid: "aAbBcCdDeEfF", version: "000456", kbsync: blob)
            precondition(payload["kbsync"] as? String == blob && payload["guid"] as? String == "aAbBcCdDeEfF")
            precondition(payload["externalVersionId"] as? String == "000456" && payload["salableAdamId"] as? String == String(Int64.max))
        }
        for invalid in [Int64(0), -1, .min] {
            do {
                _ = try StoreDownloadProtocol.entPayload(appID: invalid, guid: guid, version: "456", kbsync: kbsync)
                fatalError("Accepted an invalid ent app ID")
            } catch StoreDownloadProtocol.EntRequestError.invalidAppID {}
        }
        for invalid in ["", "0", "000", "latest", "1.2.3", "+456", "-456", " 456", "456 ", "456\n", "４５６"] {
            do {
                _ = try StoreDownloadProtocol.entPayload(appID: 123, guid: guid, version: invalid, kbsync: kbsync)
                fatalError("Accepted an unpinned or invalid ent version")
            } catch StoreDownloadProtocol.EntRequestError.invalidVersion {}
        }
        for invalid in ["", " ", "\n", "not base64!", "AQID\n", "AAE", "AQID=", "AB==", "_-8="] {
            do {
                _ = try StoreDownloadProtocol.entPayload(appID: 123, guid: guid, version: "456", kbsync: invalid)
                fatalError("Accepted an empty, malformed or noncanonical kbsync string")
            } catch StoreDownloadProtocol.EntRequestError.invalidKBSync {}
        }
        // The limit applies to decoded bytes, not the longer base64 string.
        for size in [64 * 1024 - 1, 64 * 1024] {
            let blob = Data(repeating: 0xA5, count: size).base64EncodedString()
            let payload = try StoreDownloadProtocol.entPayload(appID: 123, guid: guid, version: "456", kbsync: blob)
            precondition(payload["kbsync"] as? String == blob)
        }
        do {
            let oversized = Data(repeating: 0xA5, count: 64 * 1024 + 1).base64EncodedString()
            _ = try StoreDownloadProtocol.entPayload(appID: 123, guid: guid, version: "456", kbsync: oversized)
            fatalError("Accepted a kbsync blob larger than 64 KiB")
        } catch StoreDownloadProtocol.EntRequestError.invalidKBSync {}

        for status in 100 ... 599 {
            let expected = status == 401 || status == 403
            precondition(StoreDownloadProtocol.shouldRefreshKBSync(StoreDownloadError.response(status)) == expected)
            precondition(StoreDownloadProtocol.shouldRefreshKBSync(StoreDownloadError.emptyResponse(status)) == expected)
        }
        for error in [
            StoreDownloadError.invalidRedirect, StoreDownloadError.invalidPackage, StoreDownloadError.empty,
            StoreDownloadError.catalogUnavailable, StoreDownloadError.actionRequired, StoreDownloadError.noVersions,
            StoreDownloadError.response(0), StoreDownloadError.emptyResponse(0),
            StoreDownloadError.rejected("401", ""), StoreDownloadError.rejected("403", ""),
            StoreDownloadProtocol.EntRequestError.invalidKBSync,
            NSError(domain: "synthetic", code: 401), NSError(domain: "synthetic", code: 403),
            URLError(.notConnectedToInternet), CancellationError(),
        ] as [Error] {
            precondition(!StoreDownloadProtocol.shouldRefreshKBSync(error))
        }
        let headers = try StoreDownloadProtocol.entHeaders(store: "143462-1,32", token: "TOKEN")
        precondition(headers == [
            "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
            "User-Agent": "Configurator/2.18 (Macintosh; OS X 15.3.2; 24D81) AppleWebKit/0620.2.4.11.6",
            "X-Apple-Store-Front": "143462-1,32", "X-Token": "TOKEN",
        ])
        for invalid in ["", " ", "TOKEN\r\nX-Other: value", "TOKEN\0", "TOKEN\t", "TOKEN\u{7F}", "ＴＯＫＥＮ"] {
            for (store, token) in [(invalid, "TOKEN"), ("143462-1,32", invalid)] {
                do {
                    _ = try StoreDownloadProtocol.entHeaders(store: store, token: token)
                    fatalError("Accepted empty or injectable ent headers")
                } catch StoreDownloadProtocol.EntRequestError.invalidHeaders {}
            }
        }

        let primary = "https://p25-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"
        for url in [primary, "https://downloaddispatch.itunes.apple.com/r/redownload?guid=fixture",
                    "https://downloaddispatch.itunes.apple.com/up/updateProduct?guid=fixture",
                    "https://p71-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/redownloadProduct"]
        {
            _ = try StoreDownloadProtocol.validatedURL(URL(string: url)!)
        }
        for url in [primary.replacingOccurrences(of: "https:", with: "http:"),
                    primary.replacingOccurrences(of: "p25-buy.itunes.apple.com", with: "p25-buy.itunes.apple.com.attacker.invalid"),
                    primary.replacingOccurrences(of: "p25-buy.", with: "user:password@p25-buy."),
                    primary.replacingOccurrences(of: "/wa/volumeStoreDownloadProduct", with: "/wa/buyProduct"),
                    primary + "#fragment", primary.replacingOccurrences(of: ".com/", with: ".com:8080/")]
        {
            do {
                _ = try StoreDownloadProtocol.validatedURL(URL(string: url)!)
                fatalError("Accepted a credential redirect outside the download endpoints")
            } catch StoreDownloadError.invalidRedirect {}
        }

        let entURL = "https://downloaddispatch.itunes.apple.com/WebObjects/DownloadDispatch.woa/wa/ent/download"
        precondition(StoreDownloadProtocol.Endpoint.entDownload.path == "/WebObjects/DownloadDispatch.woa/wa/ent/download")
        for url in [entURL, entURL + "?guid=" + guid, entURL + "?guid=aAbBcCdDeEfF"] {
            let validated = try StoreDownloadProtocol.validatedURL(URL(string: url)!)
            precondition(validated.absoluteString == url)
        }
        for url in [entURL.replacingOccurrences(of: "https:", with: "http:"),
                    entURL.replacingOccurrences(of: "downloaddispatch.itunes.apple.com", with: "buy.itunes.apple.com"),
                    entURL.replacingOccurrences(of: "downloaddispatch.itunes.apple.com", with: "p25-buy.itunes.apple.com"),
                    entURL.replacingOccurrences(of: ".com/", with: ".com.attacker.invalid/"),
                    entURL.replacingOccurrences(of: "//downloaddispatch", with: "//user:password@downloaddispatch"),
                    entURL.replacingOccurrences(of: ".com/", with: ".com:8080/"),
                    entURL.replacingOccurrences(of: ".com/", with: ".com:443/"),
                    entURL.replacingOccurrences(of: "/ent/download", with: "/ent/%64ownload"),
                    entURL.replacingOccurrences(of: "//downloaddispatch", with: "//%64ownloaddispatch"),
                    entURL.replacingOccurrences(of: "/WebObjects/DownloadDispatch.woa/wa", with: ""),
                    entURL + "/", entURL + "#fragment", entURL + "#", entURL + "?", entURL + "?guid",
                    entURL + "?guid=", entURL + "?guid=fixture", entURL + "?guid=00112233445", entURL + "?guid=00112233445566",
                    entURL + "?guid=00112233445g", entURL + "?guid=" + guid + "&guid=" + guid,
                    entURL + "?guid=" + guid + "&X-Token=TOKEN", entURL + "?token=TOKEN",
                    entURL + "?g%75id=" + guid, entURL + "?guid=%30" + guid.dropFirst(),
                    entURL + "?guid=" + guid + "%0A"]
        {
            do {
                _ = try StoreDownloadProtocol.validatedURL(URL(string: url)!)
                fatalError("Accepted an unsafe ent destination, path or query")
            } catch StoreDownloadError.invalidRedirect {}
        }

        // No ent redirect is permitted, even to itself or another allowlisted endpoint.
        let entRequestURL = URL(string: entURL + "?guid=" + guid)!
        let redownloadURL = URL(string: "https://downloaddispatch.itunes.apple.com/r/redownload?guid=fixture")!
        for destination in [entRequestURL, URL(string: entURL)!, URL(string: entURL + "?guid=FFEEDDCCBBAA")!,
                            URL(string: primary)!, redownloadURL,
                            URL(string: "https://downloaddispatch.itunes.apple.com/up/updateProduct")!,
                            URL(string: "https://example.invalid/collect")!]
        {
            do {
                _ = try StoreDownloadProtocol.validatedURL(destination, redirectFrom: entRequestURL)
                fatalError("Forwarded X-Token through an ent redirect")
            } catch StoreDownloadError.invalidRedirect {}
        }
        for source in [URL(string: primary)!, redownloadURL] {
            do {
                _ = try StoreDownloadProtocol.validatedURL(entRequestURL, redirectFrom: source)
                fatalError("Redirected legacy credentials into ent/download")
            } catch StoreDownloadError.invalidRedirect {}
        }
        let legacyRedirect = try StoreDownloadProtocol.validatedURL(redownloadURL, redirectFrom: URL(string: primary)!)
        precondition(legacyRedirect == redownloadURL)

        // Unknown fields and sensitive values must never reach diagnostic logs.
        let secret = "SECRET-user@example.invalid-cookie-token-url"
        let summary = StoreDownloadProtocol.summary([
            "songList": [["URL": secret, "sinfs": [secret]]], "failureType": secret,
            "customerMessage": secret, "passwordToken": secret, "dialog": ["message": secret],
            "status": secret, secret: secret,
        ])
        precondition(!summary.contains(secret) && summary.contains("songList=1") && summary.contains("failure=other"))
        precondition(StoreDownloadProtocol.fallbackReason(["metrics": ["messageCode": 0]]) == "missing-songList")
        // Catalog IDs accept both current offer shapes, never another app's entry.
        func catalog(_ offers: [[String: Any]], id: String = "123") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["results": [id: ["bundleId": "example.app", "offers": offers]]])
        }
        for offers in [[["version": ["externalId": 456]]],
                       [["version": ["externalId": "456"]]],
                       [["buyParams": "price=0&appExtVrsId=456"]],
                       [["version": ["externalId": "invalid"]], ["buyParams": "appExtVrsId=456"]]]
        {
            let version = try StoreDownloadProtocol.catalogVersion(catalog(offers), appID: 123)
            precondition(version.externalVersionID == "456" && version.bundleID == "example.app")
        }
        for data in try [catalog([]), catalog([["buyParams": "appExtVrsId=secret%20value"]]),
                         catalog([["version": ["externalId": 456]]], id: "999")]
        {
            do {
                _ = try StoreDownloadProtocol.catalogVersion(data, appID: 123)
                fatalError("Accepted missing or invalid catalog data")
            } catch StoreDownloadError.catalogUnavailable {}
        }
        do {
            _ = try StoreDownloadProtocol.packageItem(["songList": "invalid"], bundleID: "example.app")
            fatalError("Misclassified a malformed song list")
        } catch StoreDownloadError.invalidPackage {}
        do {
            _ = try StoreDownloadProtocol.packageItem(["songList": [["metadata": [
                "softwareVersionBundleId": "example.app", "softwareVersionExternalIdentifier": 456,
            ]]]], bundleID: "example.app", version: "123")
            fatalError("Accepted a different historical version")
        } catch StoreDownloadError.invalidPackage {}

        // Ignore extension/Watch metadata; validate the main IPA's actual platform.
        precondition(StoreDownloadProtocol.isMainInfoPlist("Payload/Example.app/Info.plist"))
        for path in ["Payload/Example.app/Watch/Watch.app/Info.plist", "Payload/Example.app/PlugIns/Widget.appex/Info.plist",
                     "Payload/../Info.plist", "Payload//Example.app/Info.plist", "Info.plist"]
        {
            precondition(!StoreDownloadProtocol.isMainInfoPlist(path))
        }
        for info in [
            ["CFBundleIdentifier": "example.app", "CFBundleSupportedPlatforms": ["iPhoneOS"]],
            ["CFBundleIdentifier": "example.app", "DTPlatformName": "iphoneos"],
        ] as [[String: Any]] {
            try StoreDownloadProtocol.validatePackageInfo(info, bundleID: "example.app", platform: "iPhoneOS")
        }
        for info in [
            ["CFBundleIdentifier": "other.app", "CFBundleSupportedPlatforms": ["iPhoneOS"]],
            ["CFBundleIdentifier": "example.app", "CFBundleSupportedPlatforms": ["AppleTVOS"]],
            ["CFBundleIdentifier": "example.app"],
        ] as [[String: Any]] {
            do {
                try StoreDownloadProtocol.validatePackageInfo(info, bundleID: "example.app", platform: "iPhoneOS")
                fatalError("Accepted mismatched or missing package identity")
            } catch StoreDownloadError.invalidPackage {}
        }
        let error = NSError(domain: secret, code: 403, userInfo: [NSLocalizedDescriptionKey: secret, NSURLErrorKey: secret])
        precondition(!StoreDiagnostics.errorSummary(error).contains(secret))
        print("Download protocol regression checks passed.")
    }
}
