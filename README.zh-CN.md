# MacPulse

[English](README.md) · **简体中文**

MacPulse 是一个使用 SwiftUI 和 Apple Charts 构建的 Mac 原生应用，用于记录并查看最近一段时间内的 CPU 频率、GPU 使用率、内存占用与网络收发速率曲线。支持 Apple Silicon Mac，系统要求为 macOS 14 或更新版本。当前版本为 1.2.1。

1.2.1 精简应用界面，去掉口号、副标题和解释性文字，保留读数与操作控件。指标说明移至中英文 README 用户文档；中英文切换、固定卡片高度、暂停断点和长时间范围查询优化继续保留。

## 使用

双击 `MacPulse.app` 打开应用。应用默认每 2 秒采集一次，可在“记录与设置”中改为 1、2、5 或 10 秒；可查看最近 5 分钟、15 分钟、1 小时、6 小时、24 小时或 7 天的曲线。采样历史保存在本机，并保留最近 7 天的数据。可将当前时间范围内的原始记录导出为 CSV 文件，用 Excel、Numbers 或其他工具进一步分析。

首次启动时，应用按系统首选语言选择界面：中文系统使用中文，其他语言使用英文。在“记录与设置”中的“语言 / Language”选择“中文”或“English”，应用文字立即切换，选择会保留到下次启动。系统文件对话框和 macOS 标准菜单可能继续使用系统语言。切换语言不改变已有采样记录。

应用在运行期间持续记录，关闭窗口后仍可采集；点击菜单栏的波形图标，再选择“打开性能记录”，或按 `⌘1` 重新打开窗口。菜单栏也提供暂停、继续采集与退出操作。窗口中的暂停按钮和 `⌘P` 可暂停或继续；“导出”按钮和 `⌘E` 可导出当前范围记录。暂停恢复后，曲线会保留断点。选择“退出 MacPulse”或按 `⌘Q` 后停止采集，再次打开时会继续读取本地历史。Mac 关机、睡眠和应用退出期间不会补造记录。

选择 24 小时或 7 天范围时，历史图表每 10 秒刷新一次，切换范围时立即刷新。原始数据仍按设置的 1、2、5 或 10 秒采集，顶部最新读数也随采样更新；CSV 导出始终读取该范围内的原始记录。

从 1.0 升级前，请先退出旧版应用，再打开新版。新版自动添加 GPU 和网络历史字段，保留原有 CPU、内存记录；升级前没有采集的 GPU、网络指标显示空白，CSV 中对应字段也为空。请勿同时运行两个版本写入同一个历史数据库。

## 数据与权限

内存数据来自 macOS 的内存统计接口，表示实际已用物理内存，包含压缩器占用，排除可回收的文件缓存；图表使用 GiB（1 GiB = 1,073,741,824 字节），它不等同于内存压力。CPU 频率通过系统 IOKit / IOReport 通道采集，表示采样区间中 CPU 核心活跃时的加权平均频率，不等同于每个时刻、每个核心的独立时钟读数。

GPU 使用率优先由 IOReport 的 GPU 性能状态驻留计数计算，是采样区间内 GPU 活跃状态时间占总状态时间的百分比；它反映 GPU 的活跃程度，不是显存占用，也不表示各 GPU 运算单元的占用率。当该通道不可用、且系统提供唯一可信的 GPU 驱动设备利用率时，使用 IOKit 的 `Device Utilization %` 作为备用值，界面会显示简短的“备用”标记。备用值由驱动定义，不能视作 IOReport 的采样区间平均值。

网络曲线分别显示物理网卡接收和发送的字节速率，用相邻采样的 64 位累计字节差除以实际采样间隔计算。统计系统可确认链路处于活动状态的 `enN` 以太网、Wi-Fi 以及系统暴露为此类接口的 USB 网卡，排除未连接的 Thunderbolt 网口，以及回环、VPN、桥接和 AWDL 等接口名称，避免跨虚拟接口重复计算。显示单位随当前范围内的速率切换为 B/s、KiB/s、MiB/s 或 GiB/s，按 1,024 进位；CSV 始终保存原始字节/秒。该值不是网络带宽利用百分比，也不是每个应用的流量。首次采样、暂停恢复、睡眠唤醒、网卡集合变化或计数器重置后，需建立新的计数基线；没有有效速率时保留空白。

IOReport 属于未公开稳定性承诺的系统接口，CPU 和 GPU 读数取决于当前系统和硬件是否允许读取相应计数器。在不支持的系统或无法读取时，应用明确显示缺失状态，不以标称频率、零值或随机数据替代有效读数。某项指标不可用时，其余可用指标继续采集。

采集和所有历史数据默认只保存在本机；应用不需要账号，不会发送网络请求或上传采样记录，也不创建系统后台服务。网络指标仅读取本机计数器，不发起测速。采样数据位于当前用户的 `~/Library/Application Support/MacPulse/history.sqlite`。CSV 保存到用户选择的位置。

CSV 使用稳定的英文列名、UTC 时间和原始数字单位，不随界面语言切换。`frequency_source`、`gpu_source`、`network_source` 保存采集当时的原始来源与诊断文字，已有记录不会被重新翻译；这些字段可能包含中文。

## 构建

构建应用不需要完整 Xcode。先安装 Apple Command Line Tools：

```sh
xcode-select --install
```

克隆仓库并在项目目录构建：

```sh
git clone https://github.com/ianhsu927/MacPulse.git
cd MacPulse
./build.sh
open outputs/MacPulse.app
```

默认产物为项目目录下的 `outputs/MacPulse.app`。可选择输出目录或调试构建：

```sh
./build.sh --output /path/to/output
./build.sh --debug
```

构建使用 Swift 5 语言模式，目标为 `arm64-apple-macosx14.0`，链接系统提供的 SwiftUI、Charts、AppKit、IOKit 和 SQLite。模块缓存及中间文件放在 `.build/`。应用图标由 AppKit 绘制，没有外部图片依赖；构建产物使用本机临时签名。

## 验证

安装 Apple Command Line Tools 后，可以直接运行核心验证，不需要完整 Xcode：

```sh
./verify.sh
```

验证覆盖 CPU、内存、GPU 与网络采样计算、SQLite 历史存储和旧版字段迁移、CSV 导出及图表分段。验证使用隔离数据库，不写入日常采样历史。

安装完整 Xcode 并选用其开发工具后，也可以运行 `Tests/` 中的 XCTest 测试：

```sh
swift test
```

`swift test` 会自动发现并运行语言选择、文本覆盖及格式化相关的 `LocalizationTests`。

GitHub Actions 在 `macos-15` 与 `macos-26` 的标准 Apple Silicon runner 上执行核心验证、XCTest、应用构建和严格签名检查，并提供应用 ZIP 产物。这些检查验证构建及可隔离测试的逻辑，不代表 runner 虚拟环境验证了真实 CPU/GPU 传感器。

本机已在 Apple M4、32 GiB 内存、macOS 27.0.1 上验证实时采集、历史读取、暂停恢复、CSV 导出及界面交互。隔离采集探针检查了连续采样、基线重置及反复创建与释放传感器；未观察到异常数值或持续资源增长。尚未在所有 Apple Silicon 型号和 macOS 版本上逐一实机测试。

## 项目文件

- `Sources/`：SwiftUI 界面、采样器及历史存储。
- `README.md`、`README.zh-CN.md`：英文、中文项目说明。
- `Info.plist`：应用标识和系统要求。
- `Assets/GenerateIcon.swift`：可重新生成原生图标的源码。
- `Assets/MacPulse.icns`：应用图标。
- `build.sh`：构建和签名脚本。
- `verify.sh`、`Validation/`、`Tests/`：隔离验证与 XCTest 测试。
- `.github/workflows/ci.yml`：macOS 构建和验证。

本项目不包含 Apple Developer ID 签名与公证，适用于本机使用和源码构建。
