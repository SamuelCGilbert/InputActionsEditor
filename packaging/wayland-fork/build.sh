#!/bin/bash
# Builds the packages of this unofficial fork: .deb, .rpm, AppImage and a tarball.
# Run as root in a clean Ubuntu 24.04 container. The GitHub workflow
# .github/workflows/release.yml does this; to build them yourself:
#   docker run --rm -v "$PWD:/src" -w /src ubuntu:24.04 packaging/wayland-fork/build.sh
# The KDE helpers are built against KDE Frameworks from KDE neon's Ubuntu 24.04
# archive, so the packages run on Ubuntu 24.04 and newer (the official ones are
# built on 26.04). The packages end up in packaging/out.
set -euo pipefail

SRC=$(cd "$(dirname "$0")/../.." && pwd)
cd "$SRC"
APP_ID=dev.luwx.input_actions_editor
APP_NAME=input-actions-editor
BINARY_NAME=input_actions_editor
# 0.9.0-wayland.1 -> 0.9.0+wayland1
VERSION=${VERSION:-$(sed -n 's/^version: \([0-9.]*\).*/\1/p' pubspec.yaml)-wayland.0}
PKG_VERSION=$(sed -E 's/-wayland\.?/+wayland/' <<<"$VERSION")
MAINTAINER="Sam Gilbert <86975269+SamuelCGilbert@users.noreply.github.com>"
FLUTTER_VERSION=3.44.9
FLUTTER_SHA256=a9120fa4a01048bdef438ddc3a2d4b7389662ea98a95db86eeaf10382bc4efcb

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg git xz-utils unzip file
mkdir -p /etc/apt/keyrings
curl -fsSL https://archive.neon.kde.org/public.key | gpg --dearmor > /etc/apt/keyrings/neon.gpg
echo "deb [signed-by=/etc/apt/keyrings/neon.gpg] https://archive.neon.kde.org/user noble main" \
  > /etc/apt/sources.list.d/neon.list
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  clang cmake ninja-build pkg-config build-essential libgtk-3-dev liblzma-dev \
  qt6-base-dev extra-cmake-modules libkf6iconthemes-dev libkf6service-dev \
  ruby-dev rpm
gem install --no-document fpm >/dev/null

# Flutter, the version the official release uses
if [ ! -x /opt/flutter/bin/flutter ]; then
  curl -fsSLo /tmp/flutter.tar.xz \
    "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_$FLUTTER_VERSION-stable.tar.xz"
  echo "$FLUTTER_SHA256  /tmp/flutter.tar.xz" | sha256sum -c
  tar -xJf /tmp/flutter.tar.xz -C /opt
fi
export PATH=/opt/flutter/bin:$PATH
git config --global --add safe.directory /opt/flutter
git config --global --add safe.directory "$SRC"
flutter config --no-analytics >/dev/null

flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter test
flutter build linux --release
BUNDLE=build/linux/x64/release/bundle
test -x "$BUNDLE/kde_icon_lookup" && test -x "$BUNDLE/kde_key_lookup"

# Same layout as the official packages
STAGE=packaging/stage
OUT=packaging/out
rm -rf "$STAGE" "$OUT" packaging/AppDir
mkdir -p "$STAGE/opt/$APP_NAME" "$STAGE/usr/bin" "$STAGE/usr/share/applications" "$OUT"
cp -r "$BUNDLE"/. "$STAGE/opt/$APP_NAME/"
rm -f "$STAGE/opt/$APP_NAME/data/flutter_assets/kernel_blob.bin"
printf '#!/bin/sh\nexec /opt/%s/%s "$@"\n' "$APP_NAME" "$BINARY_NAME" > "$STAGE/usr/bin/$BINARY_NAME"
chmod +x "$STAGE/usr/bin/$BINARY_NAME"
cp "linux/$APP_ID.desktop" "$STAGE/usr/share/applications/"
for size in 16 32 48 64 128 256 512; do
  install -Dm644 "linux/icons/${size}x${size}/apps/$APP_ID.png" \
    "$STAGE/usr/share/icons/hicolor/${size}x${size}/apps/$APP_ID.png"
done

# The KDE helpers need Qt 6 and KDE Frameworks 6. The app works without them
# (it only loses KDE icon and key names), so the .deb recommends them, by their
# KDE neon names or else their Debian and Ubuntu names. The .rpm depends on
# them, like the official one.
DEB_RECOMMENDS=(
  --deb-recommends "qt6-base | libqt6gui6t64 | libqt6gui6"
  --deb-recommends "kf6-kiconthemes | libkf6iconthemes6"
  --deb-recommends "kf6-kservice | libkf6service6"
)

# Epoch 1 so the official packages don't replace this one
DESC="Input Actions configurator, unofficial fork with a gesture exceptions page."
URL=https://github.com/SamuelCGilbert/InputActionsEditor
fpm -s dir -t deb --name "$APP_NAME" --version "$PKG_VERSION" --epoch 1 --architecture amd64 \
  --description "$DESC" --maintainer "$MAINTAINER" --url "$URL" --license GPL-3.0 \
  --depends "libgtk-3-0 (>= 3.24)" --depends libglib2.0-0 --depends libstdc++6 "${DEB_RECOMMENDS[@]}" \
  --deb-compression xz --package "$OUT/${APP_NAME}_${PKG_VERSION}_amd64.deb" -C "$STAGE" .
fpm -s dir -t rpm --name "$APP_NAME" --version "$PKG_VERSION" --epoch 1 --architecture x86_64 \
  --description "$DESC" --maintainer "$MAINTAINER" --url "$URL" --license GPL-3.0 \
  --depends gtk3 --depends glib2 --depends libstdc++ \
  --depends qt6-qtbase --depends qt6-qtbase-gui --depends kf6-kiconthemes --depends kf6-kservice \
  --package "$OUT/${APP_NAME}-${PKG_VERSION}-x86_64.rpm" -C "$STAGE" .

# AppImage
APPDIR=packaging/AppDir
mkdir -p "$APPDIR/bundle"
cp -r "$BUNDLE"/. "$APPDIR/bundle/"
rm -f "$APPDIR/bundle/data/flutter_assets/kernel_blob.bin"
{
  echo '#!/bin/bash'
  echo 'SELF=$(readlink -f "$0")'
  echo 'HERE=${SELF%/*}'
  echo 'export XDG_DATA_DIRS="$HERE/bundle/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"'
  printf 'exec "$HERE/bundle/%s" "$@"\n' "$BINARY_NAME"
} > "$APPDIR/AppRun"
chmod +x "$APPDIR/AppRun"
cp "linux/$APP_ID.desktop" "$APPDIR/"
cp "linux/icons/256x256/apps/$APP_ID.png" "$APPDIR/$APP_ID.png"
TOOL=/tmp/appimagetool
[ -x $TOOL ] || curl -fsSLo $TOOL \
  https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x $TOOL
# Clear the AppImage marker bytes, so a host with an AppImage handler in
# binfmt_misc (such as AppImageLauncher) doesn't take over running the tool
printf '\0\0\0' | dd of=$TOOL bs=1 seek=8 conv=notrunc status=none
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 $TOOL "$APPDIR" "$OUT/${APP_NAME}-${VERSION}-x86_64.AppImage"

tar -czf "$OUT/${APP_NAME}-${VERSION}-linux-x86_64.tar.gz" -C build/linux/x64/release bundle
(cd "$OUT" && sha256sum * > SHA256SUMS && cat SHA256SUMS)
