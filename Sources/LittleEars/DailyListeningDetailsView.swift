import SwiftUI

struct DailyListeningDetailsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @AppStorage("accent") private var accent = "blue"
    let day: ListeningCalendarDay
    @State private var details: DailyListeningDetails?
    @State private var loading = false
    @State private var error: String?
    @State private var selectedTrack: TrackDetailsTarget?
    var palette: Palette { Palette(dark: scheme == .dark, accentName: accent) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(day.date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().weekday())).font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.keyboardShortcut(.cancelAction).help("关闭")
            }
            Divider()
            HStack(spacing: 0) {
                metric("实际播放时长", (details?.seconds ?? 0) == 0 ? "0 分钟" : listeningLabel(details?.seconds ?? 0))
                metric("完整播放次数", "\(details?.completions ?? 0) 次")
                metric("不同音频", "\(details?.tracks.count ?? 0) 首")
            }
            Divider()
            HStack {
                Text("音频 / 目录"); Spacer()
                Text("实际时长").frame(width: 84, alignment: .trailing)
                Text("完整播放").frame(width: 70, alignment: .trailing)
            }.font(.system(size: 10)).foregroundStyle(palette.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(details?.tracks ?? []) { entry in
                        Button { selectedTrack = TrackDetailsTarget(id: entry.id, track: entry.track) } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.track?.title ?? "历史音频").font(.system(size: 12)).lineLimit(1)
                                    Text(entry.track.map { $0.folder.isEmpty ? "本地音频" : $0.folder } ?? "目录信息不可用").font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(timeLabel(entry.seconds)).font(.system(size: 11)).monospacedDigit().frame(width: 84, alignment: .trailing)
                                Text("\(entry.completions) 次").font(.system(size: 11)).monospacedDigit().frame(width: 70, alignment: .trailing)
                            }.frame(height: 44).contentShape(Rectangle())
                                .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 0.5).allowsHitTesting(false) }
                        }.buttonStyle(.plain).modifier(HoverHighlight()).help("查看收听统计")
                    }
                    if details?.tracks.isEmpty == true && !loading {
                        Text("这一天没有播放记录").font(.system(size: 12)).foregroundStyle(palette.secondary).padding(.top, 28)
                    }
                    if loading { ProgressView().controlSize(.small).padding(.top, 18) }
                }
            }.frame(maxHeight: .infinity)
            if let error { HStack { Text(error).font(.system(size: 10)); Spacer(); Button("重试") { Task { await load() } } } }
        }.padding(20).foregroundStyle(palette.text).background(palette.background).tint(palette.accent).buttonStyle(.bordered).controlSize(.small)
            .frame(minWidth: 520, idealWidth: 620, maxWidth: 620, minHeight: 420, idealHeight: 540, maxHeight: 540)
            .task { await load() }
            .sheet(item: $selectedTrack) { target in TrackStatisticsView(target: target).environmentObject(model).environment(\.colorScheme, scheme) }
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 10)).foregroundStyle(palette.secondary)
            Text(value).font(.system(size: 15, weight: .medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let result = try await model.dailyListeningDetails(day: day.id)
            guard !Task.isCancelled else { return }; details = result
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
