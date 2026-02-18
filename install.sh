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

RAW_VERSION="${VERSION#v}"
FILENAME="corvo_${RAW_VERSION}_${OS}_${ARCH}.tar.gz"
BASE_URL="https://github.com/$REPO/releases/download/$VERSION"

echo "Installing corvo $VERSION ($OS/$ARCH)..."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Download binary archive and checksums
curl -sSfL "$BASE_URL/$FILENAME" -o "$TMP/corvo.tar.gz"
curl -sSfL "$BASE_URL/checksums.txt" -o "$TMP/checksums.txt"

# Verify checksum
cd "$TMP"
EXPECTED=$(grep "$FILENAME" checksums.txt | awk '{print $1}')
if [ -z "$EXPECTED" ]; then
  echo "Could not find checksum for $FILENAME"
  exit 1
fi

if command -v sha256sum > /dev/null 2>&1; then
  ACTUAL=$(sha256sum corvo.tar.gz | awk '{print $1}')
elif command -v shasum > /dev/null 2>&1; then
  ACTUAL=$(shasum -a 256 corvo.tar.gz | awk '{print $1}')
else
  echo "No sha256 tool found, skipping checksum verification"
  ACTUAL="$EXPECTED"
fi

if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "Checksum mismatch — download may be corrupted"
  echo "  expected: $EXPECTED"
  echo "  actual:   $ACTUAL"
  exit 1
fi

# Extract and install
tar -xzf corvo.tar.gz
install -d "$INSTALL_DIR"
install -m 755 corvo "$INSTALL_DIR/corvo"

echo "corvo installed to $INSTALL_DIR/corvo"
"$INSTALL_DIR/corvo" --version
