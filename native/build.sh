#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APPS=("Apple Store Assistant.app" "dist/Apple Store Assistant Native.app")
mkdir -p build/native
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -O -framework AppKit -framework WebKit native/Domain.swift native/CheckoutProfile.swift native/CheckoutOrderFlow.swift native/BrowserController.swift native/TaskRecording.swift native/ManagedAutomation.swift native/AutomationBrowser.swift native/AutomationDemoBrowser.swift native/App.swift -o build/native/AppleStoreAssistant

sync_file() {
  local source="$1" destination="$2"
  if ! cmp -s "$source" "$destination"; then
    cp "$source" "$destination"
  fi
}

publish_app() {
  local app="$1"
  local executable="$app/Contents/MacOS/AppleStoreAssistant"
  local staged_executable="$executable.new.$$"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

  # Replace the executable atomically so an already-running copy can finish
  # on its existing image while the next launch gets this build.
  cp build/native/AppleStoreAssistant "$staged_executable"
  chmod 755 "$staged_executable"
  mv -f "$staged_executable" "$executable"

  sync_file native/Info.plist "$app/Contents/Info.plist"
  sync_file native/StoreBridge.js "$app/Contents/Resources/StoreBridge.js"
  sync_file native/Resources/AppleChinaStoreDirectory.json "$app/Contents/Resources/AppleChinaStoreDirectory.json"
  codesign --force --sign - "$app"
  printf '%s\n' "Built: $app"
}

for app in "${APPS[@]}"; do
  publish_app "$app"
done
