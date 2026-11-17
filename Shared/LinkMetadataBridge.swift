import Foundation
import WebKit
import LinkPresentation

final class LinkMetadataBridge: NSObject, WKScriptMessageHandler {
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
            request.timeoutInterval = 20
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: request) { data, response, _ in
                guard let data = data, data.count <= 8_000_000, let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), let html = String(data: data, encoding: .utf8) else { return }
                let result = ["id": id, "html": html]
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
    }
}
