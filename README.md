# tianting-ios

天听 iOS 客户端（Swift + SwiftUI，iOS 17+）。**天听**是自研的独立 IM 产品。信息架构见 tianting-server 的 `docs/prd/PRD-ui-v1.0.md`，视觉是天听自有品牌（靛蓝 `#4C5FD5`）。

## 结构

| 目录 | 内容 |
|---|---|
| `App/` | `@main`、App 图标、启动页颜色（Xcode target `Tianting`） |
| `Kit/` | 全部应用代码（Swift Package `TiantingAppKit`，路径依赖 `../../tianting-sdk-swift`）和单元测试 |
| `Kit/Sources/TiantingAppKit/Core/` | 不依赖界面的规则：路由与 deep link、错误文案、时间、拼音分组、会话摘要、群权限、登录、Keychain、`ui.*` 偏好、日志 |
| `Kit/Sources/TiantingAppKit/Model/` | `AppModel`（会话、导航）、`IMStore`（SDK 事件 → 可观察状态）、`NoticeStore`（系统通知）、`UIHub`（轻提示、弹窗） |
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

系统通知（PRD-ui F-UI-44、PRD-live F-PUSH-12）：横幅、`我 → 系统通知`列表、未查看数都在 `Model/NoticeStore.swift` 和 `UI/Pages/NoticePages.swift`。列表只在内存，重启后只有本次打开以来收到的；UserDefaults 只有 `ui.noticeSeen.{userId}` 这一个数字，退出登录时删除，被踢时保留。推送游标由 SDK 放在 Application Support 的独立文件里，不随退出登录删除。`scripts/e2e-server.sh` 用 `IM_PUSH_ENABLED=1` 启动服务端。

账号（PRD-chat C1）：`AppModel` 持有一个 `AccountClient`（进程内一个，"待退出"在它那里），每次登录一个 `IMClient`。登录页由 `GET /v1/config` 决定入口，失败不猜测模式；保存恢复码页在根视图替换全部内容，下面没有页面，返回手势没有去处。`UITests/AccountFakeServerTests.swift` 用测试进程里的假服务端（`UITests/AccountSupport.swift`，HTTP + WebSocket）覆盖真实服务端不能按需产生的状态，`UITests/AccountE2ETests.swift` 连真实 im-server。

图片和文件（PRD-chat C2，FE-637、FE-638）：聊天页"+"（`GET /v1/config` 的 `features.files` 关时没有）用 PHPicker（不要相册完整权限，一次最多 9 张）和 `UIDocumentPicker`；选中的先复制到临时目录，图片轮到它时用 ImageIO 处理（`Core/ImageProcessing.swift`：先看头部像素上限，按 EXIF 方向转正后只写像素，去掉 ImageIO 自己加的 Exif 段，长边 4096，缩略图 480 ≤ 512 KiB，透明的 png，GIF 原样，HEIC 转 jpeg），再交给 SDK 复制进沙盒。气泡按宽高占位，缩略图只在行建出来时取，解码前查像素上限，缓存键 `fileId:variant`；全屏看原图、存相册（`NSPhotoLibraryAddUsageDescription`，被拒提示"没有相册权限"和前往设置）；文件用 SDK 的 URLSession 下载到私有缓存，pdf、txt、图片可以"打开"（Quick Look），都可以"保存"（分享面板）。"我"页头像：裁剪 → 512×512 jpeg → `kind=avatar` → `PATCH profile`。`scripts/e2e-server.sh` 同时启动 `scripts/fake_s3.py`（127.0.0.1:18183）并打开 `IM_FILES_ENABLED`；`UITests/FilesE2ETests.swift`、`ZzFilesClockE2ETests.swift`（调服务端时钟，名字排在最后）。系统选择器测试点不了：调试构建里 `TT_TEST_PICK_DIR` 让"图片""文件"直接取这个目录里的文件。

撤回、引用、@（PRD-chat C4，FE-669、FE-670）：只在 `GET /v1/config` 的 `features.msgActions=true` 时有（没有这个字段按关）。消息菜单是系统长按菜单，菜单项在打开时按 SDK `messageActions` 现算（撤回按 `ts` 和校正后的服务端时间；菜单开着过了时限点"撤回"按服务端 4097 提示），同样的项也是 VoiceOver 的"操作"；撤回、删除的提示行没有菜单。撤回文案用 SDK `recallNotice` + `recallText`（聊天页和列表摘要同一张表，显示名备注优先）；全屏看的图片被撤回时关闭并提示"该消息已被撤回"；下载中被撤回由 SDK 中止（`.downloadAborted`），提示"该消息已被撤回"、不留部分文件。引用条在输入框上方（可取消，只记 msgId），气泡顶部的引用按纯文本显示，点了跳转：200 条以内翻页后滚动并高亮 2 秒，更远"消息太早，请翻页查看"。@ 的输入模型在 `Core/Mentions.swift`（文本 + UTF-16 区间，和 H5、Android 同语义）：`markedTextRange` 不为空（组字中）时不改模型、不打开选择；成员选择是底部面板（`searchGroupMembers`），插入公开昵称、列表显示备注和 userId。草稿结构化（文字、@ 区间、引用，只在内存）。列表前缀"[有人@我]"优先于"[草稿]"，聊天页"有人@我"按钮。`scripts/e2e-server.sh` 默认 `IM_MSG_ACTIONS_ENABLED=1`；用例在 `UITests/C4E2ETests.swift`、`C4FilesE2ETests.swift`（断网用 `TCPProxy`），调试构建的 `TT_TEST_SCAN` 让探针报告数据目录里含某串字节的文件数（只有数量）。

端到端用例的"另一个账号"是测试进程里的真实 `IMClient`：一台模拟器不能同时跑两份同一个 App。测试调用的服务端密钥由 `scripts/e2e-server.sh` 每次随机生成，只在本机临时目录。

真机运行要在 Xcode 里给 target 选签名团队（工程里没写）。服务器地址：Debug 默认 `http://localhost:8080`，可以用启动环境变量 `TIANTING_SERVER` 改；Release 的 `TTServerURL` 留空，等正式接入方式定了再填（PRD-ui F-UI-03）。

## 约定

- **颜色**只在生成的 `Tokens.swift` 里；页面用 `TC.*`（`check_sources.py` 检查）。
- **图标**来自 Lucide（ISC，`LICENSES/lucide.txt`），模板渲染，跟随前景色。
- **`accessibilityIdentifier`** 和 Web 的 `data-testid` 同名。消息元素的状态放在 `accessibilityValue`（`排队中`、`发送中`、`已发送`、`发送失败`）。
- **日志**只有 `TTLog`：入参是字面量和错误码，传不进消息、token、备注；SDK 用 `SilentLogger`。
- **token** 只在 Keychain，不进 UserDefaults、URL、日志。UserDefaults 只有 `ui.` 前缀的键。Session 和"待退出"是 Keychain 里两条分开的记录（`Core/SessionStore.swift`），`clear()` 只删前者；恢复码确认前 token 不写 Keychain。
- **测试钩子**只在 Debug 构建（`Core/TestHooks.swift`），靠启动环境变量打开，只暴露是否有值和数量，不暴露值。
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
