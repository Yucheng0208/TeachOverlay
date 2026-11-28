import AppKit
import Combine
import SwiftUI

struct Note: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var body: String
    var updated: Date
}

/// 筆記：存在 ~/Library/Application Support/TeachOverlay/notes.json（自動儲存）
@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    @Published private(set) var notes: [Note] = []
    @Published var selectedID: UUID?
    @Published var search = ""

    private var saveWork: DispatchWorkItem?
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TeachOverlay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notes.json")
    }()

    var fileURL: URL { url }

    private init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Note].self, from: data) {
            notes = decoded
        }
        selectedID = notes.first?.id
    }

    var filtered: [Note] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = notes.sorted { $0.updated > $1.updated }
        guard !q.isEmpty else { return sorted }
        return sorted.filter { $0.title.lowercased().contains(q) || $0.body.lowercased().contains(q) }
    }

    func note(_ id: UUID?) -> Note? { notes.first { $0.id == id } }

    @discardableResult
    func add() -> UUID {
        let n = Note(title: L("未命名筆記"), body: "", updated: Date())
        notes.append(n)
        selectedID = n.id
        search = ""
        scheduleSave()
        return n.id
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        if selectedID == id { selectedID = filtered.first?.id }
        NotePanel.shared.closeIfShowing(id)
        scheduleSave()
    }

    func update(_ id: UUID, title: String? = nil, body: String? = nil) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        if let title { notes[i].title = title }
        if let body { notes[i].body = body }
        notes[i].updated = Date()
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(notes) { try? data.write(to: url, options: .atomic) }
    }
}

/// 浮動顯示一則筆記（置頂；盡量不被錄影／畫面分享錄進去）
@MainActor
final class NotePanel: NSObject, NSWindowDelegate {
    static let shared = NotePanel()
    private var panel: NSPanel?
    private(set) var noteID: UUID?

    func show(_ id: UUID) {
        noteID = id
        let view = FloatingNoteView(store: .shared, loc: .shared, noteID: id)
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)  // 在畫圖疊加層之上
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            p.sharingType = .none
            p.delegate = self
            p.setFrameAutosaveName("TeachOverlayNotePanel")
            if p.frame.origin == .zero, let screen = NSScreen.main {
                p.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 380, y: screen.visibleFrame.maxY - 300))
            }
            panel = p
        }
        panel?.title = L("筆記")
        panel?.contentView = NSHostingView(rootView: view)
        panel?.keepOnScreen()
        panel?.orderFrontRegardless()
    }

    func closeIfShowing(_ id: UUID) {
        if noteID == id { panel?.close() }
    }

    func windowWillClose(_ notification: Notification) { noteID = nil }
}

struct FloatingNoteView: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var loc: Loc
    let noteID: UUID
    @ObservedObject private var prefs = FloatingNotePrefs.shared

    var body: some View {
        let note = store.note(noteID)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(note?.title ?? "").font(.headline).lineLimit(1)
                Spacer()
                Button { prefs.fontSize = max(prefs.fontSize - 2, 10) } label: { Text("A−") }
                    .buttonStyle(.borderless)
                Button { prefs.fontSize = min(prefs.fontSize + 2, 48) } label: { Text("A+") }
                    .buttonStyle(.borderless)
            }
            ScrollView {
                Text(note?.body ?? "")
                    .font(.system(size: prefs.fontSize))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(minWidth: 220, minHeight: 140)
    }
}

@MainActor
final class FloatingNotePrefs: ObservableObject {
    static let shared = FloatingNotePrefs()
    @Published var fontSize: Double = UserDefaults.standard.object(forKey: "note.font") as? Double ?? 16 {
        didSet { UserDefaults.standard.set(fontSize, forKey: "note.font") }
    }
}
