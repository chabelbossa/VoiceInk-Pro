#!/bin/bash

# Configuration
APP_NAME="VoiceInk"
PRODUCT_NAME="VoiceInk Pro 2.1 Maintenance"
SCHEME_NAME="VoiceInk"
BUILD_DIR="./build_output"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/Export"
# Persistent SPM packages dir — kept between builds to avoid repeated downloads
SPM_PACKAGES_DIR="./.spm-packages"

# Clean previous build (keep SourcePackages to avoid re-downloading)
echo "🔨 Cleaning previous build..."
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
mkdir -p "$BUILD_DIR"
mkdir -p "$SPM_PACKAGES_DIR"

# Resolve packages first (with fresh checkout dir)
echo "🔨 Resolving Swift packages..."
xcodebuild -resolvePackageDependencies \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME_NAME" \
  -clonedSourcePackagesDirPath "$SPM_PACKAGES_DIR"

if [ $? -ne 0 ]; then
    echo "❌ Package resolution failed"
    exit 1
fi

# Build Archive (Release Mode)
echo "🔨 Archiving $APP_NAME..."
xcodebuild archive \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME_NAME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination 'generic/platform=macOS' \
  -clonedSourcePackagesDirPath "$SPM_PACKAGES_DIR" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  PROVISIONING_PROFILE_SPECIFIER="" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' \
  > /dev/null

if [ $? -ne 0 ]; then
    echo "❌ Archive failed"
    exit 1
fi

# Export Application
echo "🔨 Exporting Application..."
# Manually copy the .app since we can't use exportArchive without signing
mkdir -p "$EXPORT_PATH"
cp -R "$ARCHIVE_PATH/Products/Applications/$PRODUCT_NAME.app" "$EXPORT_PATH/$PRODUCT_NAME.app"

if [ $? -eq 0 ]; then

    echo "🔨 Cleaning quarantine attributes..."
    xattr -cr "$EXPORT_PATH/$PRODUCT_NAME.app"

    echo "🔨 Re-signing frameworks and app..."
    # Re-sign all frameworks and dylibs deeply
    find "$EXPORT_PATH/$PRODUCT_NAME.app/Contents/Frameworks" \( -name "*.framework" -o -name "*.dylib" \) -print0 | while IFS= read -r -d '' item; do
        echo "   Signing $item"
        codesign --force --sign "-" --preserve-metadata=identifier,entitlements "$item" &> /dev/null
    done
    
    # Re-sign the main app
    codesign --force --sign "-" --preserve-metadata=identifier,entitlements "$EXPORT_PATH/$PRODUCT_NAME.app" &> /dev/null

    echo "✅ Build Successful!"
    echo "📍 App Location: $EXPORT_PATH/$PRODUCT_NAME.app"
    
    # Move to root for easier access
    rm -rf "./$PRODUCT_NAME.app"
    cp -R "$EXPORT_PATH/$PRODUCT_NAME.app" ./
    echo "📍 Copied to: ./$PRODUCT_NAME.app"
else
    echo "❌ Export failed"
    exit 1
fi
