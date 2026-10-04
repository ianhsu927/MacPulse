#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p .build/verification-cache
swiftc -swift-version 5 \
    -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$PWD/.build/verification-cache" \
    Sources/Telemetry.swift Sources/HistoryStore.swift Sources/ChartSeries.swift Sources/Localization.swift Validation/main.swift \
    -framework IOKit -o .build/MacPulseValidation
.build/MacPulseValidation
swiftc -swift-version 5 -parse-as-library \
    -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$PWD/.build/verification-cache" -D TEMPERATURE_SELFTEST \
    Sources/TemperatureSensor.swift Tests/TemperatureTests.swift \
    -framework IOKit -o .build/MacPulseTemperatureValidation
.build/MacPulseTemperatureValidation
swiftc -swift-version 5 -parse-as-library \
    -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$PWD/.build/verification-cache" -D MENUBAR_SELFTEST \
    Sources/MenuBarLabel.swift Tests/MenuBarFormatTests.swift \
    -framework AppKit -framework SwiftUI -o .build/MacPulseMenuBarValidation
.build/MacPulseMenuBarValidation
swiftc -swift-version 5 -parse-as-library \
    -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$PWD/.build/verification-cache" \
    Sources/Telemetry.swift Sources/HistoryStore.swift Sources/Localization.swift \
    Sources/TemperatureSensor.swift Sources/LiveMetrics.swift Sources/MonitorModel.swift Validation/LiveStatus.swift \
    -framework IOKit -framework AppKit -lsqlite3 -o .build/MacPulseLiveValidation
exec .build/MacPulseLiveValidation
