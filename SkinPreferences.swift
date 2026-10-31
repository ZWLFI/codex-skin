import AppKit
import SwiftUI

@MainActor
final class SkinPreferencesModel: ObservableObject {
    @Published var settings = BackgroundSettings.load() {
        didSet { if settings.imagePath != oldValue.imagePath { loadPreview() } }
    }
    @Published var image: NSImage?
    @Published var connected = false
    @Published var busy = false
    @Published var message: String?
    var onChange: ((BackgroundSettings) -> Void)?
    var chooseImage: () -> Void = {}
    var clearImage: () -> Void = {}
    var apply: () -> Void = {}
    var restart: () -> Void = {}

    init() { loadPreview() }

    private func loadPreview() {
        image = settings.imagePath.flatMap { NSImage(contentsOfFile: $0) }
    }

    func binding<Value>(_ key: WritableKeyPath<BackgroundSettings, Value>) -> Binding<Value> {
        Binding(get: { self.settings[keyPath: key] }, set: {
            self.settings[keyPath: key] = $0
            self.onChange?(self.settings)
        })
    }

    func preset(_ index: Int) {
        settings.resetLayout()
        if index == 1 { settings.railScale = 0.7; settings.topScale = 0.75; settings.contentScale = 1.25 }
        if index == 2 { settings.hideRail = true; settings.hideTopBar = true; settings.contentScale = 1.5 }
        onChange?(settings)
    }
}

struct SkinPreferencesView: View {
    @ObservedObject var model: SkinPreferencesModel
    private let accent = Color(red: 0.24, green: 0.43, blue: 0.93)

    var body: some View {
        HStack(spacing: 0) {
            overview.frame(width: 260)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("让工作空间更合心意").font(.system(size: 21, weight: .semibold))
                        Text("外观与布局").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(model.busy ? "应用中" : model.connected ? "已连接" : "待连接",
                          systemImage: model.busy ? "arrow.triangle.2.circlepath" : "circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(model.connected ? Color.green : Color.orange)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                }.padding(24)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        section("背景", icon: "photo") {
                            HStack {
                                Text(model.settings.imagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "尚未选择背景")
                                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                                Spacer()
                                Button("选择图片…", action: model.chooseImage)
                            }
                            Picker("显示方式", selection: model.binding(\.layout)) {
                                ForEach(BackgroundLayout.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                            }
                            slider("背景不透明度", key: \.opacity, range: 0.05...1)
                            HStack {
                                Text("数值越高，图片越清晰").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("清除背景", action: model.clearImage).buttonStyle(.link)
                                    .disabled(model.settings.imagePath == nil)
                            }
                        }
                        section("布局", icon: "rectangle.3.group") {
                            HStack(spacing: 8) {
                                ForEach(Array(["标准", "紧凑", "专注"].enumerated()), id: \.offset) { index, title in
                                    Button { model.preset(index) } label: { Text(title).frame(maxWidth: .infinity) }
                                }
                            }.controlSize(.large)
                            toggle("隐藏最左侧导航栏", key: \.hideRail)
                            slider("导航栏宽度", key: \.railScale, range: 0.5...1).disabled(model.settings.hideRail)
                            toggle("隐藏顶部栏", key: \.hideTopBar)
                            slider("顶部栏高度", key: \.topScale, range: 0.5...1).disabled(model.settings.hideTopBar)
                            slider("对话与输入框宽度", key: \.contentScale, range: 1...2)
                            Text("隐藏后可从系统菜单栏恢复；会话列表保留。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        section("连接", icon: "link") {
                            toggle("自动恢复连接", key: \.autoRestart)
                            Text("接口不可用时允许重启 Codex；重启会中断正在运行的任务。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let message = model.message {
                                Text(message).font(.caption).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 20)
                }
                Divider()
                HStack {
                    Label("自动保存", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("重新应用", action: model.apply)
                    Button("启动 / 重启并应用", action: model.restart).buttonStyle(.borderedProminent)
                }.disabled(model.busy).padding(18)
            }.frame(width: 500)
        }.frame(width: 760, height: 650)
            .background(Color(nsColor: .windowBackgroundColor)).tint(accent)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let icon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: icon).resizable().frame(width: 64, height: 64)
            }
            Text("Codex Skin").font(.system(size: 27, weight: .semibold, design: .rounded))
            Text("你的空间，你的节奏。")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
            Spacer(minLength: 24)
            preview
            Text("布局预览").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 24)
            Button { model.preset(0) } label: {
                Label("恢复栏位与默认尺寸", systemImage: "arrow.counterclockwise")
            }.buttonStyle(.plain).font(.system(size: 12))
            Text("背景图片与透明度将保留")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            Divider().overlay(.white.opacity(0.15))
            Text("VERSION \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.8.0")")
                .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
        }.padding(26).frame(maxHeight: .infinity).foregroundStyle(.white)
            .background(LinearGradient(colors: [Color(red: 0.10, green: 0.14, blue: 0.24), Color(red: 0.06, green: 0.08, blue: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var preview: some View {
        ZStack {
            Color(red: 0.15, green: 0.21, blue: 0.32)
            if let image = model.image {
                GeometryReader { geometry in
                    previewImage(image).frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped().opacity(model.settings.opacity)
                }
            }
            HStack(spacing: 0) {
                if !model.settings.hideRail {
                    VStack(spacing: 12) {
                        Image(systemName: "square.stack.3d.up")
                        Image(systemName: "plus")
                        Spacer()
                        Image(systemName: "gearshape")
                    }.font(.system(size: 9)).padding(.vertical, 12)
                        .frame(width: 26 * model.settings.railScale).background(.black.opacity(0.2))
                }
                VStack(spacing: 0) {
                    if !model.settings.hideTopBar {
                        HStack { Circle().frame(width: 4, height: 4); Text("Workspace").font(.system(size: 8)); Spacer() }
                            .padding(.horizontal, 10).frame(height: 28 * model.settings.topScale).background(.black.opacity(0.16))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.65)).frame(height: 6)
                        RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.25)).frame(height: 5)
                        RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.25)).frame(width: 60, height: 5)
                        Spacer()
                        RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.18)).frame(height: 32)
                    }.padding(.vertical, 22).padding(.horizontal, max(10, 34 - 16 * model.settings.contentScale))
                }
            }.foregroundStyle(.white.opacity(0.8))
        }.frame(height: 190).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.16)))
            .accessibilityLabel("布局示意图")
    }

    @ViewBuilder private func previewImage(_ image: NSImage) -> some View {
        switch model.settings.layout {
        case .fill: Image(nsImage: image).resizable().scaledToFill()
        case .fit: Image(nsImage: image).resizable().scaledToFit()
        case .stretch: Image(nsImage: image).resizable()
        case .tile: Image(nsImage: image).resizable(resizingMode: .tile)
        case .center: Image(nsImage: image)
        }
    }

    private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold))
            content()
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06)))
    }

    private func slider(_ title: String, key: WritableKeyPath<BackgroundSettings, Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 4) {
            HStack { Text(title); Spacer(); Text("\(Int((model.settings[keyPath: key] * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: Binding(get: { model.settings[keyPath: key] }, set: {
                model.binding(key).wrappedValue = ($0 * 100).rounded() / 100
            }), in: range).accessibilityLabel(title)
        }.font(.system(size: 12))
    }

    private func toggle(_ title: String, key: WritableKeyPath<BackgroundSettings, Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: model.binding(key)).labelsHidden().toggleStyle(.switch)
        }
    }
}
