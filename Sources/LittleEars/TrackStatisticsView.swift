import SwiftUI
import Charts

struct TrackStatisticsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @AppStorage("accent") private var accent = "blue"
    let target: TrackDetailsTarget
    @State private var period: TrackStatisticsPeriod = .week
    @State private var summary = TrackStatistics.empty
    @State private var days: [DailyStat] = []
    @State private var records: [TrackListeningRecord] = []
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?
    @State private var request = UUID()
    @State private var selectedDay: String?
    @State private var queryDate = Date()
    var palette: Palette { Palette(dark: scheme == .dark, accentName: accent) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(target.track?.title ?? "历史音频").font(.system(size: 16, weight: .semibold)).lineLimit(2)
                    Text(target.track.map { $0.folder.isEmpty ? "本地音频" : $0.folder } ?? "目录信息不可用")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
                    Text(target.track.map { "\(timeLabel($0.duration)) · \($0.format)\($0.available ? "" : " · 文件不可用")" } ?? "音频信息不可用")
                        .font(.system(size: 10)).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 0)
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.disabled(loading).help("刷新收听统计")
                Button { dismiss() } label: { Image(systemName: "xmark") }.keyboardShortcut(.cancelAction).help("关闭")
            }
            Divider()
            HStack(alignment: .top, spacing: 0) {
                metric("完整播放次数", "\(summary.completions) 次")
                metric("累计播放时长", summary.seconds == 0 ? "0 分钟" : listeningLabel(summary.seconds))
                metric("最近播放", summary.lastPlayedAt.map(listeningDateLabel) ?? "暂无记录", small: true)
                metric("累计播放天数", "\(summary.listeningDays) 天")
            }
            Divider()
            HStack {
                Text("收听趋势").font(.system(size: 12, weight: .medium))
                Spacer()
                Picker("时间范围", selection: $period) { ForEach(TrackStatisticsPeriod.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 230)
            }
            if days.isEmpty {
                Text(loading ? "正在读取收听记录…" : "所选范围暂无收听记录")
                    .font(.system(size: 11)).foregroundStyle(palette.secondary).frame(maxWidth: .infinity).frame(height: 100)
            } else {
                Chart(chartDays) { day in
                    BarMark(x: .value("日期", day.day), y: .value("分钟", day.seconds / 60)).foregroundStyle(palette.accent.opacity(0.7)).cornerRadius(2)
                    if selectedDay == day.day { RuleMark(x: .value("日期", day.day)).foregroundStyle(palette.secondary.opacity(0.5)) }
                }.chartXSelection(value: $selectedDay)
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { AxisValueLabel().font(.system(size: 9)) } }
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)); AxisValueLabel().font(.system(size: 9)) } }
                    .frame(height: 100)
                Text(selectedDay.flatMap { day in chartDays.first { $0.day == day }.map { "\(day) · 实际播放 \(timeLabel($0.seconds))" } } ?? "点击或拖动图表查看每日时长 · 范围合计 \(listeningLabel(days.reduce(0) { $0 + $1.seconds }))")
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(palette.secondary).lineLimit(1)
            }
            HStack {
                Text("播放时间").frame(maxWidth: .infinity, alignment: .leading)
                Text("实际时长").frame(width: 90, alignment: .trailing)
                Text("结果").frame(width: 60, alignment: .trailing)
            }.font(.system(size: 10)).foregroundStyle(palette.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(records) { record in
                        HStack {
                            Text(listeningDateLabel(record.startedAt)).frame(maxWidth: .infinity, alignment: .leading)
                            Text(timeLabel(record.seconds)).frame(width: 90, alignment: .trailing)
                            Text(record.completed ? "完整" : "部分").foregroundStyle(record.completed ? palette.accent : palette.secondary).frame(width: 60, alignment: .trailing)
                        }.font(.system(size: 11)).monospacedDigit().frame(height: 31)
                            .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 0.5).allowsHitTesting(false) }
                    }
                    if hasMore { Button(loading ? "正在加载…" : "加载更多") { Task { await loadMore() } }.disabled(loading).padding(.top, 9) }
                    if records.isEmpty && !loading { Text("暂无播放记录").font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.top, 12) }
                }
            }.frame(maxHeight: .infinity)
            if let error { HStack { Text(error).lineLimit(2); Spacer(); Button("重试") { Task { await load() } } }.font(.system(size: 10)).foregroundStyle(palette.secondary) }
        }.padding(20).foregroundStyle(palette.text).background(palette.background).tint(palette.accent)
            .buttonStyle(.bordered).controlSize(.small)
            .frame(minWidth: 520, idealWidth: 620, maxWidth: 620, minHeight: 420, idealHeight: 540, maxHeight: 540)
            .task(id: period) { await load() }
    }
    private func metric(_ title: String, _ value: String, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10)).foregroundStyle(palette.secondary)
            Text(value).font(.system(size: small ? 11 : 15, weight: .medium)).monospacedDigit().lineLimit(2).help(value)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var chartDays: [DailyStat] {
        guard period != .all else { return days }
        let calendar = Calendar.current
        return (0..<period.rawValue).reversed().map { offset in
            let day = ListeningClock.day(calendar.date(byAdding: .day, value: -offset, to: queryDate)!)
            return days.first { $0.day == day } ?? DailyStat(day: day, seconds: 0)
        }
    }
    private func load() async {
        let token = UUID(); request = token; loading = true; error = nil; selectedDay = nil; records = []; days = []; hasMore = false
        queryDate = Date()
        defer { if request == token { loading = false } }
        do {
            let result = try await model.trackStatistics(target.id, startDay: period.startDay(now: queryDate), endDay: ListeningClock.day(queryDate))
            guard request == token, !Task.isCancelled else { return }
            summary = result.summary; days = result.days; records = result.history.records; hasMore = result.history.hasMore
        } catch { if request == token && !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func loadMore() async {
        guard !loading, hasMore, let last = records.last else { return }
        let token = request; loading = true
        defer { if request == token { loading = false } }
        do {
            let page = try await model.trackHistory(target.id, startDay: period.startDay(now: queryDate), endDay: ListeningClock.day(queryDate), before: TrackHistoryCursor(last))
            guard request == token, !Task.isCancelled else { return }
            records.append(contentsOf: page.records); hasMore = page.hasMore
        } catch { if request == token { self.error = error.localizedDescription } }
    }
}
