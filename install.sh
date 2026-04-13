#!/bin/sh
set -e

REPO="corvohq/corvo"
INSTALL_DIR="${CORVO_INSTALL_DIR:-/usr/local/bin}"

# Detect OS
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$OS" in
  linux)  OS="linux"  ;;
  darwin) OS="darwin" ;;
  *)
    echo "Unsupported OS: $OS"
    exit 1
    ;;
esac

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)  ARCH="amd64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *)
    echo "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

# Fetch latest version
VERSION=$(curl -sSf "https://api.github.com/repos/$REPO/releases/latest" \
  | grep '"tag_name"' \
  | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

if [ -z "$VERSION" ]; then
  echo "Failed to fetch latest version from GitHub"
  exit 1
fi

FILENAME="corvo-${OS}-${ARCH}.tar.gz"
BASE_URL="https://github.com/$REPO/releases/download/$VERSION"

echo "Installing corvo $VERSION ($OS/$ARCH)..."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl -sSfL "$BASE_URL/$FILENAME" -o "$TMP/corvo.tar.gz"

cd "$TMP"
tar -xzf corvo.tar.gz
install -d "$INSTALL_DIR"
install -m 755 corvo "$INSTALL_DIR/corvo"

if [ -f corvo-inspect ]; then
  install -m 755 corvo-inspect "$INSTALL_DIR/corvo-inspect"
fi

echo "corvo $VERSION installed to $INSTALL_DIR/corvo"
