# Codex Skin

原生 macOS 菜单栏皮肤工具，为 Codex 设置背景、透明度、菜单尺寸和对话宽度。非 OpenAI 官方产品。

新版提供独立设置窗口、布局预览和简洁的叠层窗口图标。背景、布局、连接按分区展示，修改自动保存。

## 下载与安装

从 [Releases](https://github.com/ZWLFI/codex-skin/releases/latest) 下载 ZIP，解压后将 `Codex Skin.app` 拖到“应用程序”并打开。

- macOS 13+，Apple Silicon / Intel universal 安装包。
- 需要支持 Chromium 本地调试接口的 Codex 桌面端。开发使用 Bundle ID 为 `com.openai.codex` 的 `ChatGPT.app`，并非所有 ChatGPT 原生客户端都适用。
- 安装包为 ad-hoc 本地签名，**没有 Apple Developer ID 签名或公证**。确认来源后，如系统阻止启动，可通过“系统设置 → 隐私与安全性”允许该应用，或从源码构建；无需关闭系统安全设置。
- 下载 ZIP 及同名 `.sha256` 文件，运行 `shasum -a 256 -c Codex-Skin-1.8.2-universal.zip.sha256` 校验。

## 一键启动与应用

1. 打开 Codex Skin，或从菜单栏叠层图标选择“Codex Skin 设置…”。选择背景图片，图片会复制并保存。
2. 点击“启动 / 重启 Codex 并应用皮肤”：未运行时启动，运行中则请求正常退出后重新启动，并恢复保存的皮肤。
3. 有保存的背景或布局设置时，首次打开 Skin 自动尝试应用；背景接口未开启时启动 / 重启 Codex。再次打开已运行的 Skin 会打开设置窗口，并执行启动 / 重启及应用。
4. “立即重新应用”优先复用当前连接。图片、布局、透明度和尺寸无需重新选择。

**重启会中断 Codex 中正在运行的任务。** 若 Codex 弹出退出确认框，请确认退出后重试。Skin 不强制结束进程；超时会在菜单中显示失败信息。

设置窗口的“自动恢复连接”默认开启：端口连续三次拒绝连接后，为该进程自动恢复一次。关闭后可禁止后台自动重启；明确点击启动 / 重启、打开 Skin 的操作仍会执行。用户主动退出 Codex 后，后台不会反复将它拉起。

## 功能

- 填充、适应、拉伸、平铺、居中五种背景布局。
- 背景不透明度 5%～100%，数值越高图片越实。
- 左侧图标栏宽度、顶部菜单栏高度 50%～100%。
- 最左侧应用导航栏、顶部标题／标签栏可分别隐藏，收回占用的空间；会话列表保留。不改变 macOS 系统菜单栏或系统窗口按钮。
- 标准、紧凑、专注三种布局预设；专注预设隐藏两栏并将对话宽度设为 150%。
- 从设置窗口或系统菜单栏选择“恢复栏位与默认尺寸”，随时找回隐藏的导航，不清除背景与透明度。
- 对话和输入框宽度上限 100%～200%，实际受窗口可用空间限制。
- 滑块请求合并；每 4 秒轻量检查，设置变化或背景层丢失时重新注入。
- 清除多余白色渐变，保留输入框底色；背景层不拦截鼠标操作。

## 构建

需要 Xcode Command Line Tools，运行时无第三方依赖。

```bash
git clone https://github.com/ZWLFI/codex-skin.git
cd codex-skin
./build.sh
open "dist/Codex Skin.app"
```

`./build.sh` 交叉编译两个架构、合并 universal 应用、签名并自测。`./package.sh` 额外生成发布 ZIP 与 SHA-256。

图标由原生矢量绘图生成，运行 `swift generate-icon.swift` 可重建 16～1024 像素图标。运行 `"dist/Codex Skin.app/Contents/MacOS/CodexBackground" --preview-settings` 可预览设置窗口，不保存修改或连接 Codex。

## 验证

```bash
'dist/Codex Skin.app/Contents/MacOS/CodexBackground' --self-test
codesign --verify --deep --strict 'dist/Codex Skin.app'

# 独立测试应用：冷启动、运行中重启、退出后启动，不重启真实 Codex
swiftc -parse-as-library -swift-version 5 -D LAUNCHER_TEST \
  -framework AppKit -framework UniformTypeIdentifiers -framework SwiftUI \
  CodexBackground.swift SkinPreferences.swift test-launcher.swift -o dist/test-launcher
./dist/test-launcher

# 预设与同路径图片预览更新，不写用户设置
swiftc -parse-as-library -swift-version 5 -D LAUNCHER_TEST \
  -framework AppKit -framework UniformTypeIdentifiers -framework SwiftUI \
  CodexBackground.swift SkinPreferences.swift test-preferences.swift -o dist/test-preferences
./dist/test-preferences

# 使用 ChatGPT.app 附带的 Node / Playwright；布局测试还需 Google Chrome
'/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node' test-layout.cjs
# 连接测试要求 9342 端口空闲，先退出 Skin 及占用端口的 Codex
'/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node' test-connection.cjs
```

GitHub Actions 运行 universal 构建、内置自测、预设和预览更新测试。真实应用资源测试和 GUI 启动测试在本地运行。

## 排障与限制

诊断连接：`"/Applications/Codex Skin.app/Contents/MacOS/CodexBackground" --check-connection`，仅应用一次并报告结果，不会重启 Codex。

- 背景接口未开启：点击“启动 / 重启 Codex 并应用皮肤”。
- 等待主窗口：打开 Codex 主窗口。启动等待最多 45 秒，超时后仍会每 4 秒重试注入。
- 无法退出：完成 Codex 自身的退出确认，或手动退出后使用 Skin 启动。
- 样式更新后失效：提交 Codex / Skin 版本及不含个人内容的截图。

工具通过仅监听 `127.0.0.1:9342` 的 DevTools 接口注入 CSS，不修改或重新签名 Codex，不上传图片。该接口可访问应用页面，只应在可信本机使用，勿转发或暴露到网络。

界面样式依赖非官方选择器，Codex 更新可能需要适配。Apple Silicon 已运行验证，Intel 已交叉编译但尚未实机验证。

## 恢复与卸载

选择“恢复 Codex 默认背景”及“恢复栏位与默认尺寸”。退出 Skin 并正常重启 Codex 可清除注入及调试启动参数。移除 `Codex Skin.app` 即可卸载；图片副本在 `~/Library/Application Support/CodexBackground`，设置域为 `com.local.codex-background`。

## License

[MIT](LICENSE)。仓库及安装包不包含用户选择的背景图片、聊天记录和个人配置。
