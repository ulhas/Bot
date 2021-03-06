import Config
import Services
import Common
import Foundation

//MARK: - Error
/// Describes the range of possible errors that can occur when authenticating using OAuth
public enum OAuthAuthenticationError: Error, CustomStringConvertible {
    /// A derived url was invalid
    case invalidURL
    
    /// An oAuth error
    case oauthError(reason: String)
    
    public var description: String {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .oauthError(let reason): return "OAuth Failed: \(reason)"
        }
    }
}

//MARK: - Endpoints
private enum Endpoint: String {
    case login
    case oauth
}

//MARK: - OAuthAuthentication
/// Handles oauth authentication
public final class OAuthAuthentication: SlackAuthenticator {
    //MARK: - Private Properties
    fileprivate let clientId: String
    fileprivate let clientSecret: String
    fileprivate let server: HTTPServer
    fileprivate let http: HTTP
    fileprivate let storage: Storage
    
    //MARK: - Private Mutable Properties
    fileprivate var token: String? {
        get { return self.storage.get(.in("oauth"), key: "token") }
        set { _ = try? self.storage.set(.in("oauth"), key: "token", value: newValue) }
    }
    fileprivate var state = ""
    fileprivate var success: ((String) -> Void)?
    fileprivate var failure: ((Error) -> Void)?
    
    //MARK: - Lifecycle
    public init(clientId: String, clientSecret: String, server: HTTPServer, http: HTTP, storage: Storage) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.server = server
        self.http = http
        self.storage = storage
        
        self.configureServer()
    }
    public convenience init(config: Config, server: HTTPServer, http: HTTP, storage: Storage) throws {
        let clientId: String = try config.value(for: OAuthClientID.self)
        let clientSecret: String = try config.value(for: OAuthClientSecret.self)
        self.init(clientId: clientId, clientSecret: clientSecret, server: server, http: http, storage: storage)
    }
    
    //MARK: - Public
    public static var configItems: [ConfigItem.Type] {
        return [OAuthClientID.self, OAuthClientSecret.self]
    }
    public func authenticate(success: @escaping (String) -> Void, failure: @escaping (Error) -> Void) {
        if let token = self.token {
            success(token)
            return
            
        }
        
        self.state = "\(Int.random(min: 1, max: 999999))"
        self.success = { [weak self] token in
            self?.reset()
            success(token)
        }
        self.failure = { [weak self] error in
            self?.reset()
            failure(error)
        }
        
        print("Ready to authenticate: Please visit /login")
    }
    public func disconnected() {
        self.token = nil
    }
    
    //MARK: - State
    private func reset() {
        self.state = ""
        self.success = nil
        self.failure = nil
    }
}

//MARK: - Server
fileprivate extension OAuthAuthentication {
    func configureServer() {
        self.server.respond(
            to: .get, at: [Endpoint.login.rawValue],
            with: self, OAuthAuthentication.handleLogin
        )
        self.server.respond(
            to: .get, at: [Endpoint.oauth.rawValue],
            with: self, OAuthAuthentication.handleOAuth
        )
    }
    
    func handleLogin(url: URL, headers: [String: String], data: [String: Any]?) throws -> HTTPServerResponse? {
        guard !self.state.isEmpty else { return nil }
        return try self.oAuthAuthorizeURL()
    }
    func handleOAuth(url: URL, headers: [String: String], data: [String: Any]?) throws -> HTTPServerResponse? {
        guard
            let data = url.query?.makeQueryParameters(),
            let state = data["state"],
            let code = data["code"],
            !state.isEmpty, state == self.state
            else { return nil }
        
        if let error = data["error"] { throw OAuthAuthenticationError.oauthError(reason: error) }
        
        _ = inBackground(
            try: {
                let accessUrl = try self.oAuthAccessURL(code: code)
                let request = HTTPRequest(method: .get, url: accessUrl)
                let (_, json) = try self.http.perform(with: request)
                
                let token: String = try json.value(at: ["bot", "bot_access_token"])
                self.token = token
                self.success?(token)
            },
            catch: { error in
                self.failure?(error)
            }
        )
        
        return nil
    }
}

//MARK: - URLs
fileprivate extension OAuthAuthentication {
    func oAuthAuthorizeURL() throws -> URL {
        var components = URLComponents(string: "https://slack.com/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: self.clientId),
            URLQueryItem(name: "scope", value: "bot"),
            URLQueryItem(name: "state", value: self.state),
        ]
        
        guard let url = components?.url else { throw OAuthAuthenticationError.invalidURL }
        return url
    }
    func oAuthAccessURL(code: String) throws -> URL {
        var components = URLComponents(string: "https://slack.com/api/oauth.access")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: self.clientId),
            URLQueryItem(name: "client_secret", value: self.clientSecret),
            URLQueryItem(name: "code", value: code),
        ]
        
        guard let url = components?.url else { throw OAuthAuthenticationError.invalidURL }
        return url
    }
}
