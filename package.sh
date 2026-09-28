#!/usr/bin/env bash
set -euo pipefail

TAG=${1:?upstream release tag is required}
UPSTREAM_VERSION=${2:?upstream version is required}
VERSION=${3:?Debian package version is required}
ARCH=${4:?Debian architecture is required}
TARGET=${5:?upstream target triple is required}

UPSTREAM_REPO=openai/codex
PACKAGE=openai-codex-cli
CODEX_ASSET="codex-${TARGET}.tar.gz"
HOST_ASSET="codex-code-mode-host-${TARGET}.tar.gz"

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

DOWNLOAD="$WORK/download"
EXTRACT="$WORK/extract"
PKGROOT="$WORK/pkg"
INSTALL_ROOT="$PKGROOT/usr/lib/openai-codex-cli"
DOCROOT="$PKGROOT/usr/share/doc/openai-codex-cli"

mkdir -p "$DOWNLOAD" "$EXTRACT" "$INSTALL_ROOT" "$DOCROOT/licenses" "$PKGROOT/usr/bin" "$PKGROOT/DEBIAN" "$ROOT/dist"

gh release download "$TAG" \
  --repo "$UPSTREAM_REPO" \
  --pattern "$CODEX_ASSET" \
  --pattern "$HOST_ASSET" \
  --dir "$DOWNLOAD"

release_json=$(gh api "repos/${UPSTREAM_REPO}/releases/tags/${TAG}")

verify_github_digest() {
  local filename=$1
  local expected actual
  expected=$(jq -r --arg name "$filename" '.assets[] | select(.name == $name) | .digest // empty' <<<"$release_json")
  if [[ ! $expected =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "Missing SHA-256 digest for ${filename} in GitHub Release metadata" >&2
    exit 1
  fi
  actual=$(sha256sum "$DOWNLOAD/$filename" | awk '{print $1}')
  if [[ "sha256:${actual}" != "$expected" ]]; then
    echo "GitHub Release digest mismatch for ${filename}" >&2
    exit 1
  fi
}

verify_github_digest "$CODEX_ASSET"
verify_github_digest "$HOST_ASSET"

tar -xzf "$DOWNLOAD/$CODEX_ASSET" -C "$EXTRACT"
tar -xzf "$DOWNLOAD/$HOST_ASSET" -C "$EXTRACT"

test -x "$EXTRACT/codex-${TARGET}"
test -x "$EXTRACT/codex-code-mode-host-${TARGET}"
"$EXTRACT/codex-${TARGET}" --version | grep -Fx "codex-cli ${UPSTREAM_VERSION}"

mkdir -p "$INSTALL_ROOT/bin"
install -m0755 "$EXTRACT/codex-${TARGET}" "$INSTALL_ROOT/bin/codex"
install -m0755 "$EXTRACT/codex-code-mode-host-${TARGET}" "$INSTALL_ROOT/bin/codex-code-mode-host"
ln -sfn bin/codex "$INSTALL_ROOT/codex"

# Normalize permissions from upstream archives. The package-owned runtime is
# immutable to ordinary users; all user state remains under CODEX_HOME.
find "$INSTALL_ROOT" -type d -exec chmod 0755 {} +
find "$INSTALL_ROOT" -type f -exec chmod go-w {} +
chmod 0755 \
  "$INSTALL_ROOT/bin/codex" \
  "$INSTALL_ROOT/bin/codex-code-mode-host"

cat > "$PKGROOT/usr/bin/codex" <<'EOF'
#!/bin/sh
set -eu

# Identify the top-level subcommand while allowing global options before it.
# Only the APT-managed CLI entrypoint is affected; VS Code uses its own bundled
# Codex executable and both clients continue to share the user's CODEX_HOME.
expect_value=0
for arg in "$@"; do
    if [ "$expect_value" -eq 1 ]; then
        expect_value=0
        continue
    fi

    case "$arg" in
        --)
            break
            ;;
        -c|--config|--enable|--disable|--remote|--remote-auth-token-env|-i|--image|-m|--model|--local-provider|-p|--profile|-s|--sandbox|-C|--cd|--add-dir|-a|--ask-for-approval)
            expect_value=1
            ;;
        --config=*|--enable=*|--disable=*|--remote=*|--remote-auth-token-env=*|--image=*|--model=*|--local-provider=*|--profile=*|--sandbox=*|--cd=*|--add-dir=*|--ask-for-approval=*)
            ;;
        -*)
            ;;
        update)
            echo "openai-codex-cli is managed by APT; Codex self-update is disabled." >&2
            echo "Use: sudo apt update && sudo apt install --only-upgrade openai-codex-cli" >&2
            exit 2
            ;;
        *)
            break
            ;;
    esac
done

exec /usr/lib/openai-codex-cli/bin/codex \
    -c check_for_update_on_startup=false \
    "$@"
EOF
chmod 0755 "$PKGROOT/usr/bin/codex"

# Preserve upstream license notices in the binary package.
gh api "repos/openai/codex/contents/LICENSE?ref=${TAG}" --jq .content | base64 -d > "$DOCROOT/licenses/Codex-Apache-2.0.txt"
gh api "repos/openai/codex/contents/NOTICE?ref=${TAG}" --jq .content | base64 -d > "$DOCROOT/NOTICE"

cat > "$DOCROOT/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: OpenAI Codex CLI
Source: https://github.com/openai/codex

Files: *
Copyright: OpenAI
License: Apache-2.0
 See licenses/Codex-Apache-2.0.txt and NOTICE.

EOF

installed_size=$(du -sk "$PKGROOT/usr" | awk '{print $1}')

awk -v version="$VERSION" -v arch="$ARCH" -v installed_size="$installed_size" '
  BEGIN { inserted = 0 }
  /^Description:/ && !inserted {
    print "Version: " version
    print "Architecture: " arch
    print "Installed-Size: " installed_size
    inserted = 1
  }
  { print }
' "$ROOT/debian/control" > "$PKGROOT/DEBIAN/control"

chmod 0644 "$PKGROOT/DEBIAN/control" "$DOCROOT/copyright" "$DOCROOT/NOTICE" "$DOCROOT/licenses/"*

output="$ROOT/dist/${PACKAGE}_${VERSION}_${ARCH}.deb"
rm -f "$output"
dpkg-deb --build --root-owner-group "$PKGROOT" "$output"

dpkg-deb --info "$output"
dpkg-deb --contents "$output" | grep -E '(usr/bin/codex|usr/lib/openai-codex-cli/bin/(codex|codex-code-mode-host)|usr/share/doc/openai-codex-cli)'
echo "Built $output"
