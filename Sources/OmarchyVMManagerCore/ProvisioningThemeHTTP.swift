import DevVMProvisioningCore
import Foundation

/// Fresh, credential-free GET sessions. No cookies, cache, browser sign-in or
/// arbitrary destinations; redirects are checked before a request is followed.
struct ProvisioningThemeHTTP: ThemeHTTPFetching {
    var configuration: @Sendable () -> URLSessionConfiguration = { .ephemeral }
    static func allowed(_ url: URL) -> Bool {
        url == ThemeSelection.catalogueURL || (try? ThemeSelection.repository(url.absoluteString)) != nil
    }
    func get(_ url: URL, body: Bool) async throws -> ThemeHTTPResponse {
        guard Self.allowed(url) else { throw ThemeSelectionFailure.inaccessible }
        let configuration = self.configuration()
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 30
        let delegate = ThemeRedirectPolicy(origin: url.host)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"; request.httpShouldHandleCookies = false
        request.setValue("OmarchyVMManager-ThemeReview", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, let final = response.url, Self.allowed(final) else { throw ThemeSelectionFailure.inaccessible }
            var data = Data()
            if body, response.statusCode == 200 {
                for try await byte in bytes {
                    guard data.count < 2 * 1024 * 1024 else { throw ThemeSelectionFailure.responseTooLarge }
                    data.append(byte)
                }
            }
            try Task.checkCancellation()
            return .init(status: response.statusCode, url: final, data: data)
        } catch is CancellationError { throw CancellationError() }
        catch let error as ThemeSelectionFailure { throw error }
        catch { throw ThemeSelectionFailure.inaccessible }
    }
}
final class ThemeRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: String?
    private let lock = NSLock()
    private var redirects = 0
    init(origin: String?) { self.origin = origin }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(admit(request))
    }
    func admit(_ request: URLRequest) -> URLRequest? {
        let withinLimit = lock.withLock { redirects += 1; return redirects <= 5 }
        guard withinLimit, let url = request.url, url.host == origin, ProvisioningThemeHTTP.allowed(url) else { return nil }
        var clean = request; clean.httpMethod = "GET"; clean.httpShouldHandleCookies = false
        clean.setValue(nil, forHTTPHeaderField: "Authorization"); clean.setValue(nil, forHTTPHeaderField: "Cookie")
        return clean
    }
}
