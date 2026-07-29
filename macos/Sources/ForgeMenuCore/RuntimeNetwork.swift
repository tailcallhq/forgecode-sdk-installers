import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public typealias RuntimeDownloadProgressHandler = @Sendable (_ receivedBytes: Int64, _ expectedBytes: Int64) async -> Void

public protocol RuntimeNetworkClient: Sendable {
    func download(
        _ request: RuntimeDownloadRequest,
        progress: @escaping RuntimeDownloadProgressHandler
    ) async throws -> RuntimeDownload
}

public extension RuntimeNetworkClient {
    func download(_ request: RuntimeDownloadRequest) async throws -> RuntimeDownload {
        try await download(request, progress: { _, _ in })
    }
}

public struct RuntimeDownloadRequest: Sendable, Equatable {
    public let url: URL
    public let maximumBytes: Int64
    public let requireContentLength: Bool
    public let maximumRedirects: Int

    public init(url: URL, maximumBytes: Int64, requireContentLength: Bool = true, maximumRedirects: Int = 3) {
        self.url = url
        self.maximumBytes = maximumBytes
        self.requireContentLength = requireContentLength
        self.maximumRedirects = maximumRedirects
    }
}

public struct RuntimeDownload: Sendable, Equatable {
    public let data: Data
    public let responseURL: URL

    public init(data: Data, responseURL: URL) {
        self.data = data
        self.responseURL = responseURL
    }
}

/// Production downloader. Tests inject a URLSessionConfiguration whose protocol
/// classes provide deterministic transport while exercising this exact client.
public final class URLSessionRuntimeNetworkClient: NSObject, RuntimeNetworkClient, @unchecked Sendable {
    private final class Delegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var redirectCount = 0
        private var redirectError: RuntimeInstallerError?
        let maximumRedirects: Int

        init(maximumRedirects: Int) {
            self.maximumRedirects = maximumRedirects
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            let error: RuntimeInstallerError? = lock.withLock {
                redirectCount += 1
                if redirectCount > maximumRedirects { return .tooManyRedirects }
                guard Self.isAllowed(request.url) else {
                    return .unsafeRedirect(request.url?.absoluteString ?? "<missing>")
                }
                return nil
            }
            if let error {
                lock.withLock { redirectError = error }
                completionHandler(nil)
            } else {
                completionHandler(request)
            }
        }

        func consumeRedirectError() -> RuntimeInstallerError? {
            lock.withLock {
                defer { redirectError = nil }
                return redirectError
            }
        }

        static func isAllowed(_ url: URL?) -> Bool {
            guard let url,
                  url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == RuntimeReleaseURLs.origin.host,
                  url.user == nil,
                  url.password == nil,
                  url.port == nil,
                  url.fragment == nil
            else { return false }
            return true
        }
    }

    private let baseConfiguration: URLSessionConfiguration
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval

    public override convenience init() {
        self.init(configuration: .ephemeral)
    }

    public init(
        configuration: URLSessionConfiguration,
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 120
    ) {
        baseConfiguration = configuration
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        super.init()
    }

    public func download(
        _ request: RuntimeDownloadRequest,
        progress: @escaping RuntimeDownloadProgressHandler
    ) async throws -> RuntimeDownload {
        guard request.maximumBytes > 0,
              request.maximumRedirects >= 0,
              Delegate.isAllowed(request.url)
        else { throw RuntimeInstallerError.invalidURL(request.url.absoluteString) }

        let delegate = Delegate(maximumRedirects: request.maximumRedirects)
        guard let configuration = baseConfiguration.copy() as? URLSessionConfiguration else {
            throw RuntimeInstallerError.network("could not create an isolated URL session")
        }
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            if let redirectError = delegate.consumeRedirectError() { throw redirectError }
            guard let response = response as? HTTPURLResponse else {
                throw RuntimeInstallerError.network("non-HTTP response")
            }
            guard response.statusCode == 200 else {
                throw RuntimeInstallerError.invalidHTTPStatus(response.statusCode)
            }
            guard Delegate.isAllowed(response.url) else {
                throw RuntimeInstallerError.unsafeRedirect(response.url?.absoluteString ?? "<missing>")
            }

            let declaredLength = try Self.validatedContentLength(
                response.value(forHTTPHeaderField: "Content-Length"),
                required: request.requireContentLength
            )
            if let declaredLength, declaredLength > request.maximumBytes {
                throw RuntimeInstallerError.responseTooLarge(limit: request.maximumBytes)
            }

            try Task.checkCancellation()
            var data = Data()
            if let declaredLength, declaredLength <= Int64(Int.max) {
                data.reserveCapacity(Int(declaredLength))
                await progress(0, declaredLength)
                try Task.checkCancellation()
            }
            var lastReportedBucket: Int64 = 0
            for try await byte in bytes {
                try Task.checkCancellation()
                guard Int64(data.count) < request.maximumBytes else {
                    throw RuntimeInstallerError.responseTooLarge(limit: request.maximumBytes)
                }
                data.append(byte)
                if let declaredLength {
                    let received = Int64(data.count)
                    guard received <= declaredLength else {
                        throw RuntimeInstallerError.invalidContentLength(
                            "declared \(declaredLength), received more than declared"
                        )
                    }
                    let bucket = min(100, received * 100 / max(1, declaredLength))
                    if bucket > lastReportedBucket || received == declaredLength {
                        lastReportedBucket = bucket
                        await progress(received, declaredLength)
                        try Task.checkCancellation()
                    }
                }
            }
            try Task.checkCancellation()
            if let declaredLength, declaredLength != Int64(data.count) {
                throw RuntimeInstallerError.invalidContentLength("declared \(declaredLength), received \(data.count)")
            }
            try Task.checkCancellation()
            return RuntimeDownload(data: data, responseURL: response.url ?? request.url)
        } catch is CancellationError {
            throw RuntimeInstallerError.cancelled
        } catch let error as RuntimeInstallerError {
            throw error
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw RuntimeInstallerError.cancelled
        } catch let error as URLError where error.code == .timedOut {
            if let redirectError = delegate.consumeRedirectError() { throw redirectError }
            throw RuntimeInstallerError.networkTimeout
        } catch {
            if let redirectError = delegate.consumeRedirectError() { throw redirectError }
            throw RuntimeInstallerError.network(error.localizedDescription)
        }
    }

    private static func validatedContentLength(_ value: String?, required: Bool) throws -> Int64? {
        guard let value else {
            if required { throw RuntimeInstallerError.missingContentLength }
            return nil
        }
        guard !value.isEmpty,
              value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let parsed = Int64(value)
        else { throw RuntimeInstallerError.invalidContentLength(value) }
        return parsed
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
