/**
 * Copyright (c) Grab Taxi Holdings PTE LTD (GRAB)
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *
 */

import Foundation

// Internal helpers to call GrabId service API.
class GrabApi {
  public struct serviceEndPoints {
    var exchangeUri = ""
    var loginUri = ""
    var verify = ""
  }

  static func createUrl(baseUrl: String, params: [NSURLQueryItem]? = nil) -> URL? {
    let urlComponents = NSURLComponents(string: baseUrl)

    var charSet = CharacterSet.urlQueryAllowed
    charSet.remove(":")
    charSet.remove("=")

    if let params = params {
      var separator = ""
      var percentEncodedQuery = ""
      for param in params {
        if let encodedName = param.name.addingPercentEncoding(withAllowedCharacters: charSet),
          let encodedValue = param.value?.addingPercentEncoding(withAllowedCharacters: charSet) {
          let queryParam = "\(separator)\(encodedName)=\(encodedValue)"
          percentEncodedQuery.append(queryParam)
          separator = "&"
        }
      }
      urlComponents?.percentEncodedQuery = percentEncodedQuery
    }

    return urlComponents?.url
  }
  
  static func fetchServiceConfigurations(session: URLSession, serviceDiscoveryUrl: String, completion: @escaping(serviceEndPoints,GrabIdPartnerError?) -> Void) {
    var endPoints = serviceEndPoints()
    
    guard let url = createUrl(baseUrl: serviceDiscoveryUrl) else {
        let error = GrabIdPartnerError(code: .invalidUrl,
                                       localizeMessage:serviceDiscoveryUrl,
                                       domain: .serviceDiscovery,
                                       serviceError: nil)
        completion(endPoints, error)
      return
    }

    var urlRequest = URLRequest(url: url)
    urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
    urlRequest.httpMethod = "GET"
    // urlRequest.timeoutInterval = ???
//    let session = URLSession.shared
    let task = session.dataTask(with: urlRequest) { (data, response, error) in
      if let error = error {
        let error = GrabIdPartnerError(code: .grabIdServiceFailed,
                                       localizeMessage: GrabIdPartnerLocalization.invalidResponse.rawValue,
                                       domain: .serviceDiscovery,
                                       serviceError: error)
        completion(endPoints, error)
      } else {
        if let response = response as? HTTPURLResponse,
          !(200...299 ~= response.statusCode) {
          let error = GrabIdPartnerError(code: .discoveryServiceFailed,
                                         localizeMessage:"\(response.statusCode)",
                                         domain: .serviceDiscovery,
                                         serviceError: nil)
          completion(endPoints, error)
          return
        }

        guard let data = data else {
          let error = GrabIdPartnerError(code: .grabIdServiceFailed,
                                         localizeMessage: GrabIdPartnerLocalization.invalidResponse.rawValue,
                                         domain: .serviceDiscovery,
                                         serviceError: error)
          completion(endPoints, error)
          return
        }
        
        do {
          if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let authorizationEndpoint = json["authorization_endpoint"],
            let tokenEndpoint = json["token_endpoint"],
            let idTokenVerificationEndPoint = json["id_token_verification_endpoint"] {
            endPoints.loginUri = authorizationEndpoint as? String ?? ""
            endPoints.exchangeUri = tokenEndpoint as? String ?? ""
            endPoints.verify = idTokenVerificationEndPoint as? String ?? ""
          }
          completion(endPoints, nil)
        } catch let parseError {
          let error = GrabIdPartnerError(code: .grabIdServiceFailed,
                                         localizeMessage:parseError.localizedDescription,
                                         domain: .serviceDiscovery,
                                         serviceError: parseError)
          completion(endPoints, error)
        }
      }
    }
    task.resume()
  }
  
  static func fetchToken(session: URLSession, exchangeTokenEndPoint: String, clientID: String = "", code: String = "", codeVerifier: String = "",
                         grantType: GrantType, refreshToken: String, redirectUri: String, state: String,
                         completion: @escaping([String: Any]?,GrabIdPartnerError?) -> Void) {
    // Assemble query params to pass to createUrlWithParams
    var paramValues = [
      "client_id": clientID,
      "grant_type": grantType.rawValue
    ]
    
    // Only refresh token if client secret and refresh token are available.
    if !refreshToken.isEmpty {
      paramValues["refresh_token"] = refreshToken
    } else {
      paramValues["redirect_uri"] = redirectUri
      paramValues["code_verifier"] = codeVerifier
      paramValues["code"] = code
    }

    if let urlComponents = URLComponents(string: exchangeTokenEndPoint) {
      var components = urlComponents
      components.queryItems = paramValues.map { (key, value) in
        URLQueryItem(name: key, value: value)
      }
      components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
      if let url = components.url {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        // urlRequest.timeoutInterval = ???
//        let session = URLSession.shared
        let task = session.dataTask(with: urlRequest) { (data, response, error) in
          if let error = error {
            let error = GrabIdPartnerError(code: .serviceError,
                                           localizeMessage:GrabIdPartnerLocalization.serviceError.rawValue,
                                           domain: .exchangeToken,
                                           serviceError: error)
            completion(nil, error)
          } else {
            if let response = response as? HTTPURLResponse,
              !(200...299 ~= response.statusCode) {
              let error = GrabIdPartnerError(code: .exchangeTokenServiceFailed,
                                             localizeMessage:"\(response.statusCode)",
                domain: .exchangeToken,
                serviceError: nil)
              completion(nil, error)
              return
            }

            guard let data = data else {
              let error = GrabIdPartnerError(code: .invalidResponse,
                                             localizeMessage:GrabIdPartnerLocalization.invalidResponse.rawValue,
                                             domain: .exchangeToken,
                                             serviceError: error)
              completion(nil, error)
              return
            }
            
            do {
              if grantType == .authorizationCode,
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let access_token = json["access_token"],
                let token_type = json["token_type"],
                let expires_in = json["expires_in"],
                let id_token = json["id_token"] {
                let refresh_token = json["refresh_token"] as? String ?? "" 
                let results = ["access_token": access_token,
                               "token_type": token_type,
                               "expires_in": expires_in,
                               "id_token": id_token,
                               "refresh_token": refresh_token,
                               ]
                completion(results, nil)
              } else if grantType == .refreshToken,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access_token = json["access_token"],
                  let expires_in = json["expires_in"] {
                let results = ["access_token": access_token,
                               "expires_in": expires_in]
                completion(results, nil)
              } else {
                let error = GrabIdPartnerError(code: .invalidResponse,
                                               localizeMessage: GrabIdPartnerLocalization.invalidResponse.rawValue,
                                               domain: .exchangeToken)
                completion(nil, error)
              }
            } catch let parseError {
              let error = GrabIdPartnerError(code: .invalidServiceDiscoveryUrl,
                                             localizeMessage:parseError.localizedDescription,
                                             domain: .exchangeToken,
                                             serviceError: parseError)
              completion(nil, error)
            }
          }
        }
        task.resume()
      }
    }
  }

  static func fetchGetIdTokenInfo(session: URLSession, getIdTokenInfoEndpoint: String, clientId: String = "", idToken: String = "", nonce: String = "",
                               completion: @escaping([String: Any]?,GrabIdPartnerError?) -> Void) {
    // Assemble query params to pass to createUrlWithParams
    let paramValues = [
      "client_id": clientId,
      "id_token": idToken,
      "nonce": nonce,
    ]
    
    if let urlComponents = URLComponents(string: getIdTokenInfoEndpoint) {
      var components = urlComponents
      components.queryItems = paramValues.map { (key, value) in
        URLQueryItem(name: key, value: value)
      }
      components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
      if let url = components.url {
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        urlRequest.httpMethod = "GET"
        // urlRequest.timeoutInterval = ???
//        let session = URLSession.shared
        let task = session.dataTask(with: urlRequest) { (data, response, error) in
          if let error = error {
            let error = GrabIdPartnerError(code: .idTokenInfoServiceFailed,
                                           localizeMessage: GrabIdPartnerLocalization.serviceError.rawValue,
                                           domain: .getIdTokenInfo,
                                           serviceError: error)
            completion(nil, error)
            return
          } else {
            if let response = response as? HTTPURLResponse,
              !(200...299 ~= response.statusCode) {
              let error = GrabIdPartnerError(code: .idTokenInfoServiceFailed,
                                             localizeMessage:"\(response.statusCode)",
                                             domain: .getIdTokenInfo,
                                             serviceError: nil)
              completion(nil, error)
              return
            }

            guard let data = data else {
              let error = GrabIdPartnerError(code: .idTokenInfoServiceFailed,
                                             localizeMessage:GrabIdPartnerLocalization.invalidResponse.rawValue,
                                             domain: .getIdTokenInfo,
                                             serviceError: nil)
              completion(nil, error)
              return
            }
            
            do {
              if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let audience = json["aud"],
                  let expires_at = json["exp"],
                  let issue_at = json["iat"],
                  let issuer = json["iss"],
                  let notValidBefore = json["nbf"],
                  let tokenId = json["jti"],
                  let nonce = json["nonce"],
                  let service = json["svc"],
                  let partnerId = json["pid"],
                  let partnerUserId = json["sub"] {
                  let results = ["audience": audience,
                               "expires_at": expires_at,
                               "issue_at": issue_at,
                               "issuer": issuer,
                               "notValidBefore": notValidBefore,
                               "tokenId": tokenId,
                               "nonce": nonce,
                               "partnerId": partnerId,
                               "partnerUserId": partnerUserId,
                               "service" : service
                               ]
                completion(results, nil)
                return
              }
            } catch let parseError {
              let error = GrabIdPartnerError(code: .idTokenInfoServiceFailed,
                                             localizeMessage:parseError.localizedDescription,
                                             domain: .getIdTokenInfo,
                                             serviceError: parseError)
              completion(nil, error)
            }
          }
        }
        task.resume()
      }
    }
  }
}
