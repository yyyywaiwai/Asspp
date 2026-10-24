import ApplePackage
import Foundation

/// Download metadata transport. Keep Apple's raw bodies, cookies and signed
/// asset URLs out of both the Xcode console and the in-app log viewer.
enum StoreDownloadService {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_: URLSession, task _: URLSessionTask,
                        willPerformHTTPRedirection _: HTTPURLResponse,
                        newRequest _: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void)
        {
            completionHandler(nil)
        }
    }

    static func download(account: inout Account, package: AppStore.AppPackage) async throws -> DownloadOutput {
        let email = account.email
        return try await product(account: &account, package: package, version: package.externalVersionID, operation: "download") { item in
            try output(item: item, email: email)
        }
    }

    static func versions(account: inout Account, package: AppStore.AppPackage) async throws -> [String] {
        try await product(account: &account, package: package, version: nil, operation: "versions") { item in
            guard let metadata = item["metadata"] as? [String: Any],
                  let identifiers = metadata["softwareVersionExternalIdentifiers"] as? [Any]
            else { throw StoreDownloadError.noVersions }
            let versions = identifiers.map { StoreProtocol.string($0) }.filter { !$0.isEmpty }
            guard !versions.isEmpty else { throw StoreDownloadError.noVersions }
            return versions
        }
    }

    static func versionMetadata(account: inout Account, package: AppStore.AppPackage, versionID: String) async throws -> VersionMetadata {
        try await product(account: &account, package: package, version: versionID, operation: "version-metadata") { item in
            guard let metadata = item["metadata"] as? [String: Any],
                  let version = metadata["bundleShortVersionString"] as? String,
                  let dateString = metadata["releaseDate"] as? String,
                  let releaseDate = ISO8601DateFormatter().date(from: dateString)
            else { throw StoreDownloadError.invalidPackage }
            return VersionMetadata(displayVersion: version, releaseDate: releaseDate)
        }
    }

    private static func product<Result>(account: inout Account, package: AppStore.AppPackage, version: String?, operation: String, parse: ([String: Any]) throws -> Result) async throws -> Result {
        let trace = String(UUID().uuidString.prefix(8))
        let app = package.software
        let version = version.flatMap { $0.isEmpty ? nil : $0 }
        let platform = package.entityType ?? .iPhone
        logger.info("Store download [\(trace)]: operation=\(operation) app=\(app.id) platform=\(platform.rawValue) store=\(account.store) version=\(version ?? "latest")")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let region = Configuration.countryCode(for: account.store)
            let guid = Configuration.deviceIdentifier
            _ = try StoreDownloadProtocol.hardwareID(guid: guid)
            let dsid = try StoreDownloadProtocol.dsid(account.directoryServicesIdentifier)
            let effectiveVersion: String
            if let version {
                effectiveVersion = version
            } else {
                // Never let DownloadDispatch select another platform's build.
                guard let region else { throw StoreDownloadError.catalogUnavailable }
                let metadata = try await catalogVersion(session: session, appID: app.id, region: region, platform: platform, trace: trace)
                guard metadata.bundleID == nil || metadata.bundleID == app.bundleID else {
                    throw StoreDownloadError.catalogUnavailable
                }
                effectiveVersion = metadata.externalVersionID
            }
            logger.info("Store download [\(trace)]: pinned version=\(effectiveVersion)")
            for attempt in 0 ... 1 {
                try Task.checkCancellation()
                let candidate = try await StoreKBSyncCache.shared.value(guid: guid, dsid: dsid)
                logger.info("Store download [\(trace)]: kbsync ready cached=\(candidate.cached)")
                do {
                    let response = try await fetch(session: session, account: &account, appID: app.id,
                                                   guid: guid, version: effectiveVersion, kbsync: candidate.value, trace: trace)
                    if StoreDownloadProtocol.failureCode(response) == "9610" {
                        throw ApplePackageError.licenseRequired
                    }
                    let item = try StoreDownloadProtocol.packageItem(response, bundleID: app.bundleID, version: effectiveVersion)
                    let result = try parse(item)
                    await StoreKBSyncCache.shared.accept(candidate.value, guid: guid, dsid: dsid)
                    logger.info("Store download [\(trace)]: product metadata ready")
                    return result
                } catch {
                    try Task.checkCancellation()
                    await StoreKBSyncCache.shared.invalidate(guid: guid, dsid: dsid)
                    guard attempt == 0, candidate.cached,
                          StoreDownloadProtocol.shouldRefreshKBSync(error) else { throw error }
                    logger.info("Store download [\(trace)]: refreshing rejected cached kbsync once")
                }
            }
            throw StoreDownloadError.empty
        } catch {
            // localizedDescription and NSError.userInfo can contain Apple messages
            // or a credential-bearing URL. Log only the error type and numeric code.
            logger.error("Store download [\(trace)]: failed, \(StoreDiagnostics.errorSummary(error))")
            throw error
        }
    }

    private static func catalogVersion(session: URLSession, appID: Int64, region: String, platform: EntityType, trace: String) async throws -> StoreDownloadProtocol.CatalogVersion {
        var url = URLComponents(string: "https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup")!
        url.queryItems = [
            URLQueryItem(name: "version", value: "2"), URLQueryItem(name: "id", value: String(appID)),
            URLQueryItem(name: "p", value: "mdm-lockup"), URLQueryItem(name: "caller", value: "MDM"),
            URLQueryItem(name: "platform", value: platform == .appleTV ? "atv9" : "enterprisestore"),
            URLQueryItem(name: "cc", value: region.lowercased()), URLQueryItem(name: "l", value: "en"),
        ]
        var request = URLRequest(url: url.url!)
        request.setValue(Configuration.userAgent, forHTTPHeaderField: "User-Agent")
        // No credentials and no automatic redirects. Foundation verifies TLS in
        // Debug too (ApplePackage 1.2.7 disables verification in its Debug client).
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        logger.info("Store download [\(trace)]: catalog HTTP=\(status) bytes=\(data.count)")
        guard status == 200 else { throw StoreDownloadError.catalogUnavailable }
        return try StoreDownloadProtocol.catalogVersion(data, appID: appID)
    }

    private static func fetch(session: URLSession, account: inout Account, appID: Int64,
                              guid: String, version: String, kbsync: String, trace: String) async throws -> [String: Any]
    {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "downloaddispatch.itunes.apple.com"
        components.path = StoreDownloadProtocol.Endpoint.entDownload.path
        components.queryItems = [URLQueryItem(name: "guid", value: guid)]
        guard let candidate = components.url else { throw StoreDownloadError.invalidRedirect }
        let url = try StoreDownloadProtocol.validatedURL(candidate)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(
            fromPropertyList: StoreDownloadProtocol.entPayload(appID: appID, guid: guid, version: version, kbsync: kbsync),
            format: .xml, options: 0
        )
        for (name, value) in try StoreDownloadProtocol.entHeaders(store: account.store, token: account.passwordToken) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(account.directoryServicesIdentifier, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(account.directoryServicesIdentifier, forHTTPHeaderField: "X-Dsid")
        for (name, value) in account.cookie.buildCookieHeader(url) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        try Task.checkCancellation()
        logger.info("Store download [\(trace)]: endpoint=entDownload sessionCookie=\(request.value(forHTTPHeaderField: "Cookie") != nil)")
        // NoRedirect refuses even same-origin redirects: X-Token must never be forwarded.
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw StoreDownloadError.response(0) }
        mergeCookies(response: response, url: url, account: &account)
        logger.info("Store download [\(trace)]: endpoint=entDownload HTTP=\(response.statusCode) bytes=\(data.count)")
        guard ![301, 302, 303, 307, 308].contains(response.statusCode) else { throw StoreDownloadError.invalidRedirect }
        let plist = StoreProtocol.plist(data)
        if let plist { logger.info("Store download [\(trace)]: \(StoreDownloadProtocol.summary(plist))") }
        guard response.statusCode == 200, let plist else {
            if data.isEmpty { throw StoreDownloadError.emptyResponse(response.statusCode) }
            throw StoreDownloadError.response(response.statusCode)
        }
        return plist
    }

    private static func mergeCookies(response: HTTPURLResponse, url: URL, account: inout Account) {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, field in
            if let name = field.key as? String, let value = field.value as? String {
                result[name] = value
            }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
            let domain = StoreProtocol.storeCookieDomain(cookie.domain)
            account.cookie.removeAll { $0.name == cookie.name && $0.path == cookie.path && StoreProtocol.storeCookieDomain($0.domain) == domain }
            if let expiry = cookie.expiresDate, expiry <= Date() {
                continue
            }
            account.cookie.append(Cookie(name: cookie.name, value: cookie.value, path: cookie.path, domain: domain,
                                         expiresAt: cookie.expiresDate?.timeIntervalSince1970, httpOnly: cookie.isHTTPOnly, secure: cookie.isSecure))
        }
    }

    /// ApplePackage's DownloadOutput format, also consumed by SignatureInjector.
    private static func output(item: [String: Any], email: String) throws -> DownloadOutput {
        guard let url = item["URL"] as? String, let asset = URL(string: url),
              ["https", "http"].contains(asset.scheme), asset.host != nil,
              var metadata = item["metadata"] as? [String: Any],
              let version = metadata["bundleShortVersionString"] as? String,
              let build = metadata["bundleVersion"] as? String,
              let signatures = item["sinfs"] as? [[String: Any]], !signatures.isEmpty
        else { throw StoreDownloadError.invalidPackage }
        let sinfs = try signatures.map { signature -> Sinf in
            guard let id = signature["id"] as? Int64, let data = signature["sinf"] as? Data else {
                throw StoreDownloadError.invalidPackage
            }
            return Sinf(id: id, sinf: data)
        }
        metadata["apple-id"] = email
        metadata["userName"] = email
        return try DownloadOutput(downloadURL: url, sinfs: sinfs, bundleShortVersionString: version,
                                  bundleVersion: build, iTunesMetadata: PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0))
    }
}
