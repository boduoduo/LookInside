#!/bin/bash
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
BINARY="lookinside"
INSTALL_DIR="${PREFIX}/bin"
# Default: local when run interactively, release when piped (curl|bash)
if [[ -t 0 ]] && [[ "${1:-}" != "--release" ]]; then
    SOURCE="local"
else
    SOURCE="release"
fi

print_help() {
    cat <<EOF
Usage: install.sh [OPTIONS] [VERSION]

Install lookinside CLI binary from local build or GitHub release.

Options:
  --local             Install from local .build/release/ (default)
  --release [VERSION] Install from GitHub release (latest if VERSION omitted)
  PREFIX              Install prefix (default: /usr/local). Example: PREFIX=~/.local install.sh

Examples:
  install.sh                    # install local build
  install.sh --release          # install latest GitHub release
  install.sh --release 1.3.0   # install specific release
  PREFIX=~/.local install.sh    # install without sudo

EOF
    exit 0
}

main() {
    local version arch asset_url use_sudo src

    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && print_help

    # Parse source option
    if [[ "${1:-}" == "--release" ]]; then
        SOURCE="release"
        version="${2:-}"
    elif [[ "${1:-}" == "--local" ]]; then
        SOURCE="local"
    fi

    # Resolve version for release mode
    if [[ "$SOURCE" == "release" ]]; then
        if [[ -z "${version:-}" ]]; then
            echo "==> Fetching latest release version..."
            version=$(curl -fsSL https://api.github.com/repos/boduoduo/LookInside/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
            if [[ -z "$version" ]]; then
                echo "Error: failed to determine latest release version"
                exit 1
            fi
            echo "==> Latest version: ${version}"
        fi
    fi

    mkdir -p "${INSTALL_DIR}" 2>/dev/null || use_sudo="sudo"
    ${use_sudo:-} mkdir -p "${INSTALL_DIR}"

    if [[ "$SOURCE" == "local" ]]; then
        src="$(cd "$(dirname "$0")" && pwd)/.build/arm64-apple-macosx/release/${BINARY}"
        if [[ ! -f "$src" ]]; then
            echo "Error: local binary not found at $src"
            echo "Run 'swift build -c release --product lookinside' first"
            exit 1
        fi
        echo "==> Installing local build to ${INSTALL_DIR}..."
        ${use_sudo:-} cp -f "$src" "${INSTALL_DIR}/${BINARY}"
    else
        arch="arm64"
        [[ "$(uname -m)" == "x86_64" ]] && arch="x86_64"

        asset_url="https://github.com/boduoduo/LookInside/releases/download/${version}/lookinside-${version}-${arch}.tar.gz"

        echo "==> Installing lookinside ${version} (${arch}) to ${INSTALL_DIR}..."

        cleanup() { rm -rf "${tmpdir}"; }
        tmpdir=$(mktemp -d)
        trap cleanup EXIT

        echo "==> Downloading ${asset_url}"
        if ! curl -fsSL -o "${tmpdir}/${BINARY}.tar.gz" "${asset_url}"; then
            echo "Error: failed to download ${asset_url}"
            echo "Check that the version exists: https://github.com/boduoduo/LookInside/releases"
            exit 1
        fi

        echo "==> Extracting..."
        tar xzf "${tmpdir}/${BINARY}.tar.gz" -C "${tmpdir}"
        ${use_sudo:-} mv -f "${tmpdir}/${BINARY}" "${INSTALL_DIR}/${BINARY}"
    fi

    ${use_sudo:-} chmod +x "${INSTALL_DIR}/${BINARY}"

    # Remove quarantine attribute (Gatekeeper workaround for unsigned binaries)
    if xattr -l "${INSTALL_DIR}/${BINARY}" 2>/dev/null | grep -q com.apple.quarantine; then
        echo "==> Removing quarantine attribute..."
        ${use_sudo:-} xattr -cr "${INSTALL_DIR}/${BINARY}"
    fi

    echo ""
    "${INSTALL_DIR}/${BINARY}" list 2>/dev/null || echo "lookinside installed to ${INSTALL_DIR}/${BINARY}"
    echo "Done."
}

main "$@"
