#!/usr/bin/env bash
# Genera build/deb/git-manager_<version>_amd64.deb a partir del bundle de
# release de Flutter Linux. Requiere: flutter, dpkg-deb.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="$(grep -m1 '^version:' pubspec.yaml | sed -E 's/version:\s*([0-9.]+).*/\1/')"
PKG_NAME="git-manager"
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

cp packaging/git-manager.desktop "$STAGE_DIR/usr/share/applications/git-manager.desktop"

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
Depends: libgtk-3-0, libsecret-1-0, git
Maintainer: Junior Garcia <junior.sacarias.garcia.diaz@volenday.com>
Description: Gestor de cuentas de GitHub para cambiar de identidad git en un clic
 Git Manager es una app de escritorio para anadir varias cuentas de
 GitHub, verificarlas contra la API y cambiar la identidad global de git
 (user.name, user.email y credenciales HTTPS) entre ellas sin usar la
 linea de comandos.
EOF

find "$STAGE_DIR" -type d -exec chmod 755 {} \;

echo "==> Empaquetando .deb"
mkdir -p "$ROOT_DIR/build/deb"
dpkg-deb --build --root-owner-group "$STAGE_DIR" "$DEB_FILE"

echo "==> Listo: $DEB_FILE"
