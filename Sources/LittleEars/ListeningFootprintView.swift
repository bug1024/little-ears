import SwiftUI
import AppKit

extension Palette {
    func footprintColor(level: Int) -> Color {
        let base = NSColor(Color(hex: dark ? 0x30353B : 0xE1E6EC)).usingColorSpace(.sRGB)!
        guard level > 0 else { return Color(nsColor: base) }
        let accent = NSColor(self.accent).usingColorSpace(.sRGB)!
        let amount: CGFloat = [0, 0.23, 0.43, 0.63, 0.83][min(4, max(0, level))]
        return Color(nsColor: NSColor(srgbRed: base.redComponent * (1 - amount) + accent.redComponent * amount,
            green: base.greenComponent * (1 - amount) + accent.greenComponent * amount,
            blue: base.blueComponent * (1 - amount) + accent.blueComponent * amount, alpha: 1))
    }
}
struct ListeningFootprintView: View {
    @EnvironmentObject var model: AppModel
    let palette: Palette
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var years: [Int] = []
    @State private var metric: ListeningHeatmapMetric = .duration
    @State private var data: [String: DailyListeningStat] = [:]
    @State private var error: String?
    @State private var loading = false
    @State private var loadRequest = UUID()
    @State private var loadedYear: Int?
    @FocusState private var focusedDay: String?
    private let size: CGFloat = 11
    private let gap: CGFloat = 3
    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }
    private struct RequestKey: Hashable { var year: Int; var day: String; var seconds: Double; var completions: Int }
    private var requestKey: RequestKey {
        let live = year == currentYear ? model.stats.days.last : nil
        return RequestKey(year: year, day: live?.day ?? "", seconds: live?.seconds ?? 0, completions: year == currentYear ? model.stats.completions : 0)
    }
    var body: some View {
        let grid = ListeningCalendar(year: year)
        let byPosition = Dictionary(uniqueKeysWithValues: grid.days.map { ($0.column * 7 + $0.row, $0) })
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("听力足迹").font(.system(size: 12, weight: .medium))
                if loading && loadedYear != year { ProgressView().controlSize(.mini) }
                Spacer(minLength: 6)
                Button { year -= 1 } label: { Image(systemName: "chevron.left") }.disabled(year <= 1).help("上一年")
                Picker("年份", selection: $year) {
                    ForEach(Array(Set(years + [year, currentYear])).sorted(by: >), id: \.self) { Text(String($0)).tag($0) }
                }.labelsHidden().frame(width: 76)
                Button { year += 1 } label: { Image(systemName: "chevron.right") }.disabled(year >= currentYear).help("下一年")
                Picker("统计指标", selection: $metric) { ForEach(ListeningHeatmapMetric.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            }.controlSize(.small)
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: gap) {
                    Color.clear.frame(width: 12, height: 16)
                    ForEach(0..<7) { row in Text(["一", "", "三", "", "五", "", ""][row]).font(.system(size: 9)).foregroundStyle(palette.secondary).frame(width: 12, height: size) }
                }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 0) {
                            ZStack(alignment: .topLeading) {
                                ForEach(grid.days.filter { Calendar.current.component(.day, from: $0.date) == 1 }) { day in
                                    Text("\(Calendar.current.component(.month, from: day.date))月").font(.system(size: 9)).foregroundStyle(palette.secondary)
                                        .offset(x: CGFloat(day.column) * (size + gap))
                                }
                            }.frame(width: CGFloat(grid.columns) * (size + gap), height: 19, alignment: .topLeading)
                            HStack(alignment: .top, spacing: gap) {
                                ForEach(0..<grid.columns, id: \.self) { column in
                                    VStack(spacing: gap) {
                                        ForEach(0..<7) { row in
                                            if let day = byPosition[column * 7 + row] {
                                                let value = data[day.id] ?? DailyListeningStat(day: day.id, seconds: 0, completions: 0)
                                                Button { model.listeningDayTarget = day } label: {
                                                    FootprintTile(palette: palette, level: metric.level(value), today: day.isToday, future: day.isFuture, focused: focusedDay == day.id)
                                                        .frame(width: size, height: size)
                                                }.buttonStyle(.plain).disabled(day.isFuture)
                                                    .focusable(!day.isFuture).focused($focusedDay, equals: day.id).focusEffectDisabled().id(day.id)
                                                    .help("\(day.date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day()))\n实际收听 \(listeningLabel(value.seconds))\n完整播放 \(value.completions) 次")
                                                    .accessibilityLabel("\(day.date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().weekday()))，实际收听 \(listeningLabel(value.seconds))，完整播放 \(value.completions) 次\(day.isFuture ? "，未来日期" : "")")
                                            } else { Color.clear.frame(width: size, height: size).accessibilityHidden(true) }
                                        }
                                    }
                                }
                            }.padding(.bottom, 3)
                        }
                    }.onChange(of: focusedDay) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
            HStack(spacing: 5) {
                Text("\(String(year)) 年 · \(metric.title)").font(.system(size: 10)).foregroundStyle(palette.secondary)
                Spacer()
                Text("少").font(.system(size: 9)).foregroundStyle(palette.secondary)
                ForEach(0..<5) { level in RoundedRectangle(cornerRadius: 2).fill(palette.footprintColor(level: level)).frame(width: 11, height: 11) }
                Text("多").font(.system(size: 9)).foregroundStyle(palette.secondary)
            }.help(metric == .duration ? "0；不足 15 分钟；15–30 分钟；30–60 分钟；60 分钟及以上" : "0；1–2 次；3–5 次；6–10 次；11 次及以上")
            if let error { HStack { Text(error).font(.system(size: 10)); Spacer(); Button("重试") { Task { await load() } } } }
        }.padding(16).modifier(PanelStyle(palette: palette))
            .task(id: requestKey) { await load() }
            .onKeyPress(.leftArrow) { moveFocus(-7, grid: grid) }
            .onKeyPress(.rightArrow) { moveFocus(7, grid: grid) }
            .onKeyPress(.upArrow) { moveFocus(-1, grid: grid) }
            .onKeyPress(.downArrow) { moveFocus(1, grid: grid) }
            .onKeyPress(.return) {
                guard let day = grid.days.first(where: { $0.id == focusedDay }), !day.isFuture else { return .ignored }
                model.listeningDayTarget = day; return .handled
            }
    }
    private func moveFocus(_ offset: Int, grid: ListeningCalendar) -> KeyPress.Result {
        guard let focusedDay else { return .ignored }
        if let next = grid.moving(from: focusedDay, dayOffset: offset) { self.focusedDay = next.id }
        return .handled
    }
    private func load() async {
        let requestedYear = year; let token = UUID(); loadRequest = token; loading = true; error = nil
        if loadedYear != year { data = [:] }
        defer { if loadRequest == token { loading = false } }
        do {
            let result = try await model.yearlyListeningStats(year: requestedYear)
            guard loadRequest == token, year == requestedYear, !Task.isCancelled else { return }
            data = Dictionary(uniqueKeysWithValues: result.days.map { ($0.day, $0) }); loadedYear = requestedYear; years = result.years.filter { $0 <= currentYear }
        } catch { if loadRequest == token && !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
private struct FootprintTile: View {
    let palette: Palette
    let level: Int
    let today: Bool
    let future: Bool
    let focused: Bool
    @State private var hovering = false
    var body: some View {
        RoundedRectangle(cornerRadius: 2).fill(future ? palette.background : palette.footprintColor(level: level))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(focused ? palette.accent : hovering ? palette.secondary : today ? palette.accent.opacity(0.55) : future ? palette.border : .clear, lineWidth: focused ? 1.5 : 0.75))
            .overlay { if future { Path { p in p.move(to: CGPoint(x: 3, y: 8)); p.addLine(to: CGPoint(x: 8, y: 3)) }.stroke(palette.secondary.opacity(0.18), lineWidth: 0.5) } }
            .onHover { hovering = $0 }
    }
}
