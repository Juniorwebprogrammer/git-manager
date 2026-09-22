#!/usr/bin/env bash
# Genera build/deb/git-manager_<version>_amd64.deb a partir del bundle de
# release de Flutter Linux. Requiere: flutter, dpkg-deb.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="$(grep -m1 '^version:' pubspec.yaml | sed -E 's/version:\s*([0-9.]+).*/\1/')"
PKG_NAME="git-manager"
# Must match the GApplication ID in linux/CMakeLists.txt (APPLICATION_ID),
# which is also the running window's WM_CLASS/app_id. The .desktop
# filename and StartupWMClass need to match it, otherwise the dock/
# taskbar can't associate the running window with this launcher entry
# and its icon (even though the icon shows fine in the app menu, which
# reads the .desktop file directly instead of matching a window).
DESKTOP_ID="com.turinconconnect.git_manager"
ARCH="amd64"
STAGE_DIR="$ROOT_DIR/build/deb/${PKG_NAME}"
DEB_FILE="$ROOT_DIR/build/deb/${PKG_NAME}_${VERSION}_${ARCH}.deb"

echo "==> Compilando bundle de release..."
flutter build linux --release

echo "==> Preparando árbol del paquete en $STAGE_DIR"
rm -rf "$STAGE_DIR"
mkdir -p \
  "$STAGE_DIR/DEBIAN" \
  "$STAGE_DIR/opt/$PKG_NAME" \
  "$STAGE_DIR/usr/bin" \
  "$STAGE_DIR/usr/share/applications"

cp -r build/linux/x64/release/bundle/. "$STAGE_DIR/opt/$PKG_NAME/"

cat > "$STAGE_DIR/usr/bin/git-manager" <<'EOF'
#!/bin/sh
exec /opt/git-manager/git_manager "$@"
EOF
chmod 755 "$STAGE_DIR/usr/bin/git-manager"

cp packaging/uninstall.sh "$STAGE_DIR/opt/$PKG_NAME/uninstall.sh"
chmod 755 "$STAGE_DIR/opt/$PKG_NAME/uninstall.sh"

cp "packaging/${DESKTOP_ID}.desktop" "$STAGE_DIR/usr/share/applications/${DESKTOP_ID}.desktop"
cp "packaging/${DESKTOP_ID}.uninstall.desktop" \
  "$STAGE_DIR/usr/share/applications/${DESKTOP_ID}.uninstall.desktop"

for size in 16 32 48 64 128 192 256 512; do
  icon_dir="$STAGE_DIR/usr/share/icons/hicolor/${size}x${size}/apps"
  mkdir -p "$icon_dir"
  cp "packaging/icons/${size}.png" "$icon_dir/git-manager.png"
done

cat > "$STAGE_DIR/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $VERSION
Section: devel
Priority: optional
Architecture: $ARCH
Depends: libgtk-3-0, libsecret-1-0, git, polkitd | policykit-1
Recommends: zenity, libnotify-bin
Maintainer: Junior Garcia <junior@turinconconnect.com>
Description: GitHub account manager to switch your git identity in one click
 Git Manager is a desktop app to add multiple GitHub accounts, verify
 them against the API, and switch the global git identity (user.name,
 user.email and HTTPS credentials) between them without using the
 command line. Includes an "Uninstall Git Manager" menu entry to
 remove it without a terminal.
EOF

cat > "$STAGE_DIR/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 755 "$STAGE_DIR/DEBIAN/postinst"

cat > "$STAGE_DIR/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 755 "$STAGE_DIR/DEBIAN/postrm"

find "$STAGE_DIR" -type d -exec chmod 755 {} \;

echo "==> Empaquetando .deb"
mkdir -p "$ROOT_DIR/build/deb"
dpkg-deb --build --root-owner-group "$STAGE_DIR" "$DEB_FILE"

echo "==> Listo: $DEB_FILE"
