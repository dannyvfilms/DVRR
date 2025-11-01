//
//  PlexResourceLoaderDelegate.swift
//  PlexChannelsTV
//
//  Created by Codex on 11/1/25.
//

import AVFoundation
import Foundation

/// Resource loader delegate that adds Plex headers to playback requests
/// This ensures sessions appear in app.plex.tv and Plex Dash
final class PlexResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    private let sessionID: String?
    private let token: String
    private let clientIdentifier: String
    private let productName: String
    private let version: String
    private let platform: String
    private let device: String
    private let deviceName: String
    
    init(
        sessionID: String?,
        token: String,
        clientIdentifier: String,
        productName: String,
        version: String,
        platform: String,
        device: String,
        deviceName: String
    ) {
        self.sessionID = sessionID
        self.token = token
        self.clientIdentifier = clientIdentifier
        self.productName = productName
        self.version = version
        self.platform = platform
        self.device = device
        self.deviceName = deviceName
        super.init()
    }
    
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url else { return false }
        
        // Note: AVFoundation's resource loader may not intercept all HTTPS requests directly
        // For HLS streams, segment requests might bypass the resource loader
        // We primarily rely on headers being set via the transcoder URL parameters and timeline API
        
        // Only handle HTTP/HTTPS requests
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        
        // Log when resource loader intercepts a request (for debugging)
        if url.path.contains("transcode") || url.path.contains("m3u8") {
            print("[PlexResourceLoader] Intercepted request: \(url.path)")
        }
        
        // Handle redirects if redirect property is set
        if let redirect = loadingRequest.redirect {
            return handleRedirect(loadingRequest: loadingRequest, redirectRequest: redirect)
        }
        
        // Create a new mutable request from the existing request
        var originalRequest = URLRequest(url: url)
        originalRequest.httpMethod = loadingRequest.request.httpMethod
        originalRequest.allHTTPHeaderFields = loadingRequest.request.allHTTPHeaderFields
        originalRequest.httpBody = loadingRequest.request.httpBody
        
        // Add Plex headers (merge with existing headers)
        originalRequest.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        originalRequest.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        originalRequest.setValue(productName, forHTTPHeaderField: "X-Plex-Product")
        originalRequest.setValue(version, forHTTPHeaderField: "X-Plex-Version")
        originalRequest.setValue(platform, forHTTPHeaderField: "X-Plex-Platform")
        originalRequest.setValue(device, forHTTPHeaderField: "X-Plex-Device")
        originalRequest.setValue(deviceName, forHTTPHeaderField: "X-Plex-Device-Name")
        
        // Add session identifier if provided (critical for session tracking)
        if let sessionID {
            originalRequest.setValue(sessionID, forHTTPHeaderField: "X-Plex-Session-Identifier")
        }
        
        // Handle byte range requests
        if let dataRequest = loadingRequest.dataRequest {
            let requestedOffset = dataRequest.requestedOffset
            let requestedLength = dataRequest.requestedLength
            
            if requestedOffset > 0 || requestedLength > 0 {
                let rangeHeader = "bytes=\(requestedOffset)-\(requestedOffset + Int64(requestedLength) - 1)"
                originalRequest.setValue(rangeHeader, forHTTPHeaderField: "Range")
            }
        }
        
        // Perform the request
        let task = URLSession.shared.dataTask(with: originalRequest) { [weak loadingRequest] data, response, error in
            guard let loadingRequest = loadingRequest else { return }
            
            if let error {
                loadingRequest.finishLoading(with: error)
                return
            }
            
            guard let data, let response = response as? HTTPURLResponse else {
                let nsError = NSError(domain: "PlexResourceLoader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
                loadingRequest.finishLoading(with: nsError)
                return
            }
            
            // Set content information first (if available)
            if let contentRequest = loadingRequest.contentInformationRequest {
                contentRequest.contentType = response.mimeType ?? "application/octet-stream"
                contentRequest.contentLength = response.expectedContentLength >= 0 ? response.expectedContentLength : Int64(data.count)
                contentRequest.isByteRangeAccessSupported = true
            }
            
            // Provide response data to loading request
            if let dataRequest = loadingRequest.dataRequest {
                dataRequest.respond(with: data)
            }
            
            loadingRequest.response = response
            loadingRequest.finishLoading()
        }
        
        task.resume()
        return true
    }
    
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForResponseTo authenticationChallenge: URLAuthenticationChallenge
    ) -> Bool {
        // Handle authentication challenges if needed
        return false
    }
    
    private func handleRedirect(loadingRequest: AVAssetResourceLoadingRequest, redirectRequest: URLRequest) -> Bool {
        // Create a new mutable request from the redirect request
        var newRedirectRequest = redirectRequest
        
        // Add Plex headers to the redirect request
        newRedirectRequest.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        newRedirectRequest.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        newRedirectRequest.setValue(productName, forHTTPHeaderField: "X-Plex-Product")
        newRedirectRequest.setValue(version, forHTTPHeaderField: "X-Plex-Version")
        newRedirectRequest.setValue(platform, forHTTPHeaderField: "X-Plex-Platform")
        newRedirectRequest.setValue(device, forHTTPHeaderField: "X-Plex-Device")
        newRedirectRequest.setValue(deviceName, forHTTPHeaderField: "X-Plex-Device-Name")
        
        if let sessionID {
            newRedirectRequest.setValue(sessionID, forHTTPHeaderField: "X-Plex-Session-Identifier")
        }
        
        // Update the redirect request
        loadingRequest.redirect = newRedirectRequest
        
        // Continue with the redirect
        return false  // Let AVFoundation handle the redirect
    }
}
