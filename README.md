# MacPulse

**English** · [简体中文](README.zh-CN.md)

MacPulse is a native Mac app built with SwiftUI and Apple Charts. It records recent CPU frequency, GPU usage, memory usage, and network receive/send rates. It supports Apple Silicon Macs running macOS 14 or later. The current version is 1.2.1.

Version 1.2.1 simplifies the interface to readings and controls, removing slogans, subtitles, and explanatory copy. Measurement explanations now live in these English and Chinese README files. Chinese/English switching, fixed chart heights, pause gaps, and efficient long-range history queries remain available.

## Use

Open `MacPulse.app`. The app samples every 2 seconds by default; choose 1, 2, 5, or 10 seconds in **Recording & Settings**. Available chart ranges are 5 minutes, 15 minutes, 1 hour, 6 hours, 24 hours, and 7 days. History stays on your Mac and retains the most recent 7 days. Export the original records in the selected range to CSV for use in Excel, Numbers, or another analysis tool.

On first launch, the app uses Chinese when the system's preferred language is Chinese and English otherwise. In **Recording & Settings**, use **语言 / Language** to choose **中文** or **English**. App text changes immediately and your choice is remembered across launches. System file dialogs and standard macOS menus may continue to use the system language. Changing the interface language does not change saved samples.

Recording continues while the app is running, including when its window is closed. Click the waveform icon in the menu bar and choose **Open Performance History**, or press `⌘1`, to reopen the window. The menu bar also provides pause, resume, and quit controls. Use the window's pause button or `⌘P` to pause or resume, and **Export** or `⌘E` to export the selected range. Curves retain a gap when recording resumes after a pause. **Quit MacPulse** or `⌘Q` stops recording; reopening the app loads the saved history. No samples are invented for periods when the Mac is off or asleep, or the app is not running.

For the 24-hour and 7-day ranges, history charts refresh every 10 seconds and immediately when you select another range. Raw sampling still follows your chosen 1-, 2-, 5-, or 10-second interval, and the latest readings update with each sample. CSV exports always read the original records in the selected range.

Before upgrading from 1.0, quit the old app before opening the new version. The upgrade adds GPU and network history fields and preserves existing CPU and memory records. GPU and network readings from before the upgrade remain blank in both charts and CSV. Avoid running two versions that write to the same history database simultaneously.

## Measurements and privacy

Memory readings come from macOS memory statistics. They represent used physical memory, including physical storage occupied by the compressor and excluding reclaimable file caches. Charts use GiB (1 GiB = 1,073,741,824 bytes). This is not the same as memory pressure. CPU frequency comes from IOKit / IOReport channels and is the active-residency-weighted average clock during the sampling interval, rather than an independent instantaneous clock reading for every core.

GPU usage primarily comes from IOReport GPU performance-state residency counters. It measures the percentage of the sampling interval spent in active GPU states; it does not measure GPU memory or occupancy of individual execution units. If this channel is unavailable and macOS exposes exactly one trustworthy GPU driver utilization reading, the app uses IOKit's `Device Utilization %` and shows a short **Fallback** marker. That reading is defined by the driver and is not treated as an IOReport interval average.

Network charts show received and sent bytes per second separately. Rates use differences between 64-bit interface byte counters divided by the actual elapsed interval. The app counts connected physical `enN` Ethernet and Wi-Fi interfaces, including USB adapters exposed in that form when macOS confirms an active link. It excludes disconnected Thunderbolt ports and loopback, VPN, bridge, and AWDL interface names to avoid duplicating traffic across virtual interfaces. Display units adapt to B/s, KiB/s, MiB/s, or GiB/s in powers of 1,024; CSV stores bytes per second. These are traffic rates, rather than a percentage of link capacity or traffic for individual apps. The first sample, pause/resume, sleep/wake, interface-set changes, and counter resets establish a new baseline; unavailable rates remain blank.

IOReport is a system interface without a public stability guarantee. CPU and GPU availability depends on the hardware, macOS version, and whether access to the counters is allowed. Unsupported or unreadable measurements display an explicit missing-data state. The app does not replace them with nominal clocks, fabricated zeroes, or random values. Other available metrics continue recording.

All samples and history stay on the Mac by default. The app requires no account, sends no network requests, uploads no samples, and installs no system background service. Network monitoring reads local counters without initiating a speed test. The database is stored at `~/Library/Application Support/MacPulse/history.sqlite`; CSV is saved to the location you choose.

CSV uses stable English column names, UTC timestamps, and raw numeric units regardless of the interface language. The `frequency_source`, `gpu_source`, and `network_source` fields preserve the original measurement-source and diagnostic text at collection time. Existing records are not translated again, so these fields may contain Chinese.

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

Validation covers CPU, memory, GPU, and network calculations; SQLite history and legacy schema migration; CSV exports; and chart segmentation. It uses isolated databases and does not write to your everyday recording history.

With full Xcode installed and its developer tools selected, run the XCTest suite:

```sh
swift test
```

Swift automatically discovers and runs `LocalizationTests`, which check language selection, text coverage, and formatting.

GitHub Actions uses the standard Apple Silicon `macos-15` and `macos-26` runners to execute core validation, XCTest, app builds, and strict signature checks. It also provides app ZIP artifacts. These checks validate builds and isolated logic; virtual runners do not certify real CPU/GPU sensor behavior.

Local checks have exercised live sampling, history retrieval, pause/resume, CSV export, and UI interaction on an Apple M4 with 32 GiB of memory running macOS 27.0.1. An isolated sampling probe exercised repeated samples, baseline resets, and repeated creation/destruction of sensors without observing invalid readings or steadily increasing resource use. Every Apple Silicon model and macOS release has not been individually tested on physical hardware.

## Project files

- `Sources/`: SwiftUI interface, sensors, and history storage.
- `README.md`, `README.zh-CN.md`: English and Chinese documentation.
- `Info.plist`: app identity and system requirements.
- `Assets/GenerateIcon.swift`: source for regenerating the native icon.
- `Assets/MacPulse.icns`: app icon.
- `build.sh`: build and signing script.
- `verify.sh`, `Validation/`, `Tests/`: isolated validation and XCTest suites.
- `.github/workflows/ci.yml`: macOS build and validation workflow.

The project does not include Apple Developer ID signing or notarization. The generated app is intended for local use and source builds.
