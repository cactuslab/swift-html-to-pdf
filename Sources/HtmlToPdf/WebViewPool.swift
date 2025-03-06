//
//  File.swift
//  swift-html-to-pdf
//
//  Created by Coen ten Thije Boonkkamp on 08/09/2024.
//

#if canImport(WebKit)
import Foundation
import WebKit
import Dependencies

/// An actor for managing a pool of WKWebViews
actor WebViewPoolActor {
    /// Error types that can be thrown by the WebViewPool
    enum Error: Swift.Error {
        case timeout
        case poolExhausted
    }
    
    private var availableWebViews: [WKWebView]
    private var pendingRequests: [UnsafeContinuation<WKWebView, Swift.Error>] = []
    private let maxSize: Int
    
    init(size: Int) {
        self.maxSize = size
        // Create web views on the main actor since WKWebView requires it
        self.availableWebViews = []
        
        // Schedule creation of web views on the main actor
        Task { @MainActor in
            let webViews = (0..<size).map { _ in
                WKWebView(frame: .zero)
            }
            await self.addWebViews(webViews)
        }
    }
    
    /// Add a batch of web views to the pool
    func addWebViews(_ webViews: [WKWebView]) {
        availableWebViews.append(contentsOf: webViews)
        
        // Fulfill any pending requests with the newly available web views
        while !pendingRequests.isEmpty, let webView = availableWebViews.popLast() {
            let continuation = pendingRequests.removeFirst()
            continuation.resume(returning: webView)
        }
    }
    
    /// Request a web view from the pool
    func acquireWebView() async throws -> WKWebView {
        // If we have available web views, return one immediately
        if let webView = availableWebViews.popLast() {
            return webView
        }
        
        // Otherwise, wait for one to become available
        return try await withUnsafeThrowingContinuation { continuation in
            pendingRequests.append(continuation)
        }
    }
    
    /// Return a web view to the pool
    func releaseWebView(_ webView: WKWebView) {
        // If someone is waiting for a web view, give it to them directly
        if let continuation = pendingRequests.first {
            pendingRequests.removeFirst()
            continuation.resume(returning: webView)
        } else {
            // Otherwise, put it back in the pool
            availableWebViews.append(webView)
        }
    }
}

/// Client for the WebViewPool using the dependencies library
struct WebViewPoolClient {
    /// Acquire a web view from the pool
    var acquireWebView: @Sendable () async throws -> WKWebView
    
    /// Release a web view back to the pool
    var releaseWebView: @Sendable (WKWebView) async -> Void
    
    /// Attempt to acquire a web view with retries
    var acquireWithRetry: @Sendable (Int, TimeInterval) async throws -> WKWebView
}

extension WebViewPoolClient: DependencyKey {
    static var liveValue: WebViewPoolClient {
        let actor = WebViewPoolActor(size: ProcessInfo.processInfo.activeProcessorCount)
        
        return WebViewPoolClient(
            acquireWebView: {
                try await actor.acquireWebView()
            },
            releaseWebView: { webView in
                await actor.releaseWebView(webView)
            },
            acquireWithRetry: { retries, delay in
                // Try to acquire with retries
                for attempt in 0..<retries {
                    do {
                        return try await actor.acquireWebView()
                    } catch {
                        if attempt == retries - 1 {
                            // Last attempt, propagate the error
                            throw error
                        }
                        
                        // Wait before trying again
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                }
                
                // This should never be reached if retries > 0
                throw WebViewPoolActor.Error.timeout
            }
        )
    }
    
    /// Test value that uses dummy web views for testing
    static var testValue: WebViewPoolClient {
        return liveValue
//        return WebViewPoolClient(
//            acquireWebView: { @MainActor in
//                // Create a dummy web view for testing
//                return WKWebView(frame: .zero)
//            },
//            releaseWebView: { _ in
//                // Do nothing in tests
//            },
//            acquireWithRetry: { _, _ in
//                // Just return a new web view in tests
//                @MainActor func createWebView() -> WKWebView {
//                    return WKWebView(frame: .zero)
//                }
//                return await createWebView()
//            }
//        )
    }
}

extension DependencyValues {
    var webViewPool: WebViewPoolClient {
        get { self[WebViewPoolClient.self] }
        set { self[WebViewPoolClient.self] = newValue }
    }
}


#endif
