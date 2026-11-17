import SwiftUI
import AppKit

struct Bookmark: Identifiable, Codable {
    var id = UUID()
    var name: String
    var url: String
    var note: String
}
struct BookmarkGroup: Identifiable, Codable {
    var id = UUID()
    var name: String
    var bookmarks: [Bookmark] = []
}

@MainActor final class Library: ObservableObject {
    @Published var groups: [BookmarkGroup] = []
    @Published var error: String?
    private let file: URL
    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WebsiteShelf", isDirectory: true)
        file = directory.appendingPathComponent("bookmarks.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                groups = try JSONDecoder().decode([BookmarkGroup].self, from: Data(contentsOf: file))
            }
        } catch { self.error = "无法读取收藏数据：\(error.localizedDescription)" }
    }
    func save() {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(groups).write(to: file, options: .atomic)
        } catch { self.error = "保存失败：\(error.localizedDescription)" }
    }
}

struct Editor: Identifiable {
    enum Kind { case group(UUID?), bookmark(UUID, UUID?) }
    let id = UUID()
    let kind: Kind
}

struct ContentView: View {
    @StateObject private var library = Library()
    @State private var selected: UUID?
    @State private var editor: Editor?
    @State private var search = ""
    @State private var deleteGroup: UUID?
    @State private var deleteBookmark: UUID?
    private var current: BookmarkGroup? { library.groups.first { $0.id == selected } }
    private var results: [Bookmark] {
        (current?.bookmarks ?? []).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.url.localizedCaseInsensitiveContains(search) || $0.note.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack { Text("我的收藏").font(.system(size: 20, weight: .bold)); Spacer(); Button { editor = Editor(kind: .group(nil)) } label: { Image(systemName: "plus") }.help("添加分组") }
                    .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 16)
                List(selection: $selected) {
                    ForEach(library.groups) { group in
                        HStack { Image(systemName: "folder").foregroundStyle(.secondary); Text(group.name); Spacer(); Text("\(group.bookmarks.count)").foregroundStyle(.secondary).font(.caption) }
                            .tag(group.id)
                            .contextMenu {
                                Button("重命名") { editor = Editor(kind: .group(group.id)) }
                                Button("删除分组", role: .destructive) { deleteGroup = group.id }
                            }
                    }
                }.listStyle(.sidebar)
                Text("网站收藏 · 本地保存").font(.caption).foregroundStyle(.secondary).padding(18)
            }.navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if let group = current {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 5) { Text(group.name).font(.system(size: 28, weight: .bold)); Text("\(group.bookmarks.count) 个网站").foregroundStyle(.secondary) }
                        Spacer()
                        Button { editor = Editor(kind: .bookmark(group.id, nil)) } label: { Label("添加网站", systemImage: "plus") }.buttonStyle(.borderedProminent)
                        Menu { Button("重命名分组") { editor = Editor(kind: .group(group.id)) }; Button("删除分组", role: .destructive) { deleteGroup = group.id } } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().help("分组选项")
                    }.padding(.horizontal, 32).padding(.top, 30).padding(.bottom, 22)
                    TextField("搜索名称、链接或备注", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 32).padding(.bottom, 18)
                    Divider()
                    if results.isEmpty {
                        Spacer(); VStack(spacing: 10) { Image(systemName: search.isEmpty ? "bookmark" : "magnifyingglass").font(.system(size: 30)).foregroundStyle(.tertiary); Text(search.isEmpty ? "还没有收藏网站" : "没有找到匹配的网站").font(.headline); Text(search.isEmpty ? "点击右上角添加第一个网站" : "试试其他关键词").foregroundStyle(.secondary) }.frame(maxWidth: .infinity); Spacer()
                    } else {
                        ScrollView { LazyVStack(spacing: 0) { ForEach(results) { bookmark in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: "globe").font(.system(size: 17)).foregroundStyle(Color.accentColor).frame(width: 38, height: 38).background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 5) {
                                    Button(bookmark.name) { open(bookmark.url) }.buttonStyle(.plain).font(.headline)
                                    Text(bookmark.url).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                                    if !bookmark.note.isEmpty { Text(bookmark.note).font(.subheadline).foregroundStyle(.secondary).padding(.top, 3).textSelection(.enabled) }
                                }
                                Spacer()
                                Button { open(bookmark.url) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.borderless).help("打开网站")
                                Menu { Button("编辑") { editor = Editor(kind: .bookmark(group.id, bookmark.id)) }; Button("复制链接") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(bookmark.url, forType: .string) }; Button("删除", role: .destructive) { deleteBookmark = bookmark.id } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                            }.padding(.vertical, 17).padding(.horizontal, 32)
                            Divider().padding(.leading, 84)
                        } } }
                    }
                } else {
                    Spacer(); VStack(spacing: 12) { Image(systemName: "bookmark.square").font(.system(size: 38)).foregroundStyle(.tertiary); Text("收藏你喜欢的网站").font(.title2.bold()); Text("先创建一个分组，把常用网站整理在一起。").foregroundStyle(.secondary); Button("创建分组") { editor = Editor(kind: .group(nil)) }.buttonStyle(.borderedProminent).padding(.top, 6) }.frame(maxWidth: .infinity); Spacer()
                }
            }.frame(minWidth: 480, minHeight: 480)
        }
        .frame(minWidth: 720, minHeight: 500)
        .sheet(item: $editor) { item in EditSheet(library: library, editor: item) { id in selected = id } }
        .alert("删除分组？", isPresented: Binding(get: { deleteGroup != nil }, set: { if !$0 { deleteGroup = nil } })) {
            Button("取消", role: .cancel) { deleteGroup = nil }
            Button("删除", role: .destructive) { if let id = deleteGroup { library.groups.removeAll { $0.id == id }; if selected == id { selected = library.groups.first?.id }; library.save() }; deleteGroup = nil }
        } message: { Text("该分组中的所有网站也会被删除。") }
        .alert("删除网站？", isPresented: Binding(get: { deleteBookmark != nil }, set: { if !$0 { deleteBookmark = nil } })) {
            Button("取消", role: .cancel) { deleteBookmark = nil }
            Button("删除", role: .destructive) { if let id = deleteBookmark, let i = library.groups.firstIndex(where: { $0.id == selected }) { library.groups[i].bookmarks.removeAll { $0.id == id }; library.save() }; deleteBookmark = nil }
        } message: { Text("此操作无法撤销。") }
        .alert("出现问题", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) { Button("好") { library.error = nil } } message: { Text(library.error ?? "") }
        .onAppear { if selected == nil { selected = library.groups.first?.id } }
    }
    func open(_ address: String) { if let url = URL(string: address) { NSWorkspace.shared.open(url) } }
}

struct EditSheet: View {
    @ObservedObject var library: Library
    let editor: Editor
    let select: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var note = ""
    @State private var validation = ""
    private var isGroup: Bool { if case .group = editor.kind { return true }; return false }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isGroup ? "分组" : "网站").font(.title2.bold())
            TextField(isGroup ? "分组名称" : "网站名称", text: $name).textFieldStyle(.roundedBorder)
            if !isGroup {
                TextField("网址，例如 example.com", text: $url).textFieldStyle(.roundedBorder)
                Text("备注（可选）").font(.subheadline).foregroundStyle(.secondary)
                TextEditor(text: $note).font(.body).frame(height: 90).border(Color.secondary.opacity(0.25))
            }
            if !validation.isEmpty { Text(validation).foregroundStyle(.red).font(.caption) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("保存") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 430).onAppear(perform: load)
    }
    func load() {
        switch editor.kind {
        case .group(let id): if let group = library.groups.first(where: { $0.id == id }) { name = group.name }
        case .bookmark(let groupID, let id): if let bookmark = library.groups.first(where: { $0.id == groupID })?.bookmarks.first(where: { $0.id == id }) { name = bookmark.name; url = bookmark.url; note = bookmark.note }
        }
    }
    func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { validation = "请填写名称。"; return }
        switch editor.kind {
        case .group(let id):
            if let id, let i = library.groups.firstIndex(where: { $0.id == id }) { library.groups[i].name = cleanName; select(id) }
            else { let group = BookmarkGroup(name: cleanName); library.groups.append(group); select(group.id) }
        case .bookmark(let groupID, let id):
            var address = url.trimmingCharacters(in: .whitespacesAndNewlines)
            if !address.contains("://") { address = "https://" + address }
            guard let components = URLComponents(string: address), let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = components.host, !host.isEmpty, !host.contains(" ") else { validation = "请输入有效的 HTTP 或 HTTPS 网址。"; return }
            guard let i = library.groups.firstIndex(where: { $0.id == groupID }) else { return }
            if let id, let j = library.groups[i].bookmarks.firstIndex(where: { $0.id == id }) { library.groups[i].bookmarks[j].name = cleanName; library.groups[i].bookmarks[j].url = address; library.groups[i].bookmarks[j].note = note.trimmingCharacters(in: .whitespacesAndNewlines) }
            else { library.groups[i].bookmarks.append(Bookmark(name: cleanName, url: address, note: note.trimmingCharacters(in: .whitespacesAndNewlines))) }
        }
        library.save(); dismiss()
    }
}

@main struct WebsiteShelfApp: App {
    var body: some Scene { WindowGroup { ContentView() }.windowStyle(.titleBar) }
}
