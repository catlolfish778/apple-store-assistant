#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/Apple Store Assistant Native.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/native
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -O -framework AppKit -framework WebKit native/Domain.swift native/CheckoutProfile.swift native/CheckoutOrderFlow.swift native/BrowserController.swift native/TaskRecording.swift native/ManagedAutomation.swift native/AutomationBrowser.swift native/AutomationDemoBrowser.swift native/App.swift -o build/native/AppleStoreAssistant
cp build/native/AppleStoreAssistant "$APP/Contents/MacOS/AppleStoreAssistant"
cp native/Info.plist "$APP/Contents/Info.plist"
cp native/StoreBridge.js "$APP/Contents/Resources/StoreBridge.js"
cp native/Resources/AppleChinaStoreDirectory.json "$APP/Contents/Resources/AppleChinaStoreDirectory.json"
codesign --force --sign - "$APP"
printf '%s\n' "Built: $APP"
