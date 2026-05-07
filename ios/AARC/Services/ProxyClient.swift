import Foundation

struct PingResponse: Decodable, Sendable {
    let ok: Bool
    let ts: Int
    let service: String
}

actor ProxyClient {
    static let shared = ProxyClient()

    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
    }

    func ping() async throws -> PingResponse {
        let url = Config.apiBaseURL.appendingPathComponent("ping")
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ProxyError.httpStatus(code)
        }
        return try decoder.decode(PingResponse.self, from: data)
    }
}

enum ProxyError: Error, LocalizedError {
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "HTTP \(code)"
        }
    }
}
