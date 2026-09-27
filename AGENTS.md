# MacTool

macOS 菜单栏常驻的实用工具应用(SwiftUI,最低系统 macOS 15,Apple Silicon)。

## 功能模块

- **菜单栏**: CPU / GPU / 内存 / 网速 / 电量 任意组合,渲染为两行模板图片
- **监控**: CPU(用户/系统、负载、每核、Top5 进程)、GPU、内存(App/联动/压缩/交换、Top5 进程)、磁盘(容量+读写速度)、网络(速率曲线、本机/公网 IP、累计流量)、运行时长;右键进程可结束
- **监控附加**: 网络测速、复制 IP、阈值通知(CPU/内存/磁盘)
- **电池**: 电量、循环次数、健康度、温度/电压/功率,80% 充电提醒、低电量提醒、蓝牙设备电量
- **清理**: 垃圾清理(缓存/日志/DerivedData/npm 等,移入废纸篓)、应用卸载(扫描 ~/Library 残留)、大文件查找
- **工具**: 锁屏、Finder 隐藏文件、隐藏桌面图标、深色模式、推出外置磁盘、重启 Dock/访达、定时防休眠、清空废纸篓、剪贴板历史(文本/文件/图片,搜索置顶,全局快捷键弹窗)

## 构建与验证

```bash
# 编译(Debug,产物在 .derivedData/Build/Products/Debug/MacTool.app)
xcodebuild -project MacTool.xcodeproj -scheme MacTool -configuration Debug -derivedDataPath .derivedData build

# 测试
xcodebuild -project MacTool.xcodeproj -scheme MacTool -configuration Debug -derivedDataPath .derivedData test

# 运行
open .derivedData/Build/Products/Debug/MacTool.app
```

打包分发:

```bash
./scripts/package.sh            # -> build/MacTool-<版本>.dmg(arm64+x86_64 通用,ad-hoc 签名)
swift scripts/make-icon.swift   # 重新生成 AppIcon
```

没有 Developer ID 证书,DMG 未公证:接收者首次打开需在「系统设置 > 隐私与安全性」点「仍要打开」,
或执行 `xattr -dr com.apple.quarantine /Applications/MacTool.app`(DMG 内附安装说明)。
版本号改 project.pbxproj 中的 `MARKETING_VERSION`。

工程使用 Xcode 16+ 同步文件夹(PBXFileSystemSynchronizedRootGroup),新增源码文件无需改 project.pbxproj。

## 约定

- UI 文案用中文;标识符用英文
- 清理操作一律走 `FileManager.trashItem`(移入废纸篓),不可直接 `removeItem`
- 服务层为 `@Observable @MainActor` 类,通过 `.environment(...)` 注入;`AppSettings` 是 `ObservableObject`
- 未启用 App Sandbox(需要访问系统指标与用户库目录);签名为本地运行(ad-hoc)
- 菜单栏 label(`MenuBarExtra` label)只支持单行文本、忽略字体和内嵌图片,自定义排版需用 `ImageRenderer` 渲染成 `isTemplate` 图片(见 `MenuBarMetricsStrip`)
- 面板(MenuBarExtra .window)失去焦点就会收起:**不要用 `confirmationDialog` / `.alert`**,二次确认用内联的 `ConfirmBar`
- `~/.Trash` 受 TCC 保护读不到,清倒废纸篓走访达 AppleScript(需"自动化 > 访达"授权)
- 菜单栏显示项用 `@AppStorage("menuBarShow_*")`;`@EnvironmentObject` 在 label 中不会可靠刷新
- App 启动时会结束同 Bundle ID 的旧实例(单实例),调试时同时 `open` 和 Xcode Run 不会出现两个图标
- 启动的子进程要绑定 App 生命周期(如 `caffeinate -w <pid>`),避免 App 退出后残留
- 捕获子进程输出时先 `readDataToEndOfFile` 再 `waitUntilExit`(输出 >64KB 会死锁)
- 单实例保护在 XCTest 宿主中跳过(`XCTestConfigurationFilePath`),否则并行测试会互相结束
- 电池:新系统 AppleSmartBattery 的容量在 `BatteryData` 子字典,顶层 `MaxCapacity` 是百分比(见 `BatteryMath`);部分机型不提供温度
- 锁屏用 login.framework 的 `SACLockScreenImmediate`(dlsym),旧的 CGSession 工具已被系统移除
- 全局快捷键用 Carbon `RegisterEventHotKey`(`GlobalHotKey`,无需权限);剪贴板弹窗是 `.nonactivatingPanel` 的 `KeyablePanel`,导航键在 `sendEvent` 里拦截;自动粘贴模拟 ⌘V 需辅助功能权限(ad-hoc 签名每次重编译后权限可能失效,需重新勾选)
- 剪贴板忽略 `org.nspasteboard.ConcealedType` 等敏感标记;持久化只存文本/文件(`~/Library/Application Support/MacTool/clipboard.json`,0600)
- 通知统一走 `Notifier.post`;阈值提醒用 `ThresholdTrigger`(持续时长 + 回落重新布防),开关 key 为 `alert_*`;截图/测试实例用 `alertsEnabled: false`
- 测速用 `/usr/bin/networkQuality -c`(吞吐量单位是 bit/s);蓝牙电量解析 `system_profiler SPBluetoothDataType -json`(慢,仅电池页可见时轮询)
- 视觉自查:`ImageRenderer` 画不了 ScrollView/GroupBox,离屏截图用 `NSHostingView` + `cacheDisplay`
