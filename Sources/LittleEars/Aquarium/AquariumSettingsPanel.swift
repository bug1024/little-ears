import SwiftUI

struct AquariumSettingsPanel: View {
    @ObservedObject var controller: AquariumController
    @Environment(\.dismiss) var dismiss
    @State private var draft: AquariumConfiguration
    @State private var search = ""
    init(controller: AquariumController) {
        self.controller = controller
        _draft = State(initialValue: controller.configuration)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("水族箱场景").font(.title3.weight(.semibold)); Spacer(); Text("\(draft.totalFish) / 40 条鱼").foregroundStyle(.secondary).monospacedDigit() }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("水母") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("海月水母")
                                Spacer()
                                Text("\(draft.moonJellyCount) 只").monospacedDigit()
                                Stepper("海月水母数量", value: $draft.moonJellyCount, in: 0...5).labelsHidden()
                            }

                        }.padding(8)
                    }
                    GroupBox("鱼群") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("搜索鱼种", text: $search).textFieldStyle(.roundedBorder)
                                Button("全部鱼种") { draft.fishCounts = Dictionary(uniqueKeysWithValues: (300...327).map { ($0, 1) }) }
                                Button("清空") { draft.fishCounts = [:] }
                            }
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(controller.catalog.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { species in
                                        HStack {
                                            Text(species.name).lineLimit(1)
                                            Spacer()
                                            Text("\(draft.fishCounts[species.id] ?? 0)").monospacedDigit().frame(width: 20)
                                            Stepper(species.name, value: countBinding(species.id), in: 0...min(3, AquariumConfiguration.maximumFish - draft.totalFish + (draft.fishCounts[species.id] ?? 0)))
                                                .labelsHidden().accessibilityLabel("\(species.name) 数量")
                                        }.frame(height: 28).padding(.horizontal, 4)
                                        Divider()
                                    }
                                }
                            }.frame(height: 205)
                            HStack { Toggle("洞穴海鳗", isOn: $draft.showMoray); Spacer(); Toggle("沙地海星", isOn: $draft.showStarfish) }
                        }.padding(8)
                    }
                    GroupBox("画面") {
                        VStack(spacing: 10) {
                            HStack { Text("背板"); Spacer(); Picker("背板", selection: $draft.blueBackdrop) { Text("蓝黑").tag(false); Text("纯蓝").tag(true) }.labelsHidden().pickerStyle(.segmented).frame(width: 190) }
                            HStack { Toggle("气泡", isOn: $draft.bubbles); Spacer(); Toggle("水波光纹", isOn: $draft.caustics) }
                            HStack { Text("绘制质量"); Spacer(); Picker("绘制质量", selection: $draft.energySaving) { Text("标准 · 30 fps").tag(false); Text("省电 · 24 fps").tag(true) }.labelsHidden().frame(width: 190) }
                        }.padding(8)
                    }
                    GroupBox("环境音") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("气泡环境音", isOn: $draft.ambientEnabled)
                            HStack { Text("音量"); Slider(value: $draft.ambientVolume, in: 0...1).accessibilityLabel("环境音音量"); Text("\(Int((draft.ambientVolume * 100).rounded()))%").monospacedDigit().frame(width: 34) }.disabled(!draft.ambientEnabled)
                            Toggle("音乐播放时降低环境音", isOn: $draft.duckDuringPlayback).disabled(!draft.ambientEnabled)
                            Text("只在水族箱页面可见时播放；切换页面、隐藏窗口和睡眠定时结束时停止。").font(.caption).foregroundStyle(.secondary)
                        }.padding(8)
                    }
                    if let error = controller.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(20)
            }
            Divider()
            HStack {
                Button("恢复默认") { draft = AquariumConfiguration() }
                Spacer()
                if controller.applying { ProgressView().controlSize(.small) }
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用") { Task { if await controller.apply(draft) { dismiss() } } }.keyboardShortcut(.defaultAction).disabled(controller.applying || controller.loading || controller.renderer == nil)
            }.padding(16)
        }.frame(width: 560, height: 650).font(.system(size: 12))
            .task { await controller.prepare() }
            .onChange(of: controller.configuration.ambientEnabled) { _, enabled in draft.ambientEnabled = enabled }
    }
    private func countBinding(_ id: Int) -> Binding<Int> {
        Binding(get: { draft.fishCounts[id] ?? 0 }, set: { draft.fishCounts[id] = $0 })
    }
}
