// URLSession async compatibility for Linux (swift-corelibs-foundation)

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(Linux)
extension URLSession {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Swift.Error>) in
            dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, let response = response {
                    continuation.resume(returning: (data, response))
                } else {
                    let unknownError = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse, userInfo: nil)
                    continuation.resume(throwing: unknownError)
                }
            }.resume()
        }
    }
}
#endif
