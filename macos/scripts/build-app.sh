#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${MACOS_DIR}/.." && pwd)"

SHARED_JS_DIR="${REPO_ROOT}/shared/js"
RESOURCES_JS_DIR="${MACOS_DIR}/Sources/CampusEntryCore/Resources/js"

DIST_DIR="${MACOS_DIR}/dist"
APP_NAME="CampusEntry"
VERSION="1.0.0"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_BIN_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
DMG_STAGING_DIR="${DIST_DIR}/dmg-staging"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}-macOS.dmg"
ICNS_PATH="${RESOURCES_DIR}/${APP_NAME}.icns"

echo "==> [1/6] Syncing shared JS scripts..."
if [ -d "${SHARED_JS_DIR}" ]; then
    mkdir -p "${RESOURCES_JS_DIR}"
    shopt -s nullglob
    js_files=("${SHARED_JS_DIR}"/*.js)
    shopt -u nullglob
    if [ ${#js_files[@]} -gt 0 ]; then
        cp -f "${js_files[@]}" "${RESOURCES_JS_DIR}/"
        echo "Synced ${#js_files[@]} JS files from shared/js into Resources/js."
    else
        echo "No .js files found in ${SHARED_JS_DIR}; keeping existing Resources/js."
    fi
else
    echo "Shared JS directory not found at ${SHARED_JS_DIR}; keeping existing Resources/js."
fi

echo "==> [2/6] Building release binary..."
swift build -c release --package-path "${MACOS_DIR}"
BIN_DIR="$(swift build -c release --package-path "${MACOS_DIR}" --show-bin-path)"
EXECUTABLE_PATH="${BIN_DIR}/${APP_NAME}"

if [ ! -x "${EXECUTABLE_PATH}" ]; then
    echo "Error: Release executable not found at ${EXECUTABLE_PATH}" >&2
    exit 1
fi

echo "==> [3/6] Assembling ${APP_NAME}.app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_BIN_DIR}" "${RESOURCES_DIR}"

cp -f "${EXECUTABLE_PATH}" "${MACOS_BIN_DIR}/${APP_NAME}"
chmod +x "${MACOS_BIN_DIR}/${APP_NAME}"

# Copy SwiftPM resource bundle(s) (e.g. CampusEntry_CampusEntryCore.bundle) into Contents/Resources/
shopt -s nullglob
bundles=("${BIN_DIR}"/*.bundle)
shopt -u nullglob
for bundle in "${bundles[@]}"; do
    bundle_name="$(basename "${bundle}")"
    rm -rf "${RESOURCES_DIR:?}/${bundle_name}"
    cp -R "${bundle}" "${RESOURCES_DIR}/${bundle_name}"
    echo "Copied resource bundle: ${bundle_name}"
done

echo "==> [4/6] Generating ${APP_NAME}.icns..."
swift "${SCRIPT_DIR}/generate-icon.swift" "${ICNS_PATH}"

cat > "${CONTENTS_DIR}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>教务直达</string>
    <key>CFBundleExecutable</key>
    <string>CampusEntry</string>
    <key>CFBundleIconFile</key>
    <string>CampusEntry</string>
    <key>CFBundleIdentifier</key>
    <string>cn.edu.sues.campus-entry</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>教务直达</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <false/>
    </dict>
</dict>
</plist>
PLIST

echo "==> [5/6] Ad-hoc code signing ${APP_NAME}.app..."
codesign --deep --force -s - "${APP_BUNDLE}"
codesign --verify --deep --strict "${APP_BUNDLE}"

echo "==> [6/6] Creating ${APP_NAME}-${VERSION}-macOS.dmg..."
rm -rf "${DMG_STAGING_DIR}" "${DMG_PATH}"
mkdir -p "${DMG_STAGING_DIR}"
cp -R "${APP_BUNDLE}" "${DMG_STAGING_DIR}/${APP_NAME}.app"
ln -s /Applications "${DMG_STAGING_DIR}/Applications"

hdiutil create \
    -volname "教务直达 ${VERSION}" \
    -srcfolder "${DMG_STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

rm -rf "${DMG_STAGING_DIR}"

echo "Build complete:"
echo "  App: ${APP_BUNDLE}"
echo "  DMG: ${DMG_PATH}"
