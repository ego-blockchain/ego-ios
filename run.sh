#!/bin/sh
# Build Ego Wallet and run it in the iOS Simulator.
# Usage: ./run.sh ["iPhone 16 Pro"]
set -e
cd "$(dirname "$0")"

DEVICE="${1:-iPhone 16 Pro}"
APP=build/Build/Products/Debug-iphonesimulator/EgoWallet.app

[ -d EgoWallet.xcodeproj ] || xcodegen generate

xcodebuild -project EgoWallet.xcodeproj -scheme EgoWallet \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath build CODE_SIGN_IDENTITY=- -quiet build

xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator
xcrun simctl terminate "$DEVICE" com.egoblockchain.wallet 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" com.egoblockchain.wallet
