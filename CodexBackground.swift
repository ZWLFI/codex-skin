import AppKit
import Foundation
import UniformTypeIdentifiers
import SwiftUI

private let debugPort = 9342
private let codexBundleIdentifier = "com.openai.codex"

enum BackgroundLayout: String, CaseIterable {
    case fill
    case fit
    case stretch
    case tile
    case center

    var title: String {
        switch self {
        case .fill: return "填充"
        case .fit: return "适应"
        case .stretch: return "拉伸"
        case .tile: return "平铺"
        case .center: return "居中"
        }
    }

    var css: (size: String, repeatMode: String, position: String) {
        switch self {
        case .fill: return ("cover", "no-repeat", "center")
        case .fit: return ("contain", "no-repeat", "center")
        case .stretch: return ("100% 100%", "no-repeat", "center")
        case .tile: return ("auto", "repeat", "top left")
        case .center: return ("auto", "no-repeat", "center")
        }
    }
}

struct BackgroundSettings {
    var imagePath: String?
    var opacity: Double
    var layout: BackgroundLayout
    var railScale: Double = 1
    var topScale: Double = 1
    var contentScale: Double = 1
    var autoRestart: Bool = true
    var hideRail: Bool = false
    var hideTopBar: Bool = false

    var hasCustomization: Bool {
        imagePath != nil || hideRail || hideTopBar || railScale != 1 || topScale != 1 || contentScale != 1
    }

    mutating func resetLayout() {
        hideRail = false
        hideTopBar = false
        railScale = 1
        topScale = 1
        contentScale = 1
    }

    static func load(from defaults: UserDefaults = .standard) -> BackgroundSettings {
        let savedOpacity = defaults.object(forKey: "backgroundOpacity") as? NSNumber
        return BackgroundSettings(
            imagePath: defaults.string(forKey: "backgroundImagePath"),
            opacity: min(1, max(0.05, savedOpacity?.doubleValue ?? 0.65)),
            layout: BackgroundLayout(rawValue: defaults.string(forKey: "backgroundLayout") ?? "fill") ?? .fill,
            railScale: min(1, max(0.5, (defaults.object(forKey: "railScale") as? NSNumber)?.doubleValue ?? 1)),
            topScale: min(1, max(0.5, (defaults.object(forKey: "topScale") as? NSNumber)?.doubleValue ?? 1)),
            contentScale: min(2, max(1, (defaults.object(forKey: "contentScale") as? NSNumber)?.doubleValue ?? 1)),
            autoRestart: defaults.object(forKey: "autoRestartCodex") == nil ? true : defaults.bool(forKey: "autoRestartCodex"),
            hideRail: defaults.bool(forKey: "hideRail"),
            hideTopBar: defaults.bool(forKey: "hideTopBar")
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(imagePath, forKey: "backgroundImagePath")
        defaults.set(opacity, forKey: "backgroundOpacity")
        defaults.set(layout.rawValue, forKey: "backgroundLayout")
        defaults.set(railScale, forKey: "railScale")
        defaults.set(topScale, forKey: "topScale")
        defaults.set(contentScale, forKey: "contentScale")
        defaults.set(autoRestart, forKey: "autoRestartCodex")
        defaults.set(hideRail, forKey: "hideRail")
        defaults.set(hideTopBar, forKey: "hideTopBar")
    }
}

enum BackgroundError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case let .message(message) = self { return message }
        return nil
    }
}

enum BackgroundStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CodexBackground", isDirectory: true)
    }()

    static func importImage(from source: URL) throws -> URL {
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 25 * 1024 * 1024 else {
            throw BackgroundError.message("图片必须是不大于 25 MB 的普通文件")
        }
        guard NSImage(contentsOf: source) != nil else {
            throw BackgroundError.message("无法读取该图片")
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = source.pathExtension.lowercased().isEmpty ? "img" : source.pathExtension.lowercased()
        let destination = directory.appendingPathComponent("background.\(ext)")
        let temporary = directory.appendingPathComponent("background-\(UUID().uuidString).tmp")
        try FileManager.default.copyItem(at: source, to: temporary)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        return destination
    }
}

private struct CDPTarget: Decodable {
    let type: String
    let url: String
    let webSocketDebuggerUrl: String?

    var isAppWindow: Bool {
        guard type == "page", let page = URLComponents(string: url), page.scheme == "app",
              page.host == "-", ["/index.html", "/detached-window.html"].contains(page.path),
              !(page.queryItems ?? []).contains(where: { $0.name == "initialRoute" && $0.value == "/avatar-overlay" }),
              let socket = webSocketDebuggerUrl.flatMap(URL.init(string:)),
              socket.scheme == "ws", socket.host == "127.0.0.1", socket.port == debugPort else { return false }
        return true
    }
}

// Allow one automatic restart per process after three refused connections.
struct RecoveryGate {
    var process: Int32?
    var failures = 0
    var attempted = Set<Int32>()

    mutating func shouldRecover(process pid: Int32?, portMissing: Bool) -> Bool {
        if process != pid { process = pid; failures = 0 }
        guard let pid, portMissing else { failures = 0; return false }
        failures += 1
        guard failures >= 3, !attempted.contains(pid) else { return false }
        attempted.insert(pid)
        return true
    }
}

final class CodexInjector {
    var statusChanged: ((Bool, String?, Bool) -> Void)?

    private let queue = DispatchQueue(label: "codex-background.injector", qos: .utility)
    private let session: URLSession
    private var timer: DispatchSourceTimer?
    private var cachedImage: (path: String, modified: Date, dataURL: String)?
    private var lastScript: String?
    private var appliedTargets = Set<String>()
    @MainActor private var pendingApply: DispatchWorkItem?

    static let probeScript = """
    (() => {
      const state = window.__codexSkinState;
      const valid = document.querySelector('[data-app-shell-frame]') && state &&
        state.nodes.every(node => node.isConnected) &&
        (document.documentElement.getAttribute('data-codex-background') === 'active') === state.active;
      return valid ? { active: state.active } : { ready: false };
    })()
    """

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 15
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 4)
        timer.setEventHandler { [weak self] in _ = self?.inject(reportStatus: true) }
        timer.resume()
        self.timer = timer
    }

    func applyNow(completion: ((Int) -> Void)? = nil) {
        queue.async { [weak self] in
            let count = self?.inject(reportStatus: true) ?? 0
            if let completion { DispatchQueue.main.async { completion(count) } }
        }
    }

    @MainActor func scheduleApply(completion: ((Int) -> Void)? = nil) {
        pendingApply?.cancel()
        let work = DispatchWorkItem { [weak self] in
            let count = self?.inject(reportStatus: true) ?? 0
            if let completion { DispatchQueue.main.async { completion(count) } }
        }
        pendingApply = work
        queue.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func waitAndApply(timeout: TimeInterval = 45, completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if self.inject(reportStatus: false) > 0 {
                    DispatchQueue.main.async { completion(true) }
                    return
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            DispatchQueue.main.async { completion(false) }
        }
    }

    private func inject(reportStatus: Bool) -> Int {
        do {
            let targets = try fetchTargets()
            let settings = BackgroundSettings.load()
            let image = try settings.imagePath.map(makeDataURL)
            let script = Self.injectionScript(settings: settings, imageDataURL: image)
            if script != lastScript {
                appliedTargets.removeAll()
                lastScript = script
            }
            appliedTargets.formIntersection(targets.compactMap(\.webSocketDebuggerUrl))
            let applied = targets.filter { target in
                guard let raw = target.webSocketDebuggerUrl, let url = URL(string: raw) else { return false }
                if appliedTargets.contains(raw), evaluate(Self.probeScript, at: url) { return true }
                let succeeded = evaluate(script, at: url)
                if succeeded { appliedTargets.insert(raw) } else { appliedTargets.remove(raw) }
                return succeeded
            }.count
            if reportStatus {
                DispatchQueue.main.async { [weak self] in
                    self?.statusChanged?(applied > 0, applied > 0 ? nil : "背景接口已连接，等待主窗口加载或重新应用", false)
                }
            }
            return applied
        } catch {
            if reportStatus {
                let portMissing = (error as? URLError)?.code == .cannotConnectToHost
                DispatchQueue.main.async { [weak self] in
                    self?.statusChanged?(false, portMissing ? "Codex 背景接口未开启" : error.localizedDescription, portMissing)
                }
            }
            return 0
        }
    }

    private func fetchTargets() throws -> [CDPTarget] {
        let url = URL(string: "http://127.0.0.1:\(debugPort)/json/list")!
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data = try synchronousData(for: request)
        return try JSONDecoder().decode([CDPTarget].self, from: data).filter {
            $0.isAppWindow
        }
    }

    private func synchronousData(for request: URLRequest) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { result = .failure(error); return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
                result = .failure(BackgroundError.message("Codex 未开启背景接口"))
                return
            }
            result = .success(data)
        }.resume()
        guard semaphore.wait(timeout: .now() + 3) == .success, let result else {
            throw BackgroundError.message("连接 Codex 超时")
        }
        return try result.get()
    }

    private func evaluate(_ expression: String, at url: URL) -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let socket = session.webSocketTask(with: request)
        let semaphore = DispatchSemaphore(value: 0)
        var succeeded = false
        socket.resume()

        let message: [String: Any] = [
            "id": 1,
            "method": "Runtime.evaluate",
            "params": ["expression": expression, "returnByValue": true]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else {
            socket.cancel(with: .invalid, reason: nil)
            return false
        }
        func receiveResponse() {
            socket.receive { result in
                if case let .success(message) = result,
                   case let .string(text) = message,
                   let data = text.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    guard object["id"] as? Int == 1 else { receiveResponse(); return }
                    succeeded = Self.evaluationSucceeded(object)
                }
                semaphore.signal()
            }
        }
        socket.send(.string(json)) { error in
            guard error == nil else { semaphore.signal(); return }
            receiveResponse()
        }
        _ = semaphore.wait(timeout: .now() + 12)
        socket.cancel(with: .normalClosure, reason: nil)
        return succeeded
    }

    static func evaluationSucceeded(_ response: [String: Any]) -> Bool {
        guard response["error"] == nil,
              let result = response["result"] as? [String: Any],
              result["exceptionDetails"] == nil,
              let remote = result["result"] as? [String: Any],
              let value = remote["value"] as? [String: Any] else { return false }
        return value["active"] is Bool
    }

    private func makeDataURL(path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let modified = values.contentModificationDate,
              let size = values.fileSize, size > 0, size <= 25 * 1024 * 1024 else {
            throw BackgroundError.message("背景图片不存在或过大")
        }
        if let cachedImage, cachedImage.path == path, cachedImage.modified == modified {
            return cachedImage.dataURL
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
        let dataURL = "data:\(mime);base64,\(data.base64EncodedString())"
        cachedImage = (path, modified, dataURL)
        return dataURL
    }

    static func injectionScript(settings: BackgroundSettings, imageDataURL: String?) -> String {
        let layout = settings.layout.css
        let payload: [String: Any] = [
            "image": imageDataURL ?? NSNull(),
            "opacity": settings.opacity,
            "railScale": settings.railScale,
            "topScale": settings.topScale,
            "contentScale": settings.contentScale,
            "hideRail": settings.hideRail,
            "hideTopBar": settings.hideTopBar,
            "size": layout.size,
            "repeatMode": layout.repeatMode,
            "position": layout.position
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        let json = String(data: data, encoding: .utf8)!
        return """
        (() => {
          if (!document.head || !document.body || !document.querySelector('[data-app-shell-frame]')) {
            return { ready: false };
          }
          const cfg = \(json);
          let frameStyle = document.getElementById('codex-frame-style');
          if (cfg.railScale === 1 && cfg.topScale === 1 && cfg.contentScale === 1 && !cfg.hideRail && !cfg.hideTopBar) {
            frameStyle?.remove();
            frameStyle = null;
          } else {
            if (!frameStyle) {
              frameStyle = document.createElement('style');
              frameStyle.id = 'codex-frame-style';
              document.head.appendChild(frameStyle);
            }
            frameStyle.textContent = `
              [data-app-shell-frame] {
                --app-shell-navigation-rail-width: ${cfg.hideRail ? 0 : 52 * cfg.railScale}px !important;
                --height-titlebar: ${44 * cfg.topScale}px !important;
                --thread-content-max-width: ${48 * cfg.contentScale}rem !important;
              }
              [data-app-navigation-rail] {
                zoom: ${cfg.railScale};
                width: 52px !important;
              }
              [data-app-shell-titlebar] {
                zoom: ${cfg.topScale};
                height: 44px !important;
              }
              ${cfg.hideRail ? `
                [data-app-shell-frame] [data-app-navigation-rail] { display: none !important; }
              ` : ''}
              ${cfg.hideTopBar ? `
                [data-app-shell-frame], [data-app-shell-frame] :is([class*="_Layout_"], [class^="Layout-"], [class*=" Layout-"]) {
                  --height-titlebar: 0px !important;
                  --app-shell-titlebar-height: 0px !important;
                  --app-shell-titlebar-top-inset: 0px !important;
                  --app-shell-page-header-offset: 0px !important;
                  --app-shell-header-height: 0px !important;
                  --app-shell-application-menu-height: 0px !important;
                }
                [data-app-shell-frame] :is([class*="_MainContentFrame_"], [class^="MainContentFrame-"], [class*=" MainContentFrame-"]) {
                  --app-shell-main-content-frame-top-offset: 0px !important;
                  --app-shell-main-toolbar-height: 0px !important;
                }
                [data-app-shell-frame] :is([data-app-shell-titlebar], [data-app-shell-main-titlebar],
                  [data-app-shell-application-menu-bar], [data-app-shell-tab-row]) { display: none !important; }
              ` : ''}
            `;
          }
          const styleId = 'codex-background-style';
          const layerId = 'codex-background-layer';
          const observerKey = '__codexBackgroundOpaqueObserver';
          window[observerKey]?.disconnect();
          delete window[observerKey];
          if (!cfg.image) {
            document.getElementById(styleId)?.remove();
            document.getElementById(layerId)?.remove();
            document.documentElement.removeAttribute('data-codex-background');
            window.__codexSkinState = { active: false, nodes: [frameStyle].filter(Boolean) };
            return { active: false };
          }
          let style = document.getElementById(styleId);
          if (!style) {
            style = document.createElement('style');
            style.id = styleId;
            document.head.appendChild(style);
          }
          style.textContent = `
            html[data-codex-background="active"],
            html[data-codex-background="active"] body,
            html[data-codex-background="active"] #root { background: transparent !important; }
            html[data-codex-background="active"] body {
              isolation: isolate;
              --color-background-elevated-primary: inherit !important;
            }
            #codex-background-layer {
              position: fixed; inset: 0; z-index: -1; pointer-events: none;
              background-color: var(--main-surface-primary, #111318);
            }
            html[data-codex-background="active"] aside.app-shell-left-panel,
            html[data-codex-background="active"] aside.app-shell-left-panel nav,
            html[data-codex-background="active"] [data-app-shell-frame],
            html[data-codex-background="active"] [data-app-shell-page-surface],
            html[data-codex-background="active"] [data-app-shell-main-surface],
            html[data-codex-background="active"] [data-app-shell-main-titlebar],
            html[data-codex-background="active"] [data-app-shell-page-header],
            html[data-codex-background="active"] [data-app-shell-titlebar],
            html[data-codex-background="active"] .app-shell-left-panel,
            html[data-codex-background="active"] .sidebar-navigation,
            html[data-codex-background="active"] main,
            html[data-codex-background="active"] [role="main"],
            html[data-codex-background="active"] .thread-scroll-container,
            html[data-codex-background="active"] header:is(.app-header-tint, [data-app-shell-header-edge-scroll], [class*="_Header_"], [class^="Header-"], [class*=" Header-"]) { background: transparent !important; }
            html[data-codex-background="active"] .thread-scroll-container
              [class~="bg-gradient-to-t"][class~="from-surface"],
            html[data-codex-background="active"] .thread-scroll-container
              [class*="_background_"][class*="_fade_"][class~="pointer-events-none"][class~="from-surface"],
            html[data-codex-background="active"] .thread-scroll-container
              :is([class^="background-"], [class*=" background-"])[aria-hidden="true"][class~="pointer-events-none"][class~="absolute"]:is([class~="from-surface"], [class~="bg-surface"]),
            html[data-codex-background="active"] .thread-scroll-container [data-thread-scroll-footer],
            html[data-codex-background="active"] .thread-scroll-container [data-thread-scroll-footer]
              > [class~="pointer-events-none"][class~="absolute"][class~="bg-surface"] { background: none !important; }
            html[data-codex-background="active"] [data-app-shell-main-content-top-fade],
            html[data-codex-background="active"] [class*="_MainContentTopFade_"],
            html[data-codex-background="active"] [data-app-shell-frame] :is([class^="MainContentTopFade-"], [class*=" MainContentTopFade-"]) { background: none !important; }
            html[data-codex-background="active"] [data-app-shell-main-surface] :is([class*="_WorkspaceContent_"], [class^="WorkspaceContent-"], [class*=" WorkspaceContent-"])::before,
            html[data-codex-background="active"] [data-app-shell-page-header][data-sticky]::before {
              background: none !important;
            }
            html[data-codex-background="active"] [data-app-shell-header-toolbar] > :first-child,
            html[data-codex-background="active"] [data-app-shell-header-toolbar] > :first-child * { background: transparent !important; }
          `;
          let layer = document.getElementById(layerId);
          if (!layer) {
            layer = document.createElement('div');
            layer.id = layerId;
            document.body.prepend(layer);
          }
          Object.assign(layer.style, {
            backgroundImage: `url("${cfg.image}")`,
            backgroundSize: cfg.size,
            backgroundRepeat: cfg.repeatMode,
            backgroundPosition: cfg.position,
            opacity: String(cfg.opacity)
          });
          document.documentElement.setAttribute('data-codex-background', 'active');
          window.__codexSkinState = { active: true, nodes: [style, layer, frameStyle].filter(Boolean) };
          return { active: true };
        })()
        """
    }
}

enum CodexLauncher {
    static func restartWithDebugPort(applicationURL: URL? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let app = try applicationURL ?? codexApplicationURL()
                guard let bundleID = Bundle(url: app)?.bundleIdentifier else {
                    throw BackgroundError.message("应用包无效")
                }
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                running.forEach { _ = $0.terminate() }
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline && running.contains(where: { !$0.isTerminated }) {
                    Thread.sleep(forTimeInterval: 0.2)
                }
                guard !running.contains(where: { !$0.isTerminated }) else {
                    throw BackgroundError.message("无法自动退出 Codex，请手动退出后重试")
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = [
                    "-na", app.path, "--args",
                    "--remote-debugging-address=127.0.0.1",
                    "--remote-debugging-port=\(debugPort)"
                ]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw BackgroundError.message("Codex 启动失败")
                }
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private static func codexApplicationURL() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: codexBundleIdentifier)
            .compactMap(\.bundleURL) + [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: codexBundleIdentifier),
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            home.appendingPathComponent("Applications/ChatGPT.app")
        ].compactMap { $0 }
        guard let app = candidates.first(where: {
            Bundle(url: $0)?.bundleIdentifier == codexBundleIdentifier
        }) else {
            throw BackgroundError.message("未找到官方 ChatGPT/Codex 应用")
        }
        return app
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let injector = CodexInjector()
    private let menu = NSMenu()
    private var statusItem: NSStatusItem!
    private var connected = false
    private var lastError: String?
    private var restoringSavedBackground = false
    private var recoveryGate = RecoveryGate()
    private var portMissing = false
    private var preferencesWindow: NSWindow?
    private let preferences = SkinPreferencesModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.3.layers.3d", accessibilityDescription: "Codex Skin")
        statusItem.button?.toolTip = "Codex Skin"
        menu.delegate = self
        statusItem.menu = menu
        injector.statusChanged = { [weak self] connected, error, portMissing in
            self?.connected = connected
            self?.lastError = error
            self?.portMissing = portMissing
            self?.statusItem.button?.image = NSImage(
                systemSymbolName: connected ? "square.3.layers.3d" : "exclamationmark.circle",
                accessibilityDescription: connected ? "Codex Skin 已连接" : "Codex Skin 待应用"
            )
            self?.restoreSavedBackground()
            self?.refreshPreferences()
        }
        preferences.onChange = { [weak self] settings in
            settings.save()
            self?.injector.scheduleApply()
        }
        preferences.chooseImage = { [weak self] in self?.chooseBackground() }
        preferences.clearImage = { [weak self] in self?.clearBackground() }
        preferences.apply = { [weak self] in self?.applyToCodex() }
        preferences.restart = { [weak self] in self?.restartAndApply() }
        if CommandLine.arguments.contains("--preview-settings") {
            // Preview the native UI without connecting to or restarting Codex.
            preferences.onChange = nil
            preferences.apply = {}
            preferences.restart = {}
            preferences.chooseImage = {}
            preferences.clearImage = {}
            statusItem.menu = nil
            if CommandLine.arguments.contains("--dark") { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
            showPreferences()
            return
        }
        injector.start()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(codexDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        if BackgroundSettings.load().hasCustomization { applyToCodex() }
        showPreferences()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !CommandLine.arguments.contains("--preview-settings") { restartAndApply() }
        showPreferences()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func codexDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == codexBundleIdentifier else { return }
        injector.applyNow()
    }

    private func restoreSavedBackground() {
        let settings = BackgroundSettings.load()
        guard settings.autoRestart, !restoringSavedBackground else { return }
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: codexBundleIdentifier).first?.processIdentifier
        guard settings.hasCustomization,
              settings.imagePath.map({ FileManager.default.fileExists(atPath: $0) }) ?? true,
              recoveryGate.shouldRecover(process: pid, portMissing: portMissing) else { return }
        restartAndApply()
    }

    @objc private func restartAndApply() {
        guard !restoringSavedBackground else { return }
        if let path = BackgroundSettings.load().imagePath, !FileManager.default.fileExists(atPath: path) {
            showError("保存的背景图片不存在，请重新选择背景图片")
            return
        }
        restoringSavedBackground = true
        lastError = nil
        refreshPreferences()
        if let pid = NSRunningApplication.runningApplications(withBundleIdentifier: codexBundleIdentifier).first?.processIdentifier {
            recoveryGate.attempted.insert(pid)
        }
        CodexLauncher.restartWithDebugPort { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if let pid = NSRunningApplication.runningApplications(withBundleIdentifier: codexBundleIdentifier).first?.processIdentifier {
                    recoveryGate.attempted.insert(pid)
                }
                injector.waitAndApply { [weak self] success in
                    self?.restoringSavedBackground = false
                    if !success { self?.lastError = "等待主窗口超时，将继续重试注入；可从菜单手动应用" }
                    self?.refreshPreferences()
                }
            case let .failure(error):
                restoringSavedBackground = false
                lastError = error.localizedDescription
                refreshPreferences()
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }

    private func refreshPreferences() {
        preferences.settings = BackgroundSettings.load()
        preferences.connected = connected
        preferences.busy = restoringSavedBackground
        preferences.message = lastError
    }

    @objc private func showPreferences() {
        refreshPreferences()
        if preferencesWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 650),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Codex Skin"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SkinPreferencesView(model: preferences))
            window.center()
            preferencesWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let settings = BackgroundSettings.load()
        menu.addItem(item("Codex Skin 设置…", #selector(showPreferences), key: ","))
        menu.addItem(.separator())
        let status = NSMenuItem(title: restoringSavedBackground ? "状态：正在启动并应用…" : connected ? "状态：已连接 Codex" : "状态：待应用", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if !connected, let lastError {
            let detail = NSMenuItem(title: lastError, action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
        }
        menu.addItem(.separator())
        menu.addItem(item("选择背景图片…", #selector(chooseBackground), key: "o"))
        if let path = settings.imagePath {
            let selected = NSMenuItem(title: "当前：\(URL(fileURLWithPath: path).lastPathComponent)", action: nil, keyEquivalent: "")
            selected.isEnabled = false
            menu.addItem(selected)
        }
        for (title, tag, hidden) in [("隐藏最左侧导航栏", 1, settings.hideRail), ("隐藏顶部栏", 2, settings.hideTopBar)] {
            let toggle = item(title, #selector(toggleBar(_:)))
            toggle.tag = tag
            toggle.state = hidden ? .on : .off
            menu.addItem(toggle)
        }
        menu.addItem(item("恢复栏位与默认尺寸", #selector(resetLayout)))
        menu.addItem(.separator())
        menu.addItem(item(connected ? "立即重新应用" : "应用到 Codex…", #selector(applyToCodex), key: "r"))
        let launch = item("启动 / 重启 Codex 并应用皮肤", #selector(restartAndApply))
        launch.isEnabled = !restoringSavedBackground
        menu.addItem(launch)
        menu.addItem(item("恢复 Codex 默认背景", #selector(clearBackground)))
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func chooseBackground() {
        let panel = NSOpenPanel()
        panel.title = "选择 Codex Skin 背景图片"
        panel.allowedContentTypes = [.png, .jpeg, .webP, .gif, .heic]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var settings = BackgroundSettings.load()
            settings.imagePath = try BackgroundStore.importImage(from: url).path
            settings.save()
            refreshPreferences()
            // Imported images reuse the same destination filename.
            preferences.reloadPreview()
            applyToCodex()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func clearBackground() {
        var settings = BackgroundSettings.load()
        settings.imagePath = nil
        settings.save()
        refreshPreferences()
        injector.applyNow()
    }

    @objc private func toggleBar(_ sender: NSMenuItem) {
        var settings = BackgroundSettings.load()
        if sender.tag == 1 { settings.hideRail.toggle() } else { settings.hideTopBar.toggle() }
        settings.save()
        refreshPreferences()
        injector.applyNow()
    }

    @objc private func resetLayout() {
        var settings = BackgroundSettings.load()
        settings.resetLayout()
        settings.save()
        refreshPreferences()
        injector.applyNow()
    }

    @objc private func applyToCodex() {
        guard !restoringSavedBackground else { return }
        injector.applyNow { [weak self] count in
            guard let self, count == 0 else { return }
            if portMissing || NSRunningApplication.runningApplications(withBundleIdentifier: codexBundleIdentifier).isEmpty {
                restartAndApply()
            } else {
                lastError = "主窗口尚未准备好，将继续自动应用；也可选择启动 / 重启"
            }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Codex Skin"
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

#if !LAUNCHER_TEST
@main
struct CodexBackgroundApp {
    static func main() {
        if CommandLine.arguments.contains("--check-connection") {
            let injector = CodexInjector()
            injector.statusChanged = { _, message, _ in if let message { print(message) } }
            let completion: (Int) -> Void = { count in
                print("Applied windows: \(count)")
                exit(count > 0 ? 0 : 1)
            }
            if CommandLine.arguments.contains("--burst") {
                for _ in 0..<50 { injector.scheduleApply(completion: completion) }
            } else {
                injector.applyNow(completion: completion)
            }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--print-probe-script") {
            print(CodexInjector.probeScript)
            return
        }
        if CommandLine.arguments.contains("--print-injection-script") {
            print(CodexInjector.injectionScript(
                settings: BackgroundSettings(imagePath: nil, opacity: 0.42, layout: .fit,
                    railScale: CommandLine.arguments.contains("--compact") ? 0.5 : 1,
                    topScale: CommandLine.arguments.contains("--compact") ? 0.5 : 1,
                    contentScale: CommandLine.arguments.contains("--compact") ? 1.5 : 1,
                    hideRail: CommandLine.arguments.contains("--hide-rail"),
                    hideTopBar: CommandLine.arguments.contains("--hide-top")),
                imageDataURL: CommandLine.arguments.contains("--clear") ? nil : "data:image/png;base64,AA=="
            ))
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            var gate = RecoveryGate()
            precondition(!gate.shouldRecover(process: 1, portMissing: true))
            precondition(!gate.shouldRecover(process: 1, portMissing: true))
            precondition(gate.shouldRecover(process: 1, portMissing: true))
            precondition(!gate.shouldRecover(process: 1, portMissing: true))
            precondition(!gate.shouldRecover(process: 2, portMissing: false))
            precondition(!gate.shouldRecover(process: 2, portMissing: true))
            precondition(!gate.shouldRecover(process: nil, portMissing: true))
            precondition(!gate.shouldRecover(process: 2, portMissing: true))
            precondition(!gate.shouldRecover(process: 2, portMissing: true))
            precondition(gate.shouldRecover(process: 2, portMissing: true))
            let socket = "ws://127.0.0.1:9342/devtools/page/test"
            precondition(CDPTarget(type: "page", url: "app://-/index.html", webSocketDebuggerUrl: socket).isAppWindow)
            precondition(!CDPTarget(type: "page", url: "app://-/index.html?initialRoute=%2Favatar-overlay", webSocketDebuggerUrl: socket).isAppWindow)
            precondition(!CDPTarget(type: "page", url: "https://example.com", webSocketDebuggerUrl: socket).isAppWindow)
            precondition(CodexInjector.evaluationSucceeded(["result": ["result": ["value": ["active": true]]]]))
            precondition(CodexInjector.evaluationSucceeded(["result": ["result": ["value": ["active": false]]]]))
            precondition(!CodexInjector.evaluationSucceeded(["result": ["exceptionDetails": [:], "result": ["value": ["active": true]]]]))
            precondition(!CodexInjector.evaluationSucceeded(["error": ["message": "failed"]]))
            let tile = BackgroundLayout.tile.css
            precondition(tile.size == "auto" && tile.repeatMode == "repeat")
            let settings = BackgroundSettings(imagePath: nil, opacity: 0.42, layout: .fit)
            let script = CodexInjector.injectionScript(settings: settings, imageDataURL: "data:image/png;base64,AA==")
            precondition(script.contains("contain"))
            precondition(script.contains("\"opacity\":"))
            precondition(script.contains("data:image/png;base64,AA=="))
            precondition(!script.contains("76%, transparent"))
            precondition(script.contains("bg-gradient-to-t"))
            precondition(script.contains("data-app-shell-main-content-top-fade"))
            precondition(script.contains("data-app-shell-header-toolbar"))
            precondition(script.contains("--color-background-elevated-primary: inherit !important"))
            precondition(!script.contains("new MutationObserver"))
            precondition(script.contains("?.disconnect()"))
            let suiteName = "com.local.codex-background.self-test"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            precondition(!BackgroundSettings.load(from: defaults).hideRail)
            precondition(!BackgroundSettings.load(from: defaults).hideTopBar)
            let persisted = BackgroundSettings(imagePath: "/tmp/background.png", opacity: 0.42, layout: .tile, railScale: 0.5, topScale: 0.6, contentScale: 1.5)
            persisted.save(to: defaults)
            let restored = BackgroundSettings.load(from: defaults)
            precondition(restored.imagePath == persisted.imagePath)
            precondition(restored.opacity == persisted.opacity)
            precondition(restored.layout == persisted.layout)
            precondition(restored.railScale == 0.5 && restored.topScale == 0.6 && restored.contentScale == 1.5)
            precondition(restored.autoRestart)
            var enabled = restored
            enabled.autoRestart = false
            enabled.save(to: defaults)
            precondition(!BackgroundSettings.load(from: defaults).autoRestart)
            enabled.hideRail = true
            enabled.hideTopBar = true
            enabled.imagePath = nil
            enabled.save(to: defaults)
            var hidden = BackgroundSettings.load(from: defaults)
            precondition(hidden.hideRail && hidden.hideTopBar && hidden.hasCustomization)
            hidden.resetLayout()
            precondition(!hidden.hasCustomization && hidden.opacity == 0.42 && hidden.layout == .tile)
            defaults.removePersistentDomain(forName: suiteName)
            print("self-test passed")
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
#endif
