import Cocoa
import WebKit
import UniformTypeIdentifiers

func libraryURL() -> URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return root.appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.shiyu.preview", isDirectory: true).appendingPathComponent("bookmarks.json")
}
final class NativeBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
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
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false; panel.allowedContentTypes = [.json]
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
let bridge = NativeBridge(); config.userContentController.add(bridge, name: "persistLibrary"); config.userContentController.add(bridge, name: "saveBackup"); config.userContentController.add(bridge, name: "chooseBackupDirectory"); config.userContentController.add(bridge, name: "writeAutomaticBackup")
let web = WKWebView(frame: .zero, configuration: config)
let ui = UIDelegate(); web.uiDelegate = ui
let delegate = WindowDelegate()
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
window.title = "拾页"; window.minSize = NSSize(width: 720, height: 500); window.contentView = web; window.delegate = delegate; window.center(); window.makeKeyAndOrderFront(nil)
if let url = Bundle.main.url(forResource: "index", withExtension: "html") { web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
app.activate(ignoringOtherApps: true); app.run()

 }
}
