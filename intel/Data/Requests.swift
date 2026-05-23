//
//  Requests.swift
//  Loop
//
//  Created by Ash Bhat on 11/2/24.
//


import Foundation

class Request: NSObject  {
    static let shared = Request()
    let session = URLSession(configuration: URLSessionConfiguration.ephemeral, delegate: HTTPRequestDelegate(), delegateQueue: nil)

    func getRequest(url: URL, completion: @escaping(Any?, Error?) -> Void) {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil

        let session = URLSession.init(configuration: config)
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let task = session.dataTask(with: request) {(data, response, error) in
            
            DispatchQueue.main.async {
                guard let data = data else {
                    completion(nil, RequestError.noData)
                    return
                }
                do {
                    let jsonData = try JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? [String : AnyObject]
                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                        let someDomain = url.host
                        let someCode = httpResponse.statusCode
                        let errorDesciption = jsonData?["error"] as? String
                        let someInfo = [NSLocalizedDescriptionKey: errorDesciption ?? "no description"]
                        let error = NSError(domain: someDomain!, code: someCode, userInfo: someInfo)
                        completion(nil, error)
                    }
                    else if let jsonData = try JSONSerialization.jsonObject(with: data, options: []) as? [[String : AnyObject]] {
                        completion(jsonData, nil)
                    }
                    else {
                        completion(jsonData, nil)
                    }
                } catch {
                    completion(nil, error)
                }
                
            }

        }
        task.resume()
    }
    
    func postRequest(data: [String: Any], to url: URL, headers: [String: String] = [:],  callback: @escaping (Any?, RequestError?) -> Void) {
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        request.addValue("application/json", forHTTPHeaderField: "Content-Type") // Set content type to
        
        // Apply custom headers, which can override defaults
        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }
        
        do {
            // Encode form data as JSON
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: [])
            request.httpBody = jsonData
        } catch {
            callback(nil, .unknown)
            return
        }
        
        
        let task = session.dataTask(with: request, completionHandler: { data, response, error in
            if (error != nil) {
                callback(nil, .unknown)
                return
            }
            do {
                
                guard let data = data else {
                    callback(nil, RequestError.noData)
                    return
                }
                if let jsonData = try JSONSerialization.jsonObject(with: data, options: []) as? [[String : AnyObject]] {
                    callback(jsonData, nil)
                }
                else if let jsonData = try JSONSerialization.jsonObject(with: data, options: []) as? [String : AnyObject] {
                    callback(jsonData, nil)
                }
                else {
                    callback(nil, .unknown)
                }
            } catch {
                
                if let data = data {
                    let str = String(data: data, encoding: .utf8)
                    print(str ?? "no str")
                }
                
                callback(nil, .unknown)
                return
            }
        })

        task.resume()
    }
}

public class HTTPRequestDelegate: NSObject, URLSessionDelegate
{
    // Get Challenged twice, 2nd time challenge.protectionSpace.serverTrust is nil, but works!
    public func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
                return completionHandler(URLSession.AuthChallengeDisposition.useCredential, nil)
            }
            return completionHandler(URLSession.AuthChallengeDisposition.useCredential, URLCredential(trust: serverTrust))
    }
}


public enum RequestError: Error, LocalizedError {
    case networkOffline
    case httpError
    case unknown
    case systemError
    case noData
    case emailExists
    case usernameExists
    case userNotRegistered
    
    public var errorDescription: String? {
        switch self {
        case .networkOffline:
            return "The network was offline"
        case .emailExists:
            return "There's already account registered with this email."
        case .usernameExists:
            return "This username is already registered."
        case .systemError:
            return "There was a system error. Please try again."
        case .noData:
            return "The server recieved no data for the update. Please try again."
        case .httpError:
            return "There was an networking error. Please try again."
        case .unknown:
            return "There was an unknown error. Please try again."
        case .userNotRegistered:
            return "The user has yet to register."
        }
    }
}
