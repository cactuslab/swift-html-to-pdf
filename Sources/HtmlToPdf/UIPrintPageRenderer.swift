//
//  swift-html-to-pdf | iOS.swift
//
//
//  Created by Coen ten Thije Boonkkamp on 15/07/2024.
//

#if canImport(UIKit)

import Foundation
import UIKit
import WebKit
import Dependencies

extension Document {
    
    /// Prints a ``Document`` to PDF with the given configuration.
    ///
    /// This function is more convenient when you have a directory and just want to title the PDF and save it to the directory.
    ///
    /// ## Example
    /// ```swift
    /// try await Document.init(...)
    ///     .print(configuration: .a4)
    /// ```
    ///
    /// - Parameters:
    ///   - configuration: The configuration of the PDF document.
    ///
    /// - Throws: `Error` if the function cannot write to the document's fileUrl.
    @MainActor
    public func print(
        configuration: PDFConfiguration,
        createDirectories: Bool = true
    ) async throws {
        
        if html.containsImages() {
            try await DocumentWKRenderer(
                document: self,
                configuration: configuration,
                createDirectories: createDirectories
            ).print()
            
        } else {
            try await print(
                configuration: configuration,
                createDirectories: createDirectories,
                printFormatter: UIMarkupTextPrintFormatter(markupText: self.html)
            )
        }
    }
}

extension String {
    
    /// Determines if the HTML string contains any `<img>` tags.
    /// - Returns: A boolean indicating whether the HTML contains images.
    func containsImages() -> Bool {
        let imgRegex = "<img\\s+[^>]*src\\s*=\\s*['\"]([^'\"]*)['\"][^>]*>"
        
        do {
            let regex = try NSRegularExpression(pattern: imgRegex, options: .caseInsensitive)
            let matches = regex.matches(in: self, options: [], range: NSRange(location: 0, length: self.utf16.count))
            return !matches.isEmpty
            
        } catch {
            Swift.print("Regex error: \(error.localizedDescription)")
            return false
        }
    }
}

extension Error {
    /// Determines if the error is a cancellation error
    var isCancellationError: Bool {
        (self as? CancellationError) != nil
    }
}

class CustomRenderer : UIPrintPageRenderer {
    
    private let width: CGFloat
    private let height: CGFloat
    
    override var paperRect: CGRect {
        return CGRect(x: 0, y: 0, width: width, height: height)
    }
                      
    override var printableRect: CGRect {
        return CGRect(x: 0, y: 0, width: width, height: height)
    }
    
    override var numberOfPages: Int {
        return 1
    }
    
    init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }
    
}

extension Document {
    
    /// Internal method to print the document using a custom UIPrintFormatter.
    /// - Parameters:
    ///   - configuration: The PDF configuration for printing.
    ///   - createDirectories: Flag to create directories if they don't exist. Default is `true`.
    ///   - printFormatter: The formatter used for printing the document content.
    @MainActor
    internal func print(
        configuration: PDFConfiguration,
        createDirectories: Bool = true,
        printFormatter: UIPrintFormatter
    ) async throws {
        if createDirectories {
            try FileManager.default.createDirectory(at: self.fileUrl.deletingPathExtension().deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        
        let renderer = CustomRenderer(width: configuration.paperSize.width, height: configuration.paperSize.height)
        renderer.addPrintFormatter(printFormatter, startingAtPageAt: 0)

        let paperRect = CGRect(origin: .zero, size: CGSize(width: configuration.paperSize.width, height: configuration.paperSize.height))

        let pdfData = NSMutableData()
        UIGraphicsBeginPDFContextToData(pdfData, paperRect, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))

        let bounds = UIGraphicsGetPDFContextBounds()

        (0..<renderer.numberOfPages).forEach { index in
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: index, in: bounds)
        }

        UIGraphicsEndPDFContext()

        try pdfData.write(to: self.fileUrl)
    }
}

private class DocumentWKRenderer: NSObject, WKNavigationDelegate {
    private var document: Document
    private var configuration: PDFConfiguration
    private var createDirectories: Bool
    
    private var continuation: CheckedContinuation<Void, Error>?
    private var webView: WKWebView?
    private var timeoutTask: Task<Void, Error>?
    
    init(
        document: Document,
        configuration: PDFConfiguration,
        createDirectories: Bool
    ) {
        self.document = document
        self.configuration = configuration
        self.createDirectories = createDirectories
        super.init()
    }
    
    @MainActor
    public func print(timeout: TimeInterval = 30) async throws {
        @Dependency(\.webViewPool) var webViewPool
        let webView = try await webViewPool.acquireWithRetry(8, 0.2)
        webView.navigationDelegate = self
        
        do {
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                webView.loadHTMLString(document.html, baseURL: configuration.baseURL)
                
                timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        if self.continuation != nil {
                            throw NSError(domain: "DocumentWKRenderer", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebView loading timed out"])
                        }
                    } catch {
                        if !error.isCancellationError {
                            self.continuation?.resume(throwing: error)
                            await self.cleanup(webView: webView)
                        }
                    }
                }
            }
        } catch {
            // If an error occurs, make sure to release the webView
            await cleanup(webView: webView)
            throw error
        }
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task {
            do {
                let result = try await webView.evaluateJavaScript("""
                    (function() {
                        return {
                            width: document.body.scrollWidth,
                            height: document.body.scrollHeight
                        };
                    })()
                    """)
                
                let conf: PDFConfiguration
                if let dict = result as? [String: Any],
                   let width = dict["width"] as? CGFloat,
                   let height = dict["height"] as? CGFloat {
                    webView.frame = CGRect(origin: .zero, size: webView.scrollView.contentSize)
                    webView.layoutSubviews()
                    
                    let ratio = width / CGSize.a4().width
                    
                    conf = PDFConfiguration(margins: .init(top: 0, left: 0, bottom: 0, right: 0), paperSize: CGSize(width: CGSize.a4().width, height: height / ratio), baseURL: configuration.baseURL, orientation: configuration.orientation)
                } else {
                    conf = PDFConfiguration(margins: .init(top: 0, left: 0, bottom: 0, right: 0), paperSize: webView.scrollView.contentSize, baseURL: configuration.baseURL, orientation: configuration.orientation)
                }
                
                try await document.print(
                    configuration: conf,
                    createDirectories: createDirectories,
                    printFormatter: webView.viewPrintFormatter()
                )
                timeoutTask?.cancel()
                continuation?.resume(returning: ())
            } catch {
                continuation?.resume(throwing: error)
            }
            await cleanup(webView: webView)
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        Task {
            timeoutTask?.cancel()
            continuation?.resume(throwing: error)
            await cleanup(webView: webView)
        }
    }
    
    @MainActor
    private func cleanup(webView: WKWebView) async {
        @Dependency(\.webViewPool) var webViewPool
        webView.navigationDelegate = nil
        await webViewPool.releaseWebView(webView)
    }
}

extension PDFConfiguration {
    public static func a4(margins: EdgeInsets) -> PDFConfiguration {
        return .init(
            margins: margins,
            paperSize: .a4()
        )
    }
}

extension CGSize {
    public static func paperSize() -> CGSize {
        CGSize(width: 595.22, height: 841.85)
    }
}

extension UIEdgeInsets {
    init(
        edgeInsets: EdgeInsets
    ) {
        self = .init(
            top: .init(edgeInsets.top),
            left: .init(edgeInsets.left),
            bottom: .init(edgeInsets.bottom),
            right: .init(edgeInsets.right)
        )
    }
}

#endif
