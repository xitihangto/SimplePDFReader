<p align="center">
  <img src="./AppIcon.png" width="128" height="128" alt="SimplePDFReader Icon" />
</p>

<h1 align="center">SimplePDFReader — macOS 原生极简 PDF 阅读器</h1>

<p align="center">
  基于 <b>Swift + SwiftUI + 原生 PDFKit</b> 开发的轻量级 macOS PDF 阅读器。<br/>
  专注纯粹阅读体验，仅保留放大缩小、多屏/自适应分屏、目录大纲、随输随搜与页码跳转等核心高频功能。
</p>

## 核心特性

- **纯净无打扰默认界面**：启动与打开 PDF 默认进入**单屏无侧边栏**模式，将 100% 窗口面积留给文档正文；侧边栏仅在点击左上角「侧栏」按钮时按需展开。
- **精准缩放与实时百分比**：支持工具栏放大/缩小按钮（按 `15%` 步进）与触控板双指捏合缩放，实时同步当前缩放比例（如 `100% → 115% → 130%`），点击百分比数字即可一键恢复 `100%` 原始比例。
- **弹出式多屏与智能自适应菜单**：
  - **单屏 / 双屏 / 三屏 / 四屏（2×2 网格）**：支持同一个 PDF 的多屏跨页对照阅读（如左屏看正文、右屏看图表或参考文献），也支持在副屏点击「换文件」独立打开另一份对比 PDF，或开启「多屏联动顺延翻页」。
  - **自适应分屏（按缩放等级智能判断）**：开启后可根据当前缩放比例自动切换布局——放大（`≥ 115%`）自动切为单屏单页精读、中等缩放（`72% ~ 114%`）自动切为双屏对照、缩小（`< 72%`）自动切为三屏双页概览，并提供 3 种细分策略可选。
- **目录大纲与快速页码导航**：自动递归解析 PDF 内置多级 `PDFOutline` 树并展示对应页码，点击即跳；若 PDF 未包含内置目录大纲，自动降级生成全文档快速页码列表。
- **随输随搜（实时全文检索）**：在搜索框输入字符时自动触发 `80ms` 轻量防抖实时检索，即时高亮全文档匹配项并定位至首处匹配；在搜索框内按回车键（`Return`）直接循环跳转下一处匹配；当输入变为 `0` 匹配时自动彻底清除页面高亮图层。
- **三档响应式自适应工具栏**：窗口最小宽度低至 `400pt`，工具栏根据当前窗口宽度自动在「宽屏完整模式」「中屏紧凑图标模式」与「窄窗双行抽屉搜索模式」之间平滑切换，把窗口缩窄贴在屏幕一侧伴读时也不会出现按钮溢出或裁切。
- **一键设为系统默认阅读器**：在系统顶部菜单栏「SimplePDFReader → 设为默认 PDF 阅读器…」或「文件 → 设为默认 PDF 阅读器…」中即可一键绑定为系统默认 `.pdf` 打开应用。

## 快捷键一览

| 功能分类 | 操作说明 | 快捷键 |
| :--- | :--- | :--- |
| **文件操作** | 打开 PDF 文件（也支持直接拖拽 `.pdf` 至窗口） | `⌘ + O` |
| **视图缩放** | 放大 `15%` / 缩小 `15%` | `⌘ + =` / `⌘ + -` |
| **比例重置** | 恢复 `100%` 原始大小 / 自适应当前窗口宽度 | `⌘ + 0` / `⌘ + 9` |
| **侧边栏开关** | 按需显示或隐藏左侧「大纲 / 搜索」侧边栏 | `⌘ + ⇧ + S` |
| **分屏模式切换** | 切换 单屏 / 双屏 / 三屏 / 四屏 / 自适应分屏 | `⌘ + 1` ~ `⌘ + 5` |
| **全文实时搜索** | 聚焦右上角搜索框（输入即实时搜索，回车跳下一项） | `⌘ + F` |
| **搜索结果导航** | 查找下一个匹配项 / 查找上一个匹配项 | `⌘ + G` / `⌘ + ⇧ + G` |
| **页面跳转** | 聚焦页码输入框（输入页码回车跳转） | `⌘ + J` |
| **快速翻页** | 上一页 / 下一页 | `⌘ + ↑` / `⌘ + ↓` |

## 安装与运行指南

### 方式一：直接下载 Release 应用包

1. 前往仓库右侧 **Releases** 页面下载最新的 `SimplePDFReader-macOS-arm64.zip` 并解压。
   > **架构说明**：该产物由 GitHub Actions 在 `macos-14`（Apple Silicon）运行器上构建，**仅支持 Apple Silicon（arm64）机型**。Intel Mac 请改用下方的「方式二」从源码编译。
2. 将解压出的 `SimplePDFReader.app` 拖入 `/Applications`（应用程序）目录或任意位置双击运行。
3. **首次打开安全提示说明**：由于应用采用开源本地签名，从网络下载后若遇到 macOS 提示“无法验证开发者”，可通过以下任一方式放行：
   - **系统设置放行**：打开「系统设置 → 隐私与安全性」，滑至底部点击 **「仍要打开」**。
   - **终端一键解除隔离**：在终端执行以下命令清除下载隔离属性后即可直接双击打开：
     ```bash
     xattr -cr /Applications/SimplePDFReader.app
     ```

### 方式二：从源码一键编译（本机编译零安全弹窗）

- **环境要求**：macOS 13.0+，已安装 Xcode 或 Xcode Command Line Tools（`xcode-select --install`）。
- **一键生成图标并打包 `.app`**：
  ```bash
  git clone <仓库地址>
  cd SimplePDFReader
  chmod +x build_app.sh
  ./build_app.sh
  ```
  脚本会自动使用 CoreGraphics 渲染 `1024×1024` 红色系高清图标、封装多分辨率 `AppIcon.icns`，并在上级目录生成可直接双击运行的 `SimplePDFReader.app`。

## 发版流程（维护者）

本项目对外发布的 Release 产物**只允许由 GitHub Actions 构建产生**，以保证任何一个下载到的 `.app` 都能溯源到具体的源码提交，杜绝「来源不明的二进制包」。

### 标准发版步骤

```bash
# 1. 先在 CHANGELOG.md 中新增对应版本的更新段落
# 2. 打 tag 并推送（tag 必须匹配 v* 格式）
git tag v1.0.1
git push --tags
```

推送 tag 后，[`.github/workflows/release.yml`](.github/workflows/release.yml) 会自动：

1. 在 `macos-14` 运行器上执行 `./build_app.sh`，**从源码**编译出 `SimplePDFReader.app`；
2. 打包为 `SimplePDFReader-macOS-arm64.zip`；
3. 以 `CHANGELOG.md` 作为正文创建同名 Release，并附上该产物。

### 手动重跑

进入 **Actions → Build and Release macOS App → Run workflow**，填入要发布的版本号（例如 `v1.0.1`）即可手动触发一次构建发布。

### 约定

- **禁止**手工上传本地打包的 zip 作为 Release 附件。本地产物无法自证由仓库源码构建，会破坏产物的可溯源性。
- Release 附件的上传者（uploader）应始终为 `github-actions[bot]`，可据此校验产物真伪。
- 发版前请确认 CI 构建通过；构建失败时不要手工补传产物，应先修复源码或工作流。

## 项目结构

```text
SimplePDFReader/
├── Package.swift                               # Swift Package Manager 配置文件
├── README.md                                   # 项目中文说明文档
├── CHANGELOG.md                                # 版本更新日志
├── AppIcon.png                                 # 1024×1024 高清应用图标预览
├── AppIcon.icns                                # macOS 多分辨率原生图标包
├── generate_icon.swift                         # CoreGraphics 原生矢量图标生成脚本
├── build_app.sh                                # 一键编译与打包 .app 脚本
├── .github/workflows/release.yml               # GitHub Actions 自动构建与发布 Release 工作流
└── Sources/
    └── SimplePDFReader/
        ├── ModelsAndViewModel.swift            # 大纲解析、分屏状态、智能缩放策略与实时搜索核心逻辑
        └── AppAndViews.swift                   # PDFKit 视图桥接、响应式工具栏、多屏容器与菜单命令
```
