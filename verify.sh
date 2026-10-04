#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p .build/verification-cache
swiftc -swift-version 5 \
    -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$PWD/.build/verification-cache" \
    Sources/Telemetry.swift Sources/HistoryStore.swift Sources/ChartSeries.swift Sources/Localization.swift Validation/main.swift \
    -framework IOKit -o .build/MacPulseValidation
exec .build/MacPulseValidation
