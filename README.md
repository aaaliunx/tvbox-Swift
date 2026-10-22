# TVBox-Swift

![Platform iOS | macOS](https://img.shields.io/badge/Platform-iOS%20%7C%20macOS-blue.svg)
![Swift Version](https://img.shields.io/badge/Swift-5.9-orange.svg)
![Xcode Version](https://img.shields.io/badge/Xcode-15.0+-blue.svg)
![License](https://img.shields.io/badge/License-MIT-green.svg)

**TVBox-Swift** 是一套基于原生 Swift & SwiftUI 构建的跨平台 TVBox 播放客户端核心工程，同时支持 **iOS 17.0+** 与 **macOS 14.0+**。支持点播/直播双场景，兼容 TVBox 生态数据源（JSON / XML / Remote / Spider），并已对齐安卓版 AVBox 的核心功能链路。

## ✨ 核心特性

- 🎯 **真正的原生跨平台**
  - 基于 SwiftUI + SwiftData，一套代码覆盖 macOS 与 iOS。
  - 针对多端设备交互进行原生级适配与优化。
- 🎨 **现代 UI 视觉**
  - 毛玻璃（Glassmorphism）视觉设计体系。
  - 流畅的重构动画与微交互，原生级暗黑模式支持。
- 🧩 **全方位媒体功能栈**
  - **点播中心（VOD）**：智能资源检索、卡片化视觉呈现、多级详情页、线路/清晰度切换、剧集列表。
  - **直播（Live）**：频道分组、线路切换、EPG 节目单（正在播出/下一节目）、回看入口。
  - **内容枢纽**：全源搜索、历史记录、收藏管理、分类筛选。
- ⚙️ **健壮的业务底层**
  - **持久化**：SwiftData 现代化缓存与本地数据存储。
  - **数据层**：非标准 JSON/XML 接口容错解析、注释清洗、base64 加密配置自动解密、m3u/txt 直播源自动识别、独立直播配置加载。
  - **播放器**：系统 AVPlayer 与 VLCKit 双引擎切换；播放失败自动嗅探/解析换源；字幕轨道切换（macOS）；局域网 HTTP 遥控服务。

## 🔌 数据源支持（对齐安卓版 AVBox）

| 能力 | 状态 |
|---|---|
| 源类型 `type=0/1/4`（XML / JSON / Remote） | ✅ |
| 源类型 `type=3`（Spider / Jar 动态脚本） | ✅ JavaScriptCore 沙箱执行（homeContent / categoryContent / detailContent / searchContent） |
| 加密配置 base64 自动解密 | ✅ |
| m3u / txt 直播源自动识别（无需 JSON 转换） | ✅ |
| 嗅探 / 解析切换（播放失败自动嗅探 m3u8/mp4/iframe） | ✅ |
| 播放器多引擎（系统 AVPlayer + VLCKit，IJK/EXO 为安卓特有） | ✅ |
| 字幕体系（VLC 轨道切换；字幕搜索/本地字幕延后） | ✅ |
| EPG 节目单增强（xmltv 解析 + 频道卡实时显示） | ✅ 回看/时移依赖源协议模板 |
| 分类筛选 + 快速搜索 | ✅ |
| 局域网遥控服务（HTTP 协议，同 Wi-Fi 浏览器遥控播放/暂停/音量） | ✅ |
| 历史条数上限 / M3U8 净化 / 画面缩放 / 备份恢复 | ✅ |
| DoH 自定义 DNS | ⚠️ 受 iOS 系统 DNS 限制 |
| 收藏闭环（详情页收藏入口） | ✅ |

## 🛠 技术栈

- **语言**: Swift 5.9
- **UI 框架**: SwiftUI
- **数据持久化**: SwiftData
- **工程化管理**: XcodeGen (>= 2.35)
- **播放内核**: VLCKitSPM 3.6.0（iOS/macOS）
- **脚本引擎**: JavaScriptCore（Spider 源）

## 📦 无 Mac 环境编译 iOS IPA（GitHub Actions）

本仓库内置 `.github/workflows/build-ipa.yml`，**无需 Mac** 即可通过 GitHub Actions 编译未签名 IPA：

1. 在仓库 **Actions** 页面选择 `Build IPA` 工作流 → **Run workflow**（ref: main）。
2. 工作流自动执行：`xcodegen generate` → `xcodebuild archive`（`CODE_SIGNING_ALLOWED=NO`）→ 组装标准 `Payload/TVBox.app` IPA。
3. 构建完成后在 run 的 **Artifacts** 下载 `tvbox-unsigned-ipa.zip`，解出 `TVBox-unsigned.ipa`。
4. 自签安装：**AltStore / Sideloadly / TrollStore**（或爱思助手等）签名后安装到 iPhone/iPad。

> 若 macOS runner 上 Xcode 版本过旧打不开 xcodegen 生成的新工程格式，工作流会自动 `xcode-select` 切换到已安装的 Xcode 16。

## 🚀 本地快速开始

本项目的主 Xcode 工程文件不直接包含在仓库中，通过 `XcodeGen` 生成：

### 1. 环境准备

* macOS + Xcode 15.0+
* Homebrew

```bash
brew install xcodegen
```

### 2. 生成 Xcode 工程

```bash
xcodegen generate
```

### 3. 构建与运行

打开生成的 `tvbox.xcodeproj`：
- Scheme `tvbox`（iOS）、`tvbox-macOS`（macOS）
- `Command + R` 编译运行。

### iOS 本地打包

```bash
chmod +x package_ios.sh
./package_ios.sh
```

### macOS 独立打包

```bash
chmod +x package_mac.sh
./package_mac.sh
```

> 输出：`TVBox-macOS.dmg`

## 📂 目录结构

```text
├── tvbox
│   ├── Models/         # 数据模型定义
│   ├── ViewModels/     # 业务逻辑与状态管理 (MVVM)
│   ├── Views/          # SwiftUI 原生视图组件
│   ├── Services/       # 网络层、配置解析、Sniff/Spider/EPG/遥控等服务
│   ├── Persistence/    # SwiftData 配置与读写管理
│   ├── Utils/          # 帮助类与扩展函数
│   └── Assets.xcassets # 资源文件集、图标与全局色彩
├── .github/workflows/  # GitHub Actions 无 Mac 编译 IPA 工作流
├── project.yml         # XcodeGen 工程模板
├── package_mac.sh      # macOS DMG 打包脚本
└── package_ios.sh      # iOS 打包脚本
```

## 📜 开源协议

本项目采用 [MIT License](./LICENSE) 开源发布。

## ⚠️ 开源免责声明

**本项目仅供编程技术交流、学习 Swift 与 SwiftUI 原生应用开发原理之目的。**

1. 开发者不对本项目代码产生的任何直接或间接后果负责。
2. 本项目**不提供、不内置、不分发**任何形式的具体影视资源、播放源配置接口（如接口 URL、JSON 规则等）。
3. 使用本项目所导致的所有合法性与知识产权纠纷（包括但不限于使用者自行导入第三方规则/接口而引发的版权问题），由使用者自行承担全部法律责任。
4. 本应用旨在作为一个本地多媒体客户端工具框架进行技术探讨，任何以此框架衍生的商业化产品与违法行为均与原作者无关。如果您下载、安装、编译或使用了本项目，即代表您理解并完全接受本免责声明之所有条款。
