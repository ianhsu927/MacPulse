# MacPulse

**English** · [简体中文](README.zh-CN.md)

MacPulse is a native Mac app built with SwiftUI and Apple Charts. Its fixed-width menu-bar display shows CPU temperature in °C alongside two lines of network receive (↓) and send (↑) rates. The history window records recent CPU frequency, GPU usage, memory usage, and network traffic. It supports Apple Silicon Macs running macOS 14 or later. The current version is 1.3.0.

The menu-bar readings refresh every second, independently of history recording. They continue while the window is closed or recording is paused. The interface retains concise readings and controls, Chinese/English switching, fixed chart heights, pause gaps, and efficient long-range history queries. Measurement explanations live in these English and Chinese README files.

## Use

Open `MacPulse.app`. CPU temperature and live network rates update every second in the menu bar. History recording samples every 2 seconds by default; choose 1, 2, 5, or 10 seconds in **Recording & Settings**. Available chart ranges are 5 minutes, 15 minutes, 1 hour, 6 hours, 24 hours, and 7 days. History stays on your Mac and retains the most recent 7 days. Export the original records in the selected range to CSV for use in Excel, Numbers, or another analysis tool.

On first launch, the app uses Chinese when the system's preferred language is Chinese and English otherwise. In **Recording & Settings**, use **语言 / Language** to choose **中文** or **English**. App text changes immediately and your choice is remembered across launches. System file dialogs and standard macOS menus may continue to use the system language. Changing the interface language does not change saved samples.

Recording and live readings continue while the window is closed. Click the CPU-temperature/network reading combination in the menu bar and choose **Open Performance History**, or press `⌘1`, to reopen the window. Use **Pause Recording**, **Resume Recording**, or `⌘P` to control history recording; pausing history does not stop the live menu-bar readings. **Export** or `⌘E` exports the selected range. Curves retain a gap when recording resumes after a pause. **Quit MacPulse** or `⌘Q` stops both recording and live monitoring; reopening the app loads saved history. No samples are invented for periods when the Mac is off or asleep, or the app is not running.

For the 24-hour and 7-day ranges, history charts refresh every 10 seconds and immediately when you select another range. Raw sampling still follows your chosen 1-, 2-, 5-, or 10-second interval, and the latest readings update with each sample. CSV exports always read the original records in the selected range.

Before upgrading from 1.0, quit the old app before opening the new version. The upgrade adds GPU and network history fields and preserves existing CPU and memory records. GPU and network readings from before the upgrade remain blank in both charts and CSV. Avoid running two versions that write to the same history database simultaneously.

## Measurements and privacy

CPU temperature is the arithmetic mean of the successfully read, identified CPU thermal-zone sensors obtained through read-only AppleSMC access. It is not a per-core temperature, the maximum sensor temperature, or a guaranteed CPU-package junction reading. Explicit CPU sensor-key mappings are included for M1–M5 generations; only an Apple M4 has been physically tested for this path. That probe read 12 CPU thermal-zone sensors, with subsequent sensor reads taking approximately 2 ms on the tested Mac; this observation is not a timing guarantee for other systems. Unmapped, unreadable, or invalid measurements show `—`. Temperature reads require no `sudo` or privileged helper, and the implementation contains no SMC write command. Temperature is displayed live only and is not stored in history or added to CSV.

Memory readings come from macOS memory statistics. They represent used physical memory, including physical storage occupied by the compressor and excluding reclaimable file caches. Charts use GiB (1 GiB = 1,073,741,824 bytes). This is not the same as memory pressure. CPU frequency comes from IOKit / IOReport channels and is the active-residency-weighted average clock during the sampling interval, rather than an independent instantaneous clock reading for every core.

GPU usage primarily comes from IOReport GPU performance-state residency counters. It measures the percentage of the sampling interval spent in active GPU states; it does not measure GPU memory or occupancy of individual execution units. If this channel is unavailable and macOS exposes exactly one trustworthy GPU driver utilization reading, the app uses IOKit's `Device Utilization %` and shows a short **Fallback** marker. That reading is defined by the driver and is not treated as an IOReport interval average.

Network readings show received and sent bytes per second separately. Rates use differences between 64-bit interface byte counters divided by the actual elapsed interval. The app counts connected physical `enN` Ethernet and Wi-Fi interfaces, including USB adapters exposed in that form when macOS confirms an active link. It excludes disconnected Thunderbolt ports and loopback, VPN, bridge, and AWDL interface names to avoid duplicating traffic across virtual interfaces. The compact menu-bar label uses K/M/G for 1,024-based byte units per second, for example `120K/s` means 120 KiB/s. The open menu and charts use B/s, KiB/s, MiB/s, or GiB/s; CSV stores bytes per second. These are traffic rates, rather than a percentage of link capacity or traffic for individual apps.

Live network monitoring and history recording keep independent counter baselines. Resuming paused history resets the history baseline without interrupting live rates. The first reading, interface-set changes, and counter resets establish new baselines; sleep/wake resets both paths and rediscovers temperature sensors. Missing rates remain unavailable until a valid elapsed interval is available.

IOReport and the AppleSMC sensor protocol are system interfaces without a public stability guarantee. CPU frequency, GPU usage, and temperature availability depend on the hardware, macOS version, and whether access is allowed. Unsupported or unreadable measurements display an explicit missing-data state. The app does not replace them with nominal clocks, fabricated zeroes, or random values. Other available metrics continue recording.

All samples and history stay on the Mac by default. The app requires no account, sends no network requests, uploads no samples, and installs no system background service. Network monitoring reads local counters without initiating a speed test. The database is stored at `~/Library/Application Support/MacPulse/history.sqlite`; CSV is saved to the location you choose.

CSV retains its existing 13 columns, stable English column names, UTC timestamps, and raw numeric units regardless of the interface language. The `frequency_source`, `gpu_source`, and `network_source` fields preserve the original measurement-source and diagnostic text at collection time. Existing records are not translated again, so these fields may contain Chinese. Live CPU temperature is not exported.

CPU sensor-key mappings were checked against the [Stats sensor catalogue](https://github.com/exelban/stats). Its MIT notice is retained in `ThirdPartyNotices.txt` and distributed with both the source and app bundle. MacPulse's read-only transport and temperature decoder are independently implemented.

## Build

Building the app does not require the full Xcode installation. Install Apple's Command Line Tools:

```sh
xcode-select --install
```

Clone the repository and build from its directory:

```sh
git clone https://github.com/ianhsu927/MacPulse.git
cd MacPulse
./build.sh
open outputs/MacPulse.app
```

The default output is `outputs/MacPulse.app` inside the project directory. Choose another destination or a debug build if needed:

```sh
./build.sh --output /path/to/output
./build.sh --debug
```

The build uses Swift 5 language mode and targets `arm64-apple-macosx14.0`. It links the system SwiftUI, Charts, AppKit, IOKit, and SQLite libraries. Module caches and intermediate files are stored in `.build/`. AppKit draws the app icon without external image dependencies. The generated app receives a local ad hoc signature.

## Validate

Run the isolated core validation with Apple's Command Line Tools; full Xcode is not required:

```sh
./verify.sh
```

Validation covers CPU, memory, GPU, and network calculations; SQLite history and legacy schema migration; CSV exports; chart segmentation; temperature decoding and aggregation; compact menu-bar formatting and fixed image dimensions; and the live-sampling lifecycle, including independence from paused history. It uses isolated databases and does not write to your everyday recording history.

With full Xcode installed and its developer tools selected, run the XCTest suite:

```sh
swift test
```

Swift automatically discovers the XCTest suites, including language selection and text coverage in `LocalizationTests`, read-only temperature decoding in `TemperatureTests`, and missing-value formatting, binary-unit boundaries, actual text width, and the fixed template-image size in `MenuBarFormatTests`.

GitHub Actions uses the standard Apple Silicon `macos-15` and `macos-26` runners to execute core validation, XCTest, app builds, and strict signature checks. It also provides app ZIP artifacts. These checks validate builds and isolated logic; virtual runners do not certify real CPU/GPU sensor behavior.

Earlier local checks exercised history sampling, history retrieval, pause/resume, CSV export, and UI interaction on an Apple M4 with 32 GiB of memory running macOS 27.0.1. The 1.3.0 temperature probe separately confirmed 12 readable CPU thermal-zone sensors on that Mac. Every Apple Silicon model and macOS release has not been individually tested on physical hardware; isolated logic tests and a temperature probe do not establish resource-use guarantees or certify every menu-bar interaction.

## Project files

- `Sources/`: SwiftUI interface, sensors, and history storage.
- `README.md`, `README.zh-CN.md`: English and Chinese documentation.
- `ThirdPartyNotices.txt`: Stats sensor-mapping attribution and MIT notice, also included in the app bundle.
- `Info.plist`: app identity and system requirements.
- `Assets/GenerateIcon.swift`: source for regenerating the native icon.
- `Assets/MacPulse.icns`: app icon.
- `build.sh`: build and signing script.
- `verify.sh`, `Validation/`, `Tests/`: isolated validation and XCTest suites.
- `.github/workflows/ci.yml`: macOS build and validation workflow.

The project does not include Apple Developer ID signing or notarization. The generated app is intended for local use and source builds.
