#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# CI uses Xcode. --command-line-tools is a local fallback without asset catalogs.
mode=${1:-xcode}
if [[ "$mode" != xcode && "$mode" != --command-line-tools ]]; then
  echo "Usage: RELEASE_VERSION=0.5.0 $0 [--command-line-tools]" >&2
  exit 2
fi
version=${RELEASE_VERSION:-$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);/\1/p' CLIProxyPoolWidget.xcodeproj/project.pbxproj | head -1)}
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "RELEASE_VERSION must be a numeric major.minor.patch version" >&2
  exit 2
fi
build_number=${BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' App/Info.plist)}
if [[ ! "$build_number" =~ ^[0-9]+$ ]]; then
  echo "BUILD_NUMBER must be numeric" >&2
  exit 2
fi
mkdir -p .build dist
stage=$(mktemp -d "$PWD/.build/release.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/CLIProxyPoolWidget.app"
extension="$app/Contents/PlugIns/CLIProxyPoolWidgetExtension.appex"

if [[ "$mode" == xcode ]]; then
  if ! xcodebuild -version >/dev/null 2>&1; then
    echo "Full Xcode is required. For a local compiler build, use --command-line-tools." >&2
    exit 1
  fi
  xcodebuild -project CLIProxyPoolWidget.xcodeproj -scheme CLIProxyPoolWidget \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$stage/DerivedData" \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    MARKETING_VERSION="$version" build
  ditto "$stage/DerivedData/Build/Products/Release/CLIProxyPoolWidget.app" "$app"
else
  sdk=${MACOS_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$extension/Contents/MacOS"
  for arch in arm64 x86_64; do
    xcrun swiftc -sdk "$sdk" -target "$arch-apple-macosx14.0" -swift-version 6 \
      -O -whole-module-optimization -parse-as-library -module-name CLIProxyPoolWidget \
      Shared/*.swift App/*.swift -o "$stage/app-$arch"
    xcrun swiftc -sdk "$sdk" -target "$arch-apple-macosx14.0" -swift-version 6 \
      -O -whole-module-optimization -parse-as-library -application-extension -module-name CLIProxyPoolWidgetExtension \
      Shared/*.swift Widget/CLIProxyPoolWidget.swift -o "$stage/widget-$arch"
  done
  xcrun lipo -create "$stage/app-arm64" "$stage/app-x86_64" -output "$app/Contents/MacOS/CLIProxyPoolWidget"
  xcrun lipo -create "$stage/widget-arm64" "$stage/widget-x86_64" -output "$extension/Contents/MacOS/CLIProxyPoolWidgetExtension"
  cp App/Info.plist "$app/Contents/Info.plist"
  cp Widget/Info.plist "$extension/Contents/Info.plist"
  # Build an icns from the source image; actool belongs to full Xcode.
  mkdir "$stage/AppIcon.iconset"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/clipool-logo.png --out "$stage/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Resources/clipool-logo.png --out "$stage/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$stage/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c 'Add CFBundleIconFile string AppIcon' "$app/Contents/Info.plist"
fi

# Apply identical release metadata to the app and its embedded extension.
for bundle in "$app" "$extension"; do
  plist="$bundle/Contents/Info.plist"
  name=$(basename "$bundle")
  name=${name%.*}
  identifier=com.bayfold.CLIProxyPoolWidget
  if [[ "$bundle" == "$extension" ]]; then identifier+=.WidgetExtension; fi
  /usr/libexec/PlistBuddy -c "Set CFBundleExecutable $name" "$plist"
  /usr/libexec/PlistBuddy -c "Set CFBundleIdentifier $identifier" "$plist"
  /usr/libexec/PlistBuddy -c "Set CFBundleName $name" "$plist"
  /usr/libexec/PlistBuddy -c 'Set CFBundleDevelopmentRegion en' "$plist"
  /usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $version" "$plist"
  /usr/libexec/PlistBuddy -c "Set CFBundleVersion $build_number" "$plist"
  if [[ "$bundle" == "$app" ]]; then
    /usr/libexec/PlistBuddy -c 'Set LSMinimumSystemVersion 14.0' "$plist"
  fi
  plutil -lint "$plist"
  for arch in arm64 x86_64; do
    xcrun lipo "$bundle/Contents/MacOS/$name" -verify_arch "$arch"
  done
done
# Community builds: ad-hoc signatures, no Apple certificate or notarization.
codesign --force --sign - --entitlements Widget/CLIProxyPoolWidgetExtension.entitlements "$extension"
codesign --force --sign - --entitlements App/CLIProxyPoolWidget.entitlements "$app"
codesign --verify --deep --strict "$app"

basename="CLIProxyPoolWidget-$version-universal"
ditto -c -k --sequesterRsrc --keepParent "$app" "dist/$basename.app.zip"
mkdir "$stage/dmg"
ditto "$app" "$stage/dmg/CLIProxyPoolWidget.app"
ln -s /Applications "$stage/dmg/Applications"
hdiutil create -volname 'Bayfold Pool Watch' -srcfolder "$stage/dmg" -ov -format UDZO "dist/$basename.dmg"
(cd dist && shasum -a 256 "$basename.app.zip" "$basename.dmg" > "$basename.sha256")
printf '\nRelease artifacts:\n%s\n%s\n%s\n' "$PWD/dist/$basename.app.zip" "$PWD/dist/$basename.dmg" "$PWD/dist/$basename.sha256"
