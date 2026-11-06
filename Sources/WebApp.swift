import Cocoa
import WebKit
import UniformTypeIdentifiers
import LinkPresentation
import Quartz

func libraryURL() -> URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return root.appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.shiyu.preview", isDirectory: true).appendingPathComponent("bookmarks.json")
}
func notesURL() -> URL { libraryURL().deletingLastPathComponent().appendingPathComponent("notes.json") }
final class NativeBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "fetchLinkMetadata" {
            guard let body = message.body as? [String: String], let id = body["id"], let raw = body["url"], let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            if let host = url.host?.lowercased(), host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") {
                var components = URLComponents(string: "https://www.youtube.com/oembed")!
                components.queryItems = [URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "url", value: raw)]
                if let endpoint = components.url {
                    URLSession.shared.dataTask(with: endpoint) { data, _, _ in
                        guard let data = data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
                        let result = ["id": id, "title": object["title"] as? String ?? "", "author": object["author_name"] as? String ?? "", "image": object["thumbnail_url"] as? String ?? ""]
                        guard let encoded = try? JSONSerialization.data(withJSONObject: result), let json = String(data: encoded, encoding: .utf8) else { return }
                        DispatchQueue.main.async { message.webView?.evaluateJavaScript("window.shiyuOembedResult(\(json))") }
                    }.resume()
                }
            }
            if let host = url.host?.lowercased(), ["x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"].contains(host) {
                let parts = url.path.split(separator: "/").map(String.init)
                if parts.count >= 3, parts[1] == "status", !parts[2].isEmpty, parts[2].allSatisfy({ $0.isNumber }) {
                    var components = URLComponents(string: "https://publish.twitter.com/oembed")!
                    components.queryItems = [URLQueryItem(name: "omit_script", value: "true"), URLQueryItem(name: "url", value: "https://x.com/\(parts[0])/status/\(parts[2])")]
                    if let endpoint = components.url {
                        var embedRequest = URLRequest(url: endpoint); embedRequest.timeoutInterval = 15
                        URLSession.shared.dataTask(with: embedRequest) { data, _, _ in
                            guard let data = data, data.count <= 1_000_000, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let html = object["html"] as? String else { return }
                            let result = ["id": id, "html": html, "author": object["author_name"] as? String ?? ""]
                            guard let encoded = try? JSONSerialization.data(withJSONObject: result), let json = String(data: encoded, encoding: .utf8) else { return }
                            DispatchQueue.main.async { message.webView?.evaluateJavaScript("window.shiyuXEmbedResult(\(json))") }
                        }.resume()
                    }
                }
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            URLSession.shared.dataTask(with: request) { data, response, _ in
                guard let data = data, data.count <= 2_000_000, let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), let html = String(data: data, encoding: .utf8) else { return }
                let result = ["id": id, "html": String(html.prefix(500_000))]
                guard let encoded = try? JSONSerialization.data(withJSONObject: result), let json = String(data: encoded, encoding: .utf8) else { return }
                DispatchQueue.main.async { message.webView?.evaluateJavaScript("window.shiyuHTMLResult(\(json))") }
            }.resume()
            let provider = LPMetadataProvider()
            provider.timeout = 15
            provider.startFetchingMetadata(for: url) { metadata, error in
                let result: [String: String] = ["id": id, "title": metadata?.title ?? "", "error": error == nil ? "" : "无法读取页面信息，可以手动编辑标题"]
                guard let data = try? JSONSerialization.data(withJSONObject: result), let json = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async { message.webView?.evaluateJavaScript("window.shiyuMetadataResult(\(json))") }
                _ = provider
            }
            return
        }
        if message.name == "persistNotes" {
            guard let value = message.body as? String, let data = value.data(using: .utf8) else { return }
            do { let url = notesURL(); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try data.write(to: url, options: .atomic) }
            catch { let alert = NSAlert(error: error); alert.messageText = "保存笔记失败"; alert.runModal() }
            return
        }
        if message.name == "persistLibrary" {
            guard let value = message.body as? String, let data = value.data(using: .utf8) else { return }
            do { let url = libraryURL(); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try data.write(to: url, options: .atomic) }
            catch { let alert = NSAlert(error: error); alert.messageText = "保存收藏失败"; alert.runModal() }
            return
        }
        if message.name == "chooseBackupDirectory" {
            guard let target = message.body as? String, ["icloud", "google"].contains(target) else { return }
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
            panel.message = target == "icloud" ? "选择 iCloud 备份文件夹" : "选择 Google Drive 同步文件夹"
            if panel.runModal() == .OK, let url = panel.url {
                UserDefaults.standard.set(url.path, forKey: "backup-directory-" + target)
                let literal = (try? JSONSerialization.data(withJSONObject: [url.path])).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                message.webView?.evaluateJavaScript("window.shiyuDirectorySelected(\(target == "icloud" ? "'icloud'" : "'google'"), \(literal)[0])")
            }
            return
        }
        if message.name == "writeAutomaticBackup" {
            guard let body = message.body as? [String: Any], let envelope = body["data"] as? String, let data = envelope.data(using: .utf8), let targets = body["targets"] as? [String] else { return }
            var outcomes: [String] = []
            for target in targets where ["icloud", "google"].contains(target) {
                guard let path = UserDefaults.standard.string(forKey: "backup-directory-" + target) else { outcomes.append(target + "：未选择文件夹"); continue }
                do { _ = try BackupStore.write(data, to: URL(fileURLWithPath: path, isDirectory: true)); outcomes.append(target + "：成功") }
                catch { outcomes.append(target + "：" + error.localizedDescription) }
            }
            let json = (try? JSONSerialization.data(withJSONObject: outcomes)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            message.webView?.evaluateJavaScript("window.shiyuBackupResult(\(json))")
            return
        }
        guard message.name == "saveBackup", let value = message.body as? String, let data = value.data(using: .utf8) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "拾页加密备份.json"; panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do { try data.write(to: url, options: .atomic) }
            catch { let alert = NSAlert(error: error); alert.runModal() }
        }
    }
}
final class FileCollectionBridge: NSObject, WKScriptMessageHandlerWithReply, QLPreviewPanelDataSource {
    private var previewURL: URL?
    private let store = FileCollectionStore(url: libraryURL().deletingLastPathComponent().appendingPathComponent("files.json"))

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else {
            replyHandler(nil, "文件请求格式不正确")
            return
        }
        do {
            switch action {
            case "getAll":
                replyHandler(try store.read(), nil)
            case "merge":
                guard let records = body["value"] as? [[String: Any]] else { throw invalidRequest() }
                _ = try store.merge(records)
                replyHandler(true, nil)
            case "delete":
                guard let id = body["value"] as? String else { throw invalidRequest() }
                try store.delete(id: id)
                replyHandler(true, nil)
            case "preview":
                guard let record = body["value"] as? [String: Any] else { throw invalidRequest() }
                try store.validate(record)
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shiye-preview-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = (record["name"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "文件"
                let destination = directory.appendingPathComponent(name)
                guard let encoded = record["data"] as? String, let data = Data(base64Encoded: encoded) else { throw invalidRequest() }
                try data.write(to: destination, options: .atomic)
                previewURL = destination
                let panel = QLPreviewPanel.shared()!
                panel.dataSource = self
                panel.reloadData()
                panel.makeKeyAndOrderFront(nil)
                replyHandler(true, nil)
            case "export":
                guard let record = body["value"] as? [String: Any] else { throw invalidRequest() }
                try store.validate(record)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = (record["name"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "文件"
                if panel.runModal() == .OK, let destination = panel.url,
                   let encoded = record["data"] as? String, let data = Data(base64Encoded: encoded) {
                    try data.write(to: destination, options: .atomic)
                }
                replyHandler(true, nil)
            default:
                throw invalidRequest()
            }
        } catch {
            replyHandler(nil, error.localizedDescription)
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }

    private func invalidRequest() -> NSError {
        NSError(domain: "ShiyeFiles", code: 2, userInfo: [NSLocalizedDescriptionKey: "文件请求格式不正确"])
    }
}
final class WindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { NSApplication.shared.terminate(nil) }
}
final class UIDelegate: NSObject, WKUIDelegate {
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle: "好"); alert.runModal(); completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消"); completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert(); alert.messageText = prompt; let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); field.stringValue = defaultText ?? ""; alert.accessoryView = field; alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消"); alert.window.initialFirstResponder = field; completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = parameters.allowsMultipleSelection; panel.canChooseDirectories = false
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }; return nil
    }
}
@main struct ShiyuApp {
 static func main() {
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let mainMenu = NSMenu()
let appItem = NSMenuItem(); mainMenu.addItem(appItem)
let appMenu = NSMenu(); appItem.submenu = appMenu
appMenu.addItem(withTitle: "退出拾页", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let editItem = NSMenuItem(); mainMenu.addItem(editItem)
let editMenu = NSMenu(title: "编辑"); editItem.submenu = editMenu
editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z"); redo.keyEquivalentModifierMask = [.command, .shift]
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
app.mainMenu = mainMenu
let config = WKWebViewConfiguration(); config.websiteDataStore = .default()
if let data = try? Data(contentsOf: libraryURL()), let value = String(data: data, encoding: .utf8), let escaped = try? JSONSerialization.data(withJSONObject: [value]), let literal = String(data: escaped, encoding: .utf8) {
    config.userContentController.addUserScript(WKUserScript(source: "window.shiyuNativeLibrary = \(literal)[0]", injectionTime: .atDocumentStart, forMainFrameOnly: true))
}
if let data = try? Data(contentsOf: notesURL()), let value = String(data: data, encoding: .utf8), let escaped = try? JSONSerialization.data(withJSONObject: [value]), let literal = String(data: escaped, encoding: .utf8) {
    config.userContentController.addUserScript(WKUserScript(source: "window.shiyeNativeNotes = \(literal)[0]", injectionTime: .atDocumentStart, forMainFrameOnly: true))
}
let bridge = NativeBridge(); config.userContentController.add(bridge, name: "fetchLinkMetadata"); config.userContentController.add(bridge, name: "persistLibrary"); config.userContentController.add(bridge, name: "persistNotes"); config.userContentController.add(bridge, name: "saveBackup"); config.userContentController.add(bridge, name: "chooseBackupDirectory"); config.userContentController.add(bridge, name: "writeAutomaticBackup")
let fileBridge = FileCollectionBridge()
config.userContentController.addScriptMessageHandler(fileBridge, contentWorld: .page, name: "fileCollection")
let web = WKWebView(frame: .zero, configuration: config)
let ui = UIDelegate(); web.uiDelegate = ui
let delegate = WindowDelegate()
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
window.title = "拾页"; window.minSize = NSSize(width: 720, height: 500); window.contentView = web; window.delegate = delegate; window.center(); window.makeKeyAndOrderFront(nil)
if let url = Bundle.main.url(forResource: "index", withExtension: "html") { web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
app.activate(ignoringOtherApps: true); app.run()

 }
}
