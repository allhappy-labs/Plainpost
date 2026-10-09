import os
import SwiftUI
import WebKit

#if os(macOS)
import AppKit

final class ReaderHTMLWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        guard let readerScrollView = Self.readerScrollView(containing: self) else {
            super.scrollWheel(with: event)
            return
        }
        readerScrollView.scrollWheel(with: event)
    }

    static func readerScrollView(containing view: NSView) -> NSScrollView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let scrollView = current as? NSScrollView {
                return scrollView
            }
            ancestor = current.superview
        }
        return nil
    }
}

struct HTMLMessageView: NSViewRepresentable {
    let html: String
    let allowsRemoteContent: Bool
    let onExternalURL: (@MainActor (URL) -> Void)?
    @Binding var contentHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    init(
        html: String,
        allowsRemoteContent: Bool,
        onExternalURL: (@MainActor (URL) -> Void)? = nil,
        contentHeight: Binding<CGFloat>
    ) {
        self.html = html
        self.allowsRemoteContent = allowsRemoteContent
        self.onExternalURL = onExternalURL
        _contentHeight = contentHeight
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight, onExternalURL: onExternalURL)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = Self.makeWebView(coordinator: context.coordinator)
        webView.underPageBackgroundColor = HTMLMessageDocument.underPageBackgroundColor(for: colorScheme)
        return webView
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.dismantle(webView)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.underPageBackgroundColor = HTMLMessageDocument.underPageBackgroundColor(for: colorScheme)
        context.coordinator.load(
            html: html,
            allowsRemoteContent: allowsRemoteContent,
            colorScheme: colorScheme,
            in: webView
        )
    }
}
#elseif os(iOS)
import UIKit

struct HTMLMessageView: UIViewRepresentable {
    let html: String
    let allowsRemoteContent: Bool
    let onExternalURL: (@MainActor (URL) -> Void)?
    @Binding var contentHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    init(
        html: String,
        allowsRemoteContent: Bool,
        onExternalURL: (@MainActor (URL) -> Void)? = nil,
        contentHeight: Binding<CGFloat>
    ) {
        self.html = html
        self.allowsRemoteContent = allowsRemoteContent
        self.onExternalURL = onExternalURL
        _contentHeight = contentHeight
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight, onExternalURL: onExternalURL)
    }

    func makeUIView(context: Context) -> WKWebView {
        Self.makeWebView(coordinator: context.coordinator)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.dismantle(webView)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(
            html: html,
            allowsRemoteContent: allowsRemoteContent,
            colorScheme: colorScheme,
            in: webView
        )
    }
}
#endif

extension HTMLMessageView {
    // Keep every reader in one ephemeral WebKit session. The store remains
    // private, while avoiding a separate networking session for every message.
    static let sharedWebsiteDataStore = WKWebsiteDataStore.nonPersistent()

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private var contentHeight: Binding<CGFloat>
        private let onExternalURL: (@MainActor (URL) -> Void)?
        private var loadedHTML: String?
        private var loadedRemoteContentPolicy: Bool?
        private var loadedColorScheme: ColorScheme?
        private var documentGeneration = 0
        private let prepareDocument: @MainActor (String, Bool, ColorScheme) -> Task<String, Never>
        private(set) var preparationTask: Task<Void, Never>?
        private var pendingRequest: PreparationRequest?
        private var isDismantled = false

        private struct PreparationRequest {
            let html: String
            let allowsRemoteContent: Bool
            let colorScheme: ColorScheme
            let generation: Int
            weak var webView: WKWebView?
        }

        init(
            contentHeight: Binding<CGFloat>,
            onExternalURL: (@MainActor (URL) -> Void)? = nil,
            prepareDocument: @escaping @MainActor (String, Bool, ColorScheme) -> Task<String, Never> = Coordinator.prepare
        ) {
            self.contentHeight = contentHeight
            self.onExternalURL = onExternalURL
            self.prepareDocument = prepareDocument
        }

        func load(
            html: String,
            allowsRemoteContent: Bool,
            colorScheme: ColorScheme = .light,
            in webView: WKWebView
        ) {
            guard !isDismantled else { return }
            guard loadedHTML != html || loadedRemoteContentPolicy != allowsRemoteContent || loadedColorScheme != colorScheme else {
                return
            }
            loadedHTML = html
            loadedRemoteContentPolicy = allowsRemoteContent
            loadedColorScheme = colorScheme
            documentGeneration &+= 1
            webView.stopLoading()
            let request = PreparationRequest(
                html: html, allowsRemoteContent: allowsRemoteContent,
                colorScheme: colorScheme, generation: documentGeneration, webView: webView
            )
            if preparationTask != nil {
                // Replacing this single slot immediately releases superseded input.
                pendingRequest = request
            } else {
                start(request)
            }
        }

        private func start(_ request: PreparationRequest) {
            let generation = request.generation
            let webView = request.webView
            let documentTask = prepareDocument(request.html, request.allowsRemoteContent, request.colorScheme)
            preparationTask = Task { @MainActor [weak self, weak webView] in
                let document = await documentTask.value
                // Do not retain the coordinator or WebKit view across preparation.
                guard let self else { return }
                self.preparationTask = nil
                guard !self.isDismantled else { return }
                if let pending = self.pendingRequest {
                    self.pendingRequest = nil
                    self.start(pending)
                    return
                }
                guard self.documentGeneration == generation, let webView else { return }
                let signposter = OSSignposter(subsystem: "com.plainpost.performance", category: "reader")
                signposter.emitEvent("HTMLDocumentSubmitted")
                webView.loadHTMLString(document, baseURL: nil)
            }
        }

        func dismantle(_ webView: WKWebView) {
            isDismantled = true
            documentGeneration &+= 1
            pendingRequest = nil
            loadedHTML = nil
            loadedRemoteContentPolicy = nil
            loadedColorScheme = nil
            // Synchronous regex already admitted off-thread may finish. Its weak
            // completion cannot publish or start pending work after dismantle.
            preparationTask = nil
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "mailHeight")
        }

        private static func prepare(
            html: String, allowsRemoteContent: Bool, colorScheme: ColorScheme
        ) -> Task<String, Never> {
            Task.detached(priority: .userInitiated) {
                let signposter = OSSignposter(subsystem: "com.plainpost.performance", category: "reader")
                let interval = signposter.beginInterval("HTMLPreparation", id: signposter.makeSignpostID())
                defer { signposter.endInterval("HTMLPreparation", interval) }
                return HTMLMessageDocument.document(
                    html: html,
                    allowsRemoteContent: allowsRemoteContent,
                    colorScheme: colorScheme
                )
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard !isDismantled, message.name == "mailHeight", let number = message.body as? NSNumber else {
                return
            }
            let height = min(max(CGFloat(truncating: number), 120), 100_000)
            if abs(contentHeight.wrappedValue - height) > 1 {
                contentHeight.wrappedValue = height
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if onExternalURL != nil {
                decisionHandler(.cancel)
                Task { @MainActor [weak self] in
                    self?.onExternalURL?(url)
                }
                return
            }
#if os(macOS)
            NSWorkspace.shared.open(url)
#elseif os(iOS)
            UIApplication.shared.open(url)
#endif
            decisionHandler(.cancel)
        }

        @MainActor
        func externalLinkPolicy(for url: URL) -> WKNavigationActionPolicy {
            onExternalURL?(url)
            return .cancel
        }
    }

    static func makeWebView(coordinator: Coordinator) -> WKWebView {
        let webView = HTMLMessageWebViewPool.take()
        webView.configuration.userContentController.add(coordinator, name: "mailHeight")
        webView.navigationDelegate = coordinator
        return webView
    }

    /// A reader web view with its scripts, not yet attached to a message.
    static func makeBareWebView() -> WKWebView {
        let contentController = WKUserContentController()
        // Ahead of the height observer, so it measures the recoloured, fitted email. User
        // scripts run whatever the message's Content-Security-Policy says; the message's
        // own scripts never do.
        contentController.addUserScript(
            WKUserScript(source: MPDarkmodeScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        contentController.addUserScript(
            WKUserScript(source: HTMLMessageDocument.appearanceScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        contentController.addUserScript(
            WKUserScript(
                source: HTMLMessageDocument.heightObserverScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = sharedWebsiteDataStore
        configuration.userContentController = contentController

        let webView: WKWebView
#if os(macOS)
        webView = ReaderHTMLWebView(frame: .zero, configuration: configuration)
#else
        webView = WKWebView(frame: .zero, configuration: configuration)
#endif

#if os(macOS)
        if let scrollView = webView.subviews.compactMap({ $0 as? NSScrollView }).first {
            scrollView.hasHorizontalScroller = false
            scrollView.hasVerticalScroller = false
            scrollView.horizontalScrollElasticity = .none
            scrollView.verticalScrollElasticity = .none
        }
#else
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        // No white flash before a dark-mode message is recoloured.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
#endif
        return webView
    }

}

/// Keeps one reader web view built ahead of the next message, once the app asks for it, so
/// opening a message doesn't wait for WebKit to build a view, inject the reader scripts or
/// start its web content process.
@MainActor
public enum HTMLMessageWebViewPool {
    private static var isEnabled = false
    private static var spare: WKWebView?
    private static var isReplenishing = false

    /// Builds the spare and starts WebKit's web content process. Until an app calls this,
    /// every reader builds its own web view.
    public static func prewarm() {
        isEnabled = true
        guard spare == nil else { return }
        let webView = HTMLMessageView.makeBareWebView()
        webView.loadHTMLString("", baseURL: nil)
        spare = webView
    }

    static func take() -> WKWebView {
        guard isEnabled else { return HTMLMessageView.makeBareWebView() }
        let webView = spare ?? HTMLMessageView.makeBareWebView()
        spare = nil
        replenish()
        return webView
    }

    /// Builds the next spare once the opening message has had the main thread to itself.
    private static func replenish() {
        guard !isReplenishing else { return }
        isReplenishing = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            isReplenishing = false
            prewarm()
        }
    }
}

enum HTMLMessageDocument {
    static let heightObserverScript = """
    (() => {
      let lastHeight = 0;
      let scheduled = false;
      const reportHeight = () => {
        if (scheduled) return;
        scheduled = true;
        requestAnimationFrame(() => {
          scheduled = false;
        const body = document.body;
        const root = document.documentElement;
        // A fitted (scaled) email's body still reports its unscaled offset height.
        const height = body && body.style.zoom
          ? Math.max(root ? root.scrollHeight : 0, body.getBoundingClientRect().bottom)
          : Math.max(
            body ? body.scrollHeight : 0,
            body ? body.offsetHeight : 0,
            root ? root.scrollHeight : 0,
            root ? root.offsetHeight : 0
          );
          const roundedHeight = Math.ceil(height);
          if (Math.abs(roundedHeight - lastHeight) > 1) {
            lastHeight = roundedHeight;
            window.webkit.messageHandlers.mailHeight.postMessage(roundedHeight);
          }
        });
      };
      new ResizeObserver(reportHeight).observe(document.documentElement);
      window.addEventListener('load', reportHeight);
      document.querySelectorAll('img').forEach(image => {
        image.addEventListener('load', reportHeight);
        image.addEventListener('error', reportHeight);
      });
      reportHeight();
    })();
    """

    /// Runs after the message loads: in dark mode it recolours the email (mp-darkmode, after
    /// carrying each element's stylesheet colours inline, since mp-darkmode reads only inline
    /// styles and `bgcolor`), then scales an email wider than the reader down to fit.
    static let appearanceScript = """
    (() => {
      const body = document.body;
      if (!body) return;
      const appearance = document.querySelector('meta[name="plainpost-appearance"]');
      if (appearance && appearance.content === 'dark' && window.Darkmode) {
        const nodes = [body, ...body.querySelectorAll('*')];
        for (const node of nodes) {
          const style = getComputedStyle(node);
          if (!node.style.color) node.style.color = style.color;
          const background = style.backgroundColor;
          if (!node.style.backgroundColor && background && background !== 'transparent' && background !== 'rgba(0, 0, 0, 0)') {
            node.style.backgroundColor = background;
          }
        }
        try {
          window.Darkmode.run(nodes, {
            mode: 'dark',
            defaultDarkBgColor: '\(darkPalette.surface)',
            defaultDarkTextColor: '\(darkPalette.text)'
          });
        } catch (error) {}
        document.documentElement.style.backgroundColor = '\(darkPalette.page)';
      }
      const fit = () => {
        body.style.zoom = '';
        const width = document.documentElement.scrollWidth;
        const viewport = window.innerWidth;
        if (viewport > 0 && width > viewport + 1) body.style.zoom = String(viewport / width);
      };
      fit();
      window.addEventListener('load', fit);
      document.querySelectorAll('img').forEach(image => image.addEventListener('load', fit));
    })();
    """

    static func document(
        html: String,
        allowsRemoteContent: Bool,
        colorScheme: ColorScheme = .light
    ) -> String {
        let imageSources = allowsRemoteContent ? "http: https: data: cid:" : "data: cid:"
        let csp = "default-src 'none'; img-src \(imageSources); style-src 'unsafe-inline'; font-src data:; media-src data:; script-src 'none'; frame-src 'none'; connect-src 'none'; form-action 'none'; base-uri 'none'"
        let displayedHTML = allowsRemoteContent ? html : blockingRemoteContent(in: html)
        // Every email is laid out in light colours, as senders design them; in dark mode
        // `appearanceScript` recolours it as a whole, the email's own colours included.
        let palette = lightPalette
        let headContent = """
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <meta name="plainpost-appearance" content="\(colorScheme == .dark ? "dark" : "light")">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <style>
          :root {
            color-scheme: \(palette.colorScheme);
            --plainpost-page: \(palette.page);
            --plainpost-surface: \(palette.surface);
            --plainpost-text: \(palette.text);
            --plainpost-muted: \(palette.muted);
            --plainpost-link: \(palette.link);
            --plainpost-link-visited: \(palette.visitedLink);
            --plainpost-rule: \(palette.rule);
            --plainpost-code: \(palette.code);
          }
          html {
            margin: 0;
            padding: 0;
            max-width: 100%;
            min-height: 1px;
            background: var(--plainpost-page);
            color: var(--plainpost-text);
            text-size-adjust: 100%;
          }
          body {
            margin: 0;
            padding: \(bodyPadding);
            max-width: 100%;
            min-height: 1px;
            box-sizing: border-box;
            overflow-wrap: anywhere;
            word-break: normal;
            background: var(--plainpost-surface);
            color: var(--plainpost-text);
            font-family: "Atkinson Hyperlegible", "Atkinson Hyperlegible Next", ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            font-size: 16px;
            font-weight: 400;
            line-height: 1.62;
            letter-spacing: 0;
            -webkit-font-smoothing: antialiased;
            text-rendering: optimizeLegibility;
          }
          body > :first-child { margin-top: 0; }
          body > :last-child { margin-bottom: 0; }
          p, ul, ol, dl, blockquote, pre { margin: 0 0 1.15em; }
          ul, ol { padding-left: 1.35em; }
          h1, h2, h3, h4, h5, h6 {
            margin: 1.45em 0 0.55em;
            color: var(--plainpost-text);
            font-family: Charter, "Bitstream Charter", Georgia, serif;
            font-weight: 700;
            line-height: 1.2;
          }
          h1 { font-size: 1.7em; }
          h2 { font-size: 1.4em; }
          h3 { font-size: 1.18em; }
          h4, h5, h6 { font-size: 1em; }
          a { color: var(--plainpost-link); text-decoration-thickness: 0.08em; text-underline-offset: 0.14em; }
          a:visited { color: var(--plainpost-link-visited); }
          hr { height: 1px; margin: 1.5em 0; border: 0; background: var(--plainpost-rule); }
          blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid var(--plainpost-rule); color: var(--plainpost-muted); }
          pre, code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
          pre { padding: 0.85em 1em; overflow-x: auto; background: var(--plainpost-code); border-radius: 6px; }
          img { max-width: 100%; height: auto; }
          table { max-width: 100%; height: auto; }
        </style>
        """

        // Match only structurally leading document tags. A header/custom tag,
        // late head in body content, or tag-looking text inside a quoted
        // attribute cannot choose the insertion point. Keep the generated CSP
        // ahead of resources without rewriting the accepted message markup.
        let attributes = #"(?:[^"'<>]|"[^"]*"|'[^']*')*"#
        let prefix = #"\A\s*(?:<!doctype\s+"# + attributes + #">\s*)?"#
        let htmlTag = #"<html(?=[\s/>])"# + attributes + ">"
        let headTag = #"<head(?=[\s/>])"# + attributes + ">"
        let leadingHead = "(?is)(" + prefix + "(?:" + htmlTag + #"\s*)?"# + headTag + ")"
        if displayedHTML.range(of: leadingHead, options: .regularExpression) != nil {
            return displayedHTML.replacingFirstMatch(
                pattern: leadingHead,
                with: "$1\n\(headContent)"
            )
        }
        let leadingHTML = "(?is)(" + prefix + htmlTag + ")"
        if displayedHTML.range(of: leadingHTML, options: .regularExpression) != nil {
            return displayedHTML.replacingFirstMatch(
                pattern: leadingHTML,
                with: "$1<head>\(headContent)</head>"
            )
        }
        return "<!doctype html><html><head>\(headContent)</head><body>\(displayedHTML)</body></html>"
    }

    static func loadOnceDocument(html: String, colorScheme: ColorScheme = .light) -> String {
        document(html: html, allowsRemoteContent: true, colorScheme: colorScheme)
    }

#if os(macOS)
    static func underPageBackgroundColor(for colorScheme: ColorScheme) -> NSColor {
        colorScheme == .dark
            ? NSColor(srgbRed: 0.055, green: 0.067, blue: 0.086, alpha: 1)
            : NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1)
    }
#endif

    /// The phone's reader is narrow: a slim inset leaves the email its width.
    #if os(iOS)
    static let bodyPadding = "12px 8px"
    #else
    static let bodyPadding = "28px 32px"
    #endif

    private static let lightPalette = palette(for: .light)
    private static let darkPalette = palette(for: .dark)

    private static func palette(for colorScheme: ColorScheme) -> ReaderPalette {
        colorScheme == .dark
            ? ReaderPalette(
                colorScheme: "dark",
                page: "#0E1116",
                surface: "#171C24",
                text: "#EEF2F7",
                muted: "#AEB8C6",
                link: "#86B9FF",
                visitedLink: "#C7A8FF",
                rule: "#394250",
                code: "#202733"
            )
            : ReaderPalette(
                colorScheme: "light",
                page: "#F0F2F5",
                surface: "#FFFFFF",
                text: "#20242C",
                muted: "#5F6978",
                link: "#1557B0",
                visitedLink: "#7047B5",
                rule: "#D8DEE7",
                code: "#F4F6F9"
            )
    }

    private struct ReaderPalette {
        let colorScheme: String
        let page: String
        let surface: String
        let text: String
        let muted: String
        let link: String
        let visitedLink: String
        let rule: String
        let code: String
    }

    private static func blockingRemoteContent(in html: String) -> String {
        html
            .replacingAllMatches(
                pattern: #"(?is)\bsrcset\s*=\s*(["'])([^"']*https?://[^"']*)\1"#,
                with: "data-mail-remote-srcset=$1$2$1"
            )
            .replacingAllMatches(
                pattern: #"(?is)\bsrc\s*=\s*(["'])(https?://[^"']+)\1"#,
                with: "data-mail-remote-src=$1$2$1"
            )
            .replacingAllMatches(
                pattern: #"(?is)\bbackground\s*=\s*(["'])(https?://[^"']+)\1"#,
                with: "data-mail-remote-background=$1$2$1"
            )
            .replacingAllMatches(
                pattern: #"(?is)url\(\s*["']?https?://[^)]*\)"#,
                with: "none"
            )
    }
}

private extension String {
    func replacingFirstMatch(pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return self
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regex.firstMatch(in: self, range: range) else {
            return self
        }
        return regex.stringByReplacingMatches(in: self, range: match.range, withTemplate: replacement)
    }

    func replacingAllMatches(pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return self
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(in: self, range: range, withTemplate: replacement)
    }
}
