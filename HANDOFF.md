# MyChat iOS 代码交接文档 (HANDOFF.md)

- **交接目标仓库**：`https://github.com/aa339519589-cpu/mychat-ios.git`
- **主要交接分支**：`codex/cloud-code-native-20261008`
- **PR 关联**：GitHub Pull Request #23
- **交接生成时间**：2026-10-08
- **当前工程版本**：Build 102（Xcode project `CURRENT_PROJECT_VERSION = 102`）

---

## 一、 仓库、分支与代码资产全景

### 1.1 远端与本地分支映射清单

本次交接严格遵守“不删除、不强制重置、不覆盖、不强制推送、不同分支先分别保存交接快照”原则，已将各阶段工作快照完整推送至远端私有仓库：

| 逻辑工作分支 / 阶段 | 本地目录 / 来源 | 远端对应分支 (`origin`) | 提交 SHA | 状态说明 |
| :--- | :--- | :--- | :--- | :--- |
| **主集成分支（推荐继续开发）** | `build102-new-work/work/cloud-code-ios-integrated` | `codex/cloud-code-native-20261008` | *（见最新提交）* | 包含全部原生品质优化、UI 减法、字体防砍头修复、44pt 按钮及 Cloud Code 原生接入代码 |
| **Build 102 原生品质分支** | `build102-new-work/work/engineering/upstream-ios` | `codex/build102-native-quality` | `c90ff47` | 包含自包含 NativeApp 架构、阅读字体合规、手势/滚动跟随与键盘自适应 |
| **Build 102 UI 减法分支** | `build102-new-work/work/engineering/ui-subtraction` | `codex/build102-ui-subtraction` | `0663967` | 包含模型标签修正、标题符号清理 |
| **Build 102 新工作分支** | `Dot-build102-new-work` | `codex/build102-new-work` | `d39bec0` | 本地新工作区基线提交 |
| **Build 100 收尾未提交快照** | `Dot-build100` | `snapshot/build100-finishing` | `8a83db8` | 对话一未提交改动的完整快照，包含抽屉动效与隐私欢迎页调整 |
| **Cloud Code 独立工作区快照** | `build102-new-work/work/cloud-code-ios` | `snapshot/cloud-code-workspace-20261008` | `311a5a1` | 对话三独立探索工作区的快照保存 |

### 1.2 实际代码状态与工程结构

- **主工程入口**：当前最新且通过真机安装的工程位于子目录 `NativeApp/MyChatIOS.xcodeproj`。
- **保留根工程说明**：仓库根目录保留了历史的 `MyChatIOS.xcodeproj`，以保持上游主干兼容性与 Git 历史溯源。dot 接手后进行 iOS 编译、测试与修改时，必须进入 `NativeApp/` 目录下操作。
- **资源与依赖**：
  - 移除了未获授权的 `Resources/ResponseFonts`，合规引入了带有 OFL 许可证的 `Resources/ReadingFonts`（Newsreader 字体族）以及 `InstrumentSans`。
  - 核心资源（AppIcon、BrandMark、DotMotion、ProviderIcons）完整纳入工程。
  - 无依赖 CocoaPods 或 Carthage，采用纯原生 Xcode 模块工程配置。
- **排除内容安全审计**：
  - 已逐项核对提交，无任何 API Key、密码、Token、`.env`、私钥证书（`.p12` / `id_rsa` / `.mobileprovision`）、个人隐私文件或 DerivedData 构建缓存。

---

## 二、 三个 Codex 对话的需求对应关系与累计跟踪

> **核对准则**：后面的要求不能覆盖前面的未完成要求；不把计划当成果；不把估计比例当验收结果。

| 序号 | 需求条目 | 提出对话 | 对应源码位置 | 验证等级 | 真实执行与测试状态 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| 1 | **首字回复速度（最高优先级）** | Build 100 收尾 | 后端受理链路 / 客户端预热 | **未闭环 (源码排查)** | 真机曾记录单次 14.2s 鉴权阻塞，排查出客户端鉴权与后端 prefetch。后端补丁合并后由于 Render drain 部署尚未在真机完成真实网络流式测速闭环。不能宣称已完成。 |
| 2 | **Haiku 5.5 模型卡片呈现** | Build 100 收尾 | `Domain/ModelCatalog.swift`, `Features/MainShellView.swift` | **编译通过 / 模拟器验证** | 原生代码已添加 Haiku 独立卡片与目录映射。但真机 live 列表依赖线上后端部署，端到端展示待线上部署后真机确认。 |
| 3 | **模型显示名连字符改为空格** | Build 100 收尾 | `Domain/ModelCatalog.swift` | **模拟器验证** | 正则规则已处理（如 GLM-5.2 -> GLM 5.2），测试已覆盖。 |
| 4 | **照片选择区与 Models 底框** | Build 100 收尾 | `Features/MainShellView.swift` | **源码完成 / 编译通过** | `RecentPhotoStrip` 调整为全宽负边距，Models 保留 raised 框。需真机视觉体验核对。 |
| 5 | **隐私对话过渡动效与幽灵尺寸** | Build 100 收尾 | `Features/MainShellView.swift`, `WelcomeMotionView.swift` | **源码完成 / 编译通过** | 恢复基线欢迎页过渡与幽灵尺寸 48，右上角隐私按钮按要求不改。 |
| 6 | **侧边栏排版逐帧对齐** | Build 100 收尾 | `DesignSystem/Theme.swift`, `Features/SidebarView.swift` | **部分完成 (数值调整)** | 仅调整了间距数值（20->24/25, 48->50），**未**执行与 Claude 原版截图的逐帧像素级对比，未达终验要求。 |
| 7 | **抽屉弹层手感** | Build 100 收尾 | `Features/MainShellView.swift` | **源码完成 (未经验收)** | 仅改动了 DrawerController 弹簧刚度/阻尼参数，未经真机手感验收。 |
| 8 | **文字渐进浮现（渐显）** | Build 100 收尾 | - | **未开始** | 中英文/Markdown 渐显效果在三个对话中均未开工，明确属于遗留任务。 |
| 9 | **UI 减法原则（第一抉择）** | Build 102 (1) | 全局组件 | **已执行** | 贯彻产品化减法，不添加多余说明书式配置。 |
| 10 | **模型分类修正（默认 vs 附加）** | Build 102 (1) | `Features/MainShellView.swift` | **模拟器验证** | 去除错误的 Anthropic“自定义”标签，规范核心模型展示。 |
| 11 | **顶栏标题符号与哈希清理** | Build 102 (1) | `Features/MainShellView.swift` | **模拟器验证** | 去除对话顶部莫名其妙的会话内部标识符。 |
| 12 | **Code 一级页面减法** | Build 102 (1) | `Features/CodeWorkspaceView.swift` | **模拟器验证** | 移除板块内部大串调试代码，去掉“编程”冗余大字。 |
| 13 | **历史滚动接管（上滑不抢回底部）** | Build 102 (1) | `Features/ChatConversationView.swift` | **模拟器验证** | 拖动时断开自动跟随，点击“回到底部”才恢复，覆盖 UI 回归测试。 |
| 14 | **全局文字砍头（顶部裁切截断）** | Build 102 (2) | `DesignSystem/Theme.swift` (字体工厂) | **真机验证 (Release)** | 根因定位为中文字体 fallback 描述符 17pt 与行盒冲突，已从字体工厂层修复；截帧与大字号测试通过，最新 Release 已装机。 |
| 15 | **Code 输入框/按钮几何对齐与 44pt 触控区** | Build 102 (2) | `Features/CodeWorkspaceView.swift` | **模拟器验证 / 真机验证** | 输入框、+号、发送键垂直居中；发送键与输入框留出间距；可点击区域锁死 44pt（初次 40pt 失败已修复）。 |
| 16 | **Code 页面从左往右滑动返回手势** | Build 102 (2) | `Features/CodeWorkspaceView.swift` | **模拟器验证 / 真机验证** | 全局交互手势对齐，支持边缘右滑退出。 |
| 17 | **删除 Plan / Is Skill / Readonly 假模式** | Build 102 (2) | `Features/CodeWorkspaceView.swift` | **模拟器验证** | 彻底删除本地估算与假模式切换，只保留真实云端执行交互。 |
| 18 | **清理无后端支持的伪 Code 指令** | Build 102 (2) | `Infrastructure/CodeAPIClient.swift` | **源码完成** | 剔除前端空壳指令，对齐真实后端接口。 |
| 19 | **默认配置项对齐** | Build 102 (2) | `App/AppModel.swift` | **模拟器验证** | 默认模型对齐 Haiku 5.5；画图、搜索、记忆等默认开关开启。 |

---

## 三、 验证级别界定与测试报告

每个功能的状态严格依照以下四个级别认定：
1. **源码完成 (Source Done)**：代码已编写，但未执行编译或自动化断言。
2. **编译通过 (Build Passed)**：`xcodebuild` clean build 成功，无编译错误。
3. **模拟器验证 (Simulator Verified)**：在 Xcode 模拟器（iOS 27）上通过自动化单元测试 / UI 测试用例。
4. **真机验证 (Device Verified)**：已通过 `devicectl` 签名安装到物理真机（Device ID: `00008160-000661D23C00000A`），并在真机上启动验证。

### 3.1 已执行的测试及结果
- **运行时单元测试 (`MyChatRuntimeTests`)**：
  - 测试套件包含 88 项测试用例，涵盖 AppModel 状态流转、消息收发解析、字体工厂规格、任务队列状态机等。全部通过（1 项依赖外网 live account 测试按设计跳过）。
- **UI 自动化测试 (`MyChatUITests`)**：
  - 累计通过全部 29 项 UI 交互用例，包括抽屉滑动、横竖屏自适应、输入框键盘避让、Code 发送键 44pt 触控判定、字体砍头截帧无溢出判定。
- **真机编译与安装**：
  - 提交 `b0ed5c0` 已成功完成 Release 配置签名编译，并通过 `devicectl` 安装并启动在 iPhone 真机。

### 3.2 失败记录及处理历史
- **历史失败 1（已修复）**：Code 页面新建发送键可点击区域初测被识别为 40pt（低于 44pt 规范）。修复方案：在 `CodeWorkspaceView.swift` 将 hit test 与 frame 强行约束为 44pt，二次重测通过。
- **历史失败 2（已修复）**：中文字体 fallback 描述符在小字号行盒中固定 17pt，导致多处文字顶部砍头。修复方案：在 `Theme.swift` 统一动态计算行高与 baseline offset，彻底解决。
- **当前受阻项（待云端部署）**：首字速度计时与云端任务 15 分钟离线保持，受制于线上后端服务的部署进度，尚未取得最终真机网络实测数据。

### 3.3 尚待执行的测试
- 物理真机上的实际触觉反馈（Haptic Engine）主观手感测试。
- 弱网与极端网络环境下的长连接断线自动恢复真实验收。
- 真实云端任务离线执行 15 分钟后的状态回调与通知接收。

---

## 四、 编译与运行方法

所有构建指令必须在 `NativeApp` 目录下执行：

### 4.1 模拟器编译与测试
```bash
cd NativeApp

# Debug 模拟器构建
xcodebuild -project MyChatIOS.xcodeproj -scheme MyChatIOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

# 运行自动化测试套件
xcodebuild -project MyChatIOS.xcodeproj -scheme MyChatIOS \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -parallel-testing-enabled NO test
```

### 4.2 真机构建与安装命令（本地开发环境）
```bash
cd NativeApp

# Release 真机编译构建
xcodebuild -project MyChatIOS.xcodeproj -scheme MyChatIOS \
  -configuration Debug \
  -destination 'platform=iOS,id=00008160-000661D23C00000A' \
  -derivedDataPath ./build-output build

# 安装至手机
xcrun devicectl device install app \
  --device 00008160-000661D23C00000A \
  ./build-output/Build/Products/Debug-iphoneos/MyChat.app

# 启动应用
xcrun devicectl device process launch \
  --device 00008160-000661D23C00000A \
  com.mychat.ios
```

---

## 五、 环境变量与配置项清单（不含秘密值）

在云端继续开发或本地对接真实服务时，需要配置以下变量名称（根据环境注入）：

| 变量名称 | 用途说明 | 获取 / 配置方式 |
| :--- | :--- | :--- |
| `MYCHAT_API_BASE_URL` | 后端 API 服务基础 URL（默认指向生产/测试实例） | 配置文件或运行时参数 |
| `MYCHAT_CLOUD_EXEC_ENDPOINT` | 云端 Code 任务独立执行环境接口地址 | 后端 Cloud Worker 分配 |
| `OPENROUTER_API_KEY` | 后端服务调用底层大模型目录（含 Haiku 5.5）秘钥 | 后端服务环境变量（客户端不包含） |
| `SUPABASE_URL` | 用户认证与工作区数据同步服务 URL | App 配置文件（非密钥） |
| `SUPABASE_ANON_KEY` | Supabase 客户端公钥 | 公开客户端 Anon Key |

---

## 六、 待完成任务与 dot 接手下一步

dot 获得仓库授权后在云端继续开发，请按优先级处理以下具体任务：

1. **首字速度真实链路优化（P0）**：
   - 检查并确保后端已部署最新 prefetch 与即时唤醒更新。
   - 对齐客户端鉴权就绪与受理等待流程，确保真机网络下首字回复进入 2 秒以内。
2. **文字逐字渐进浮现（P1）**：
   - 在 `ChatConversationView.swift` 中实现中英文与 Markdown 内容流式到达时的自然淡入渐显动画。
3. **侧边栏逐帧对齐（P1）**：
   - 对照 `/Users/mima1234/Downloads/IMG_0811.PNG` 与 `IMG_0812.PNG`，逐帧调整侧边栏行高、高亮色块、圆角与分组分割线。
4. **云端任务离线执行闭环（P0）**：
   - 联调 `CodeAPIClient.swift` 与后端真实沙箱环境，跑通任务下发、手机退出、云端持续运行并在再次打开时增量同步结果。
