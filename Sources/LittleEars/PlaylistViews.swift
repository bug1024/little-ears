import SwiftUI
import UniformTypeIdentifiers

struct PlaylistNameSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) private var scheme
    @AppStorage("accent") private var accent = "blue"
    @AppStorage("appearance") private var appearance = "system"
    var palette: Palette { Palette(dark: scheme == .dark, accentName: accent) }
    let draft: PlaylistDraft
    @State private var name: String
    @State private var error: String?
    @State private var saving = false
    init(draft: PlaylistDraft) { self.draft = draft; _name = State(initialValue: draft.name) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(draft.playlistID == nil ? "新建播放列表" : "重命名播放列表").font(.title3.weight(.semibold))
            TextField("例如：每天听一遍", text: $name).textFieldStyle(.plain).padding(10).modifier(MaterialSurface(palette: palette, radius: 7, inset: true)).onSubmit(save)
            if draft.playlistID == nil {
                Text(draft.trackIDs.isEmpty ? "创建后，可从音乐库多选歌曲加入。" : "按当前顺序保存 \(draft.trackIDs.count) 首音频。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? "正在保存…" : "保存", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.savingPlaylists)
            }
        }.padding(25).frame(width: 380).foregroundStyle(palette.text).background(palette.background).buttonStyle(.bordered)
            .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
    }
    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                if let id = draft.playlistID, let playlist = model.playlists.first(where: { $0.id == id }) {
                    try await model.renamePlaylist(playlist, name: name)
                } else { try await model.createPlaylist(name: name, trackIDs: draft.trackIDs) }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Selection is resolved against visible rows so a single unselected context-click targets that row.
struct AddToPlaylistMenu: View {
    @EnvironmentObject var model: AppModel
    let trackIDs: [String]
    var body: some View {
        Menu {
            Button("新建播放列表…") { model.draftPlaylist(trackIDs: trackIDs) }
            if !model.playlists.isEmpty {
                Divider()
                ForEach(model.playlists) { playlist in
                    Button(playlist.name) {
                        Task {
                            do { try await model.appendTracks(trackIDs, to: playlist) }
                            catch { model.errorMessage = error.localizedDescription }
                        }
                    }
                }
            }
        } label: { Label("加入播放列表", systemImage: "text.badge.plus") }
            .disabled(trackIDs.isEmpty || model.savingPlaylists || !model.ready)
    }
}
struct SaveQueueMenu: View {
    @EnvironmentObject var model: AppModel
    @State private var replacing: Playlist?
    var body: some View {
        Menu {
            Button("另存为新播放列表…") { model.draftPlaylist(trackIDs: model.queue.map(\.trackID)) }
            if !model.playlists.isEmpty {
                Menu("覆盖已有播放列表") {
                    ForEach(model.playlists) { playlist in Button(playlist.name) { replacing = playlist } }
                }
            }
        } label: { Label("保存队列", systemImage: "square.and.arrow.down") }
            .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
            .disabled(model.queue.isEmpty || model.savingPlaylists)
            .alert("保存到「\(replacing?.name ?? "")」？", isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } })) {
                Button("取消", role: .cancel) { replacing = nil }
                Button("保存") {
                    guard let playlist = replacing else { return }
                    let trackIDs = model.queue.map(\.trackID)
                    replacing = nil
                    Task {
                        do { try await model.replacePlaylistTracks(playlist, trackIDs: trackIDs) }
                        catch { model.errorMessage = error.localizedDescription }
                    }
                }
            } message: { Text("将用当前队列的歌曲和顺序替换这个播放列表。正在播放的音频会继续播放。") }
    }
}
struct PlaylistsView: View {
    @EnvironmentObject var model: AppModel
    let palette: Palette
    @State private var selection = Set<String>()
    @State private var deleting = false
    var playlist: Playlist? { model.selectedPlaylist }
    var entries: [PlaylistItem] { playlist.map { model.items(in: $0.id) } ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: playlist?.name ?? "播放列表", detail: playlist.map { _ in "\(entries.count) 首" } ?? "", palette: palette) {
                Button { model.draftPlaylist() } label: { Label("新建列表", systemImage: "plus") }.disabled(model.savingPlaylists || !model.ready)
            }
            if let playlist {
                HStack(spacing: 10) {
                    Button { model.playPlaylist(playlist) } label: { Label("播放", systemImage: "play.fill") }.disabled(entries.isEmpty)
                    Button { model.page = "library" } label: { Label("添加歌曲", systemImage: "plus") }
                    Button(role: .destructive) { remove(selection, from: playlist) } label: {
                        Label("移除所选", systemImage: "minus.circle")
                    }.disabled(selection.isEmpty || model.savingPlaylists).help("只从此播放列表移除选中条目，保留音频文件")
                    Spacer()
                    if model.savingPlaylists { ProgressView().controlSize(.small) }
                    Menu {
                        Button("重命名…") { model.playlistDraft = PlaylistDraft(playlistID: playlist.id, name: playlist.name) }
                        Button("删除播放列表…", role: .destructive) { deleting = true }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().disabled(model.savingPlaylists).help("管理播放列表：重命名或删除")
                }.font(.system(size: 11)).padding(.horizontal, 20).frame(height: 42)
                if entries.isEmpty { emptyState("这个列表还没有歌曲", detail: "到音乐库中多选音频，点击「加入播放列表」。") }
                else {
                    TableColumnHeader(palette: palette).padding(.horizontal, 20)
                    List(selection: $selection) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, item in
                            row(item, index: index).tag(item.id).listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
                                .onDrop(of: [.text], isTargeted: nil) { providers in
                                    guard !model.savingPlaylists, let provider = providers.first else { return false }
                                    _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                                        guard let id = object as? String else { return }
                                        Task { @MainActor in
                                            let items = model.items(in: playlist.id)
                                            guard let from = items.firstIndex(where: { $0.id == id }), let to = items.firstIndex(where: { $0.id == item.id }), from != to else { return }
                                            do { try await model.movePlaylistItems(in: playlist, from: IndexSet(integer: from), to: from < to ? to + 1 : to) }
                                            catch { model.errorMessage = error.localizedDescription }
                                        }
                                    }
                                    return true
                                }
                        }
                    }.contextMenu(forSelectionType: String.self) { ids in
                        Button("从这里播放") {
                            if let item = entries.first(where: { ids.contains($0.id) }) { model.playPlaylist(playlist, at: item.id) }
                        }.disabled(ids.isEmpty)
                        Button(ids.count > 1 ? "移除所选 \(ids.count) 首" : "从列表移除", role: .destructive) { remove(ids, from: playlist) }
                            .disabled(ids.isEmpty || model.savingPlaylists)
                        if ids.count == 1, let item = entries.first(where: { ids.contains($0.id) }), let track = model.tracks.first(where: { $0.id == item.trackID }) {
                            Button("在 Finder 中显示") { model.reveal(track) }
                        }
                    } primaryAction: { ids in
                        if let item = entries.first(where: { ids.contains($0.id) }) { model.playPlaylist(playlist, at: item.id) }
                    }
                    .onDeleteCommand { remove(selection, from: playlist) }
                    .listStyle(.plain).scrollContentBackground(.hidden).contentMargins(.horizontal, 0, for: .scrollContent).modifier(MaterialSurface(palette: palette, radius: 9, inset: true)).padding(.horizontal, 12).padding(.bottom, 8)
                    HStack {
                        Text(selection.isEmpty ? "⌘ 点击多选 · Shift 连选 · 拖动左侧手柄排序" : "已选择 \(selection.count) 首")
                        Button(selection.isEmpty ? "全选" : "取消选择") {
                            selection = selection.isEmpty ? Set(entries.map(\.id)) : []
                        }.buttonStyle(.plain).foregroundStyle(palette.accent)
                        Spacer()
                        Text("\(entries.count) 首音频")
                    }.font(.system(size: 10)).foregroundStyle(palette.secondary).padding(.horizontal, 20).frame(height: 27)
                        .overlay(alignment: .top) { Rectangle().fill(palette.border).frame(height: 1) }
                }
            } else { emptyState("没有播放列表", detail: "新建列表，或保存当前播放队列。") }
        }
            .onChange(of: playlist?.id) { _, _ in selection.removeAll() }
            .onChange(of: entries.map(\.id)) { _, ids in selection.formIntersection(ids) }
            .alert("删除「\(playlist?.name ?? "")」？", isPresented: $deleting) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    guard let playlist else { return }
                    Task {
                        do { try await model.deletePlaylist(playlist) }
                        catch { model.errorMessage = error.localizedDescription }
                    }
                }
            } message: { Text("只删除播放列表，原始音频、播放记录和当前队列都会保留。") }
    }
    private func remove(_ ids: Set<String>, from playlist: Playlist) {
        guard !ids.isEmpty, !model.savingPlaylists else { return }
        Task {
            do { try await model.removePlaylistItems(in: playlist, ids: ids); selection.subtract(ids) }
            catch { model.errorMessage = error.localizedDescription }
        }
    }
    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "music.note.list").font(.system(size: 30, weight: .light)).foregroundStyle(palette.accent)
            Text(title).font(.system(size: 17, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(palette.secondary).multilineTextAlignment(.center)
            Spacer()
        }.frame(maxWidth: .infinity)
    }
    private func row(_ item: PlaylistItem, index: Int) -> some View {
        let track = model.tracks.first { $0.id == item.trackID }
        return TrackTableRow(palette: palette, index: index, title: track?.title ?? "音频不可用",
                             origin: track.map { $0.available ? ($0.folder.isEmpty ? "本地音频" : $0.folder) : "文件不可用" } ?? "记录不可用",
                             duration: track?.duration ?? 0, format: track?.format ?? "—", selected: selection.contains(item.id), draggable: true, dragItemID: item.id)
    }
}
