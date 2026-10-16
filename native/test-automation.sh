#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/native
xcrun swiftc -swift-version 5 -framework Security native/Domain.swift native/CheckoutProfile.swift native/CheckoutProfileTests.swift -o build/native/checkout-profile-tests
build/native/checkout-profile-tests
xcrun swiftc -swift-version 5 native/Domain.swift native/ManagedAutomation.swift native/ManagedAutomationTests.swift -o build/native/automation-tests
build/native/automation-tests
xcrun swiftc -swift-version 5 native/Domain.swift native/DomainTests.swift -o build/native/domain-tests
build/native/domain-tests
xcrun swiftc -swift-version 5 -framework JavaScriptCore native/Domain.swift native/BrowserController.swift native/BrowserControllerTests.swift -o build/native/browser-controller-tests
build/native/browser-controller-tests
xcrun swiftc -swift-version 5 native/Domain.swift native/TaskRecording.swift native/TaskRecordingTests.swift -o build/native/task-recording-tests
build/native/task-recording-tests
xcrun swiftc -swift-version 5 native/Domain.swift native/BrowserController.swift native/ManagedAutomation.swift native/AutomationBrowser.swift native/AutomationBrowserIntegrationTests.swift -o build/native/automation-browser-tests
build/native/automation-browser-tests
bash native/build.sh
test_data_dir=$(mktemp -d /tmp/asa-app-self-test.XXXXXX)
ASA_TEST_DATA_DIR="$test_data_dir" 'dist/Apple Store Assistant Native.app/Contents/MacOS/AppleStoreAssistant' --self-test
plutil -extract passed raw -o - "$test_data_dir/demo-result.json" | grep -qx true
printf 'App self-test passed. Isolated evidence: %s\n' "$test_data_dir"
