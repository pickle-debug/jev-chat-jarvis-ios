import Alamofire
import Foundation
import os

/// 三路模型请求的统一出口：Alamofire Session、超时、受限重试、
/// 跨域重定向剥离 Authorization、以及不含密钥和聊天内容的日志。
final class JarvisAPIClient {
    static let shared = JarvisAPIClient()

    private let session: Session
    private let log = Logger(subsystem: "com.heself.jev-chat-jarvis-ios", category: "api")

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.httpAdditionalHeaders = nil
        session = Session(
            configuration: configuration,
            interceptor: BusyRetrier(),
            redirectHandler: AuthStrippingRedirectHandler()
        )
    }

    /// POST 一个 JSON body，解析成 `Response`。
    ///
    /// - Parameter key: 该路线自己的密钥；调用方负责取对，这里不做跨路线回退。
    func post<Body: Encodable, Response: Decodable>(
        route: APIRoute,
        urlString: String,
        key: String,
        body: Body,
        as responseType: Response.Type
    ) async throws -> Response {
        guard let url = URL(string: urlString), let scheme = url.scheme else {
            throw APIError(route: route, status: nil, detail: "接口地址无效：\(urlString)")
        }
        guard scheme.lowercased() == "https" else {
            throw APIError(route: route, status: nil, detail: "接口地址必须使用 HTTPS")
        }
        guard !key.isEmpty else {
            throw APIError(route: route, status: nil, detail: "尚未配置该路线的 API Key")
        }

        var headers: HTTPHeaders = [
            "Authorization": "Bearer \(key)",
            "Content-Type": "application/json"
        ]
        // OpenRouter 要求归属头；其他服务商会忽略未知头，但没必要发。
        if url.host?.lowercased().hasSuffix("openrouter.ai") == true {
            headers.add(name: "HTTP-Referer", value: "https://jev-assistant.local")
            headers.add(name: "X-Title", value: "Jarvis")
        }

        let started = Date()
        let response = await session
            .request(url, method: .post, parameters: body, encoder: .json, headers: headers)
            .validate()
            .serializingDecodable(Response.self, decoder: Self.decoder)
            .response
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let status = response.response?.statusCode

        switch response.result {
        case .success(let value):
            log.info("\(route.rawValue, privacy: .public) ok status=\(status ?? 0) \(elapsed)ms")
            return value
        case .failure(let error):
            let apiError = Self.describe(error, route: route, status: status, data: response.data)
            log.warning("\(route.rawValue, privacy: .public) fail status=\(status ?? 0) \(elapsed)ms kind=\(Self.kind(of: error), privacy: .public)")
            throw apiError
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    /// 错误文案要能指向修复动作，同时不泄露密钥或聊天内容。
    private static func describe(
        _ error: AFError,
        route: APIRoute,
        status: Int?,
        data: Data?
    ) -> APIError {
        if let status, !(200..<300).contains(status) {
            let snippet = data.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hint: String
            switch status {
            case 401, 403: hint = "密钥无效或无权限"
            case 404: hint = "接口地址或模型不存在"
            case 429: hint = "请求过于频繁"
            default: hint = snippet.isEmpty ? "（响应体为空）" : snippet
            }
            return APIError(route: route, status: status, detail: snippet.isEmpty ? hint : "\(hint)：\(snippet)")
        }

        if case .responseSerializationFailed = error {
            return APIError(route: route, status: status, detail: "响应格式不符合预期，请检查接口地址是否正确")
        }
        if let urlError = error.underlyingError as? URLError {
            let detail: String
            switch urlError.code {
            case .timedOut: detail = "网络超时，请检查连接"
            case .cannotFindHost, .cannotConnectToHost: detail = "无法连接该地址，请检查接口地址"
            case .notConnectedToInternet: detail = "设备当前没有网络"
            case .secureConnectionFailed, .serverCertificateUntrusted: detail = "HTTPS 证书校验失败"
            default: detail = urlError.localizedDescription
            }
            return APIError(route: route, status: status, detail: detail)
        }
        return APIError(route: route, status: status, detail: error.localizedDescription)
    }

    private static func kind(of error: AFError) -> String {
        if case .responseValidationFailed = error { return "validation" }
        if case .responseSerializationFailed = error { return "serialization" }
        if let urlError = error.underlyingError as? URLError { return "url-\(urlError.code.rawValue)" }
        return "other"
    }
}

/// 只在服务端明确表示"没处理这次请求"时重试：429 和 503/529。
///
/// 超时和 5xx 不重试——生成类 POST 可能已在服务端计费，自动重发会重复扣费，
/// 且用户看到的延迟会翻倍。让用户自己决定是否再点一次。
private struct BusyRetrier: RequestInterceptor {
    private let maxRetries = 2

    func retry(
        _ request: Request,
        for session: Session,
        dueTo error: Error,
        completion: @escaping (RetryResult) -> Void
    ) {
        guard let status = request.response?.statusCode,
              status == 429 || status == 503 || status == 529,
              request.retryCount < maxRetries else {
            completion(.doNotRetry)
            return
        }
        // 服务端给了 Retry-After 就听它的，上限 10 秒避免 UI 长时间卡在"测试中"。
        let header = request.response?.value(forHTTPHeaderField: "Retry-After")
        let advised = header.flatMap(TimeInterval.init)
        let delay = min(advised ?? pow(2, Double(request.retryCount + 1)), 10)
        completion(.retryWithDelay(delay))
    }
}

/// 跨 origin 的重定向不继续携带 Authorization，避免把密钥发给第三方主机。
private struct AuthStrippingRedirectHandler: RedirectHandler {
    func task(
        _ task: URLSessionTask,
        willBeRedirectedTo request: URLRequest,
        for response: HTTPURLResponse,
        completion: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url else {
            completion(request)
            return
        }
        var redirected = request
        if !Self.sameOrigin(original, request.url) {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completion(redirected)
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL?) -> Bool {
        guard let rhs else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
    }
}
