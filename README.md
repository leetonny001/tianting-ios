# tianting-ios

天听 iOS 客户端（Swift + SwiftUI，iOS 17+）。**天听**是自研 IM 平台，替换腾讯 IM（聊天、群聊、聊天室、站内推送）。信息架构见 tianting-server 的 `docs/prd/PRD-ui-v1.0.md`，视觉是天听自有品牌（靛蓝 `#4C5FD5`）。

## 结构

| 目录 | 内容 |
|---|---|
| `App/` | `@main`、App 图标、启动页颜色（Xcode target `Tianting`） |
| `Kit/` | 全部应用代码（Swift Package `TiantingAppKit`，路径依赖 `../../tianting-sdk-swift`）和单元测试 |
| `Kit/Sources/TiantingAppKit/Core/` | 不依赖界面的规则：路由与 deep link、错误文案、时间、拼音分组、会话摘要、群权限、登录、Keychain、`ui.*` 偏好、日志 |
| `Kit/Sources/TiantingAppKit/Model/` | `AppModel`（会话、导航）、`IMStore`（SDK 事件 → 可观察状态）、`UIHub`（轻提示、弹窗） |
| `Kit/Sources/TiantingAppKit/UI/` | 页面和组件 |
| `Kit/Sources/TiantingAppKit/Theme/` | `Tokens.swift`（生成）、字体、外观 |
| `UITests/` | XCUITest：连真实 im-server 的端到端用例 |
| `Config/` | `Info-Debug.plist`（`http://localhost:8080`、演示登录、只放开本机明文）、`Info-Release.plist`（无服务器地址、无演示登录、无 ATS 例外） |
| `design/tokens.json` | tianting-web `src/theme/tokens.json` 的副本 |
| `scripts/` | 端到端脚本、生成和检查脚本（`scripts/py/` 里的 Python 都用 `python3 -I` 运行） |

工程文件 `Tianting.xcodeproj` 是手写的，用文件夹同步组（objectVersion 77）：`App/`、`UITests/` 下加文件不用改工程文件。

## 开发

需要 Xcode 26 或更新版本；`tianting-sdk-swift` 放在同级目录。

```bash
# 单元测试（模拟器）
cd Kit && xcodebuild test -scheme TiantingAppKit -destination 'platform=iOS Simulator,name=iPhone 15'

# 端到端测试：go build 并启动测试模式的 im-server（源码在 TIANTING_SERVER_DIR、../tianting-server/server 或 ../im-mvp/server），
# 跑 XCUITest，再检查 os_log、UserDefaults、本地文件。需要 Go 和一台模拟器。
xcrun simctl create "TT iPhone 18 Pro" "iPhone 18 Pro"
scripts/run-e2e.sh [--device "名字"] [--only ChatE2ETests/testGroupChat] [--screenshots 目录]

# 生成 / 检查
python3 -I scripts/py/gen_tokens.py [--check]   # design/tokens.json → Tokens.swift
python3 -I scripts/py/check_tokens.py           # 6.2 节对比度清单、色相规则
python3 -I scripts/py/check_sources.py          # 主题文件外无颜色字面量、UserDefaults 只在 UIPrefs、无散落日志、无 http、品牌词
python3 -I scripts/py/gen_icons.py              # 从 tianting-web 的 Lucide 生成图标（清单变化时才用）
swift scripts/gen-app-icon.swift App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

端到端用例的"另一个账号"是测试进程里的真实 `IMClient`：一台模拟器不能同时跑两份同一个 App。测试调用的服务端密钥由 `scripts/e2e-server.sh` 每次随机生成，只在本机临时目录。

真机运行要在 Xcode 里给 target 选签名团队（工程里没写）。服务器地址：Debug 默认 `http://localhost:8080`，可以用启动环境变量 `TIANTING_SERVER` 改；Release 的 `TTServerURL` 留空，等正式接入方式定了再填（PRD-ui F-UI-03）。

## 约定

- **颜色**只在生成的 `Tokens.swift` 里；页面用 `TC.*`（`check_sources.py` 检查）。
- **图标**来自 Lucide（ISC，`LICENSES/lucide.txt`），模板渲染，跟随前景色。
- **`accessibilityIdentifier`** 和 Web 的 `data-testid` 同名。消息元素的状态放在 `accessibilityValue`（`排队中`、`发送中`、`已发送`、`发送失败`）。
- **日志**只有 `TTLog`：入参是字面量和错误码，传不进消息、token、备注；SDK 用 `SilentLogger`。
- **token** 只在 Keychain，不进 UserDefaults、URL、日志。UserDefaults 只有 `ui.` 前缀的键。
- **消息只按纯文本渲染**，头像只加载 https。
- `Kit` 的类逐个写 `@MainActor`，不用 `.defaultIsolation(MainActor.self)`：它让类带上隔离的 deinit，在 iOS 18.5 上释放时崩溃。

## CI

- `checks`：token、对比度、源码规则，不依赖私有仓库。
- `build-and-test`：构建 + 模拟器单元测试，要检出私有 SDK。仓库所有者运行一次 `scripts/setup-ci-deploy-key.sh` 配置只读部署密钥；没配置时跳过。
- 端到端用例不在 CI 跑：需要私有的 tianting-server 检出和模拟器，整套耗时也长；发版前在本机跑 `scripts/run-e2e.sh`。

## 天听的项目

| 仓库 | 内容 |
|---|---|
| [tianting-server](https://github.com/leetonny001/tianting-server) | Go 服务端、协议、需求 / 架构 / 测试文档 |
| [tianting-sdk-ts](https://github.com/leetonny001/tianting-sdk-ts) | SDK（TypeScript）：H5、PC |
| [tianting-sdk-kotlin](https://github.com/leetonny001/tianting-sdk-kotlin) | SDK（Kotlin）：Android |
| [tianting-sdk-swift](https://github.com/leetonny001/tianting-sdk-swift) | SDK（Swift）：iOS |
| [tianting-web](https://github.com/leetonny001/tianting-web) | H5 客户端 |
| [tianting-desktop](https://github.com/leetonny001/tianting-desktop) | PC 客户端 |
| [tianting-android](https://github.com/leetonny001/tianting-android) | Android 客户端 |
| [tianting-ios](https://github.com/leetonny001/tianting-ios) | iOS 客户端 |
| [tianting-admin](https://github.com/leetonny001/tianting-admin) | 管理后台 H5 |
| [tianting-ops](https://github.com/leetonny001/tianting-ops) | 运维后台 H5 |
