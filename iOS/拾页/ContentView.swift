import SwiftUI
import WebKit
import UniformTypeIdentifiers
import QuickLook
import SafariServices

struct ContentView: View {
    @State private var session: LibrarySession?
    @State private var failure: String?
    var body: some View {
        Group {
            if let session { PhoneLibraryWebView(session: session) }
            else if let failure { ContentUnavailableView("无法打开拾页", systemImage: "externaldrive.badge.exclamationmark", description: Text(failure)) }
            else { ProgressView("正在打开拾页") }
        }
        .tint(Color(red: 0.24, green: 0.44, blue: 0.35))
        .task {
            do {
                let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("local.shiye.app", isDirectory: true)
                #if targetEnvironment(simulator)
                let enabled = ProcessInfo.processInfo.environment["SHIYE_SIMULATOR_CLOUD_ENABLED"] == "1"
                #else
                let enabled = true
                #endif
                let store = try CloudLibrary(directory: root, cloudEnabled: enabled)
                session = try LibrarySession(store: store)
            } catch { failure = error.localizedDescription }
        }
    }
}

struct PhoneLibraryWebView: UIViewRepresentable {
    let session: LibrarySession
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let coordinator = context.coordinator
        try? session.configure(configuration.userContentController)
        configuration.userContentController.addUserScript(WKUserScript(source: "window.shiyeIsPhone=true", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        for name in ["persistLibrary", "persistNotes", "fileCollection"] {
            configuration.userContentController.addScriptMessageHandler(coordinator, contentWorld: .page, name: name)
        }
        for name in ["saveBackup", "setLanguage", "setTheme", "chooseBackupDirectory", "writeAutomaticBackup"] {
            configuration.userContentController.add(coordinator, name: name)
        }
        configuration.userContentController.add(SnapshotAcknowledgement(session: session), name: "snapshotPresented")
        configuration.userContentController.add(LinkMetadataBridge(), name: "fetchLinkMetadata")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = coordinator
        web.uiDelegate = coordinator
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.94, green: 0.95, blue: 0.93, alpha: 1)
        coordinator.web = web
        session.webView = web
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, QLPreviewControllerDataSource {
        let session: LibrarySession
        weak var web: WKWebView?
        private var previewURL: URL?
        init(session: LibrarySession) { self.session = session }
        private var presenter: UIViewController? {
            var controller = web?.window?.rootViewController
            while let presented = controller?.presentedViewController { controller = presented }
            return controller
        }
        private func text(_ source: String) -> String {
            let language = UserDefaults.standard.string(forKey: "shiye-language") ?? "system"
            let code = (language == "system" ? Locale.preferredLanguages.first ?? "zh" : language).split(separator: "-").first.map(String.init) ?? "zh"
            guard code != "zh", let url = Bundle.main.url(forResource: "NativeLocalizations", withExtension: "json"),
                  let data = try? Data(contentsOf: url), let values = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else { return source }
            return values[code]?[source] ?? values["en"]?[source] ?? source
        }
        private func openLink(_ url: URL) {
            let browser = SFSafariViewController(url: url)
            browser.preferredControlTintColor = UIColor(red: 0.24, green: 0.44, blue: 0.35, alpha: 1)
            presenter?.present(browser, animated: true)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            applyNativeTheme()
            session.sendCurrent()
        }
        private func applyNativeTheme() {
            let night = UserDefaults.standard.string(forKey: "shiye-theme") == "night"
            web?.window?.overrideUserInterfaceStyle = night ? .dark : .light
            web?.backgroundColor = night ? UIColor(red: 0.09, green: 0.11, blue: 0.10, alpha: 1) : UIColor(red: 0.94, green: 0.95, blue: 0.93, alpha: 1)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                openLink(url)
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { openLink(url) }
            return nil
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "setTheme":
                if let value = message.body as? String, ["day", "night"].contains(value) {
                    UserDefaults.standard.set(value, forKey: "shiye-theme")
                    applyNativeTheme()
                }
            case "setLanguage":
                if let value = message.body as? String { UserDefaults.standard.set(value, forKey: "shiye-language") }
            case "saveBackup":
                if let value = message.body as? String, let data = value.data(using: .utf8) { do { share(try temporaryFile(data: data, name: "Shiye-backup.json")) } catch { showError(error) } }
            default:
                let alert = UIAlertController(title: text("云盘备份"), message: "请使用导出数据，将加密备份保存到 iCloud 云盘。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: text("好"), style: .default))
                presenter?.present(alert, animated: true)
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
            do {
                if message.name == "persistLibrary" || message.name == "persistNotes" {
                    guard let value = message.body as? String, let data = value.data(using: .utf8), let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw CocoaError(.coderInvalidValue) }
                    let result = try message.name == "persistLibrary" ? session.writeGroups(records) : session.writeNotes(records)
                    replyHandler(message.name == "persistNotes" ? result.notes : result.groups, nil)
                    return
                }
                guard let body = message.body as? [String: Any], let action = body["action"] as? String else { throw CocoaError(.coderInvalidValue) }
                if action == "exportArchive", let request = body["value"] as? [String: String], let password = request["password"] {
                    Task { @MainActor in
                        do { share(try await session.exportArchive(password: password)); replyHandler(true, nil) }
                        catch { replyHandler(nil, error.localizedDescription) }
                    }
                    return
                }
                if ["getAll", "beginImport", "appendImport", "finishImport", "cancelImport", "updateMetadata", "thumbnail", "readFilePart", "inspectArchive", "cancelArchive", "commitArchive"].contains(action) {
                    Task { @MainActor in
                        do { replyHandler(try await session.fileRequest(action, value: body["value"]), nil) }
                        catch { replyHandler(nil, error.localizedDescription) }
                    }
                    return
                }
                if ["preview", "export"].contains(action), let record = body["value"] as? [String: Any], record["native"] as? Bool == true, let id = record["id"] as? String {
                    Task { @MainActor in
                        do {
                            let url = try await session.fileURL(id)
                            if action == "export" { share(url) }
                            else {
                                previewURL = url
                                let preview = QLPreviewController()
                                preview.dataSource = self
                                presenter?.present(preview, animated: true)
                            }
                            replyHandler(true, nil)
                        } catch { replyHandler(nil, error.localizedDescription) }
                    }
                    return
                }
                let validator = FileCollectionStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("unused.json"))
                switch action {
                case "getAll": replyHandler(try session.store.snapshot().files, nil)
                case "merge":
                    guard let records = body["value"] as? [[String: Any]] else { throw CocoaError(.coderInvalidValue) }
                    for record in records { try validator.validate(record) }
                    try session.mergeFiles(records)
                    replyHandler(true, nil)
                case "delete":
                    guard let id = body["value"] as? String else { throw CocoaError(.coderInvalidValue) }
                    try session.deleteFile(id)
                    replyHandler(true, nil)
                case "preview", "export":
                    guard let record = body["value"] as? [String: Any] else { throw CocoaError(.coderInvalidValue) }
                    try validator.validate(record)
                    let data = Data(base64Encoded: record["data"] as! String)!
                    let url = try temporaryFile(data: data, name: record["name"] as! String)
                    if action == "export" { share(url) }
                    else {
                        previewURL = url
                        let preview = QLPreviewController()
                        preview.dataSource = self
                        presenter?.present(preview, animated: true)
                    }
                    replyHandler(true, nil)
                default: throw CocoaError(.coderInvalidValue)
                }
            } catch { replyHandler(nil, error.localizedDescription) }
        }
        private func temporaryFile(data: Data, name: String) throws -> URL {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
            try data.write(to: url, options: .atomic)
            return url
        }
        private func share(_ url: URL) {
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = web
            activity.popoverPresentationController?.sourceRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            presenter?.present(activity, animated: true)
        }
        private func showError(_ error: Error) {
            let alert = UIAlertController(title: text("好"), message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: text("好"), style: .default))
            presenter?.present(alert, animated: true)
        }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewURL == nil ? 0 : 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { previewURL! as NSURL }
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: text("好"), style: .default) { _ in completionHandler() })
            presenter?.present(alert, animated: true)
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: text("取消"), style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: text("确定"), style: .default) { _ in completionHandler(true) })
            presenter?.present(alert, animated: true)
        }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { field in field.isSecureTextEntry = true; field.text = defaultText }
            alert.addAction(UIAlertAction(title: text("取消"), style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: text("确定"), style: .default) { _ in completionHandler(alert.textFields?.first?.text ?? "") })
            presenter?.present(alert, animated: true)
        }
    }
}
