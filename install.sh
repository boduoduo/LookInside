#!/bin/bash
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
BINARY="lookinside"
INSTALL_DIR="${PREFIX}/bin"
DEFAULT_VERSION="1.3.0"

print_help() {
    cat <<EOF
Usage: install.sh [VERSION]

Install lookinside CLI binary. Default install: ${INSTALL_DIR}/${BINARY}

  VERSION   Version to install (default: ${DEFAULT_VERSION})
            Available versions: https://github.com/boduoduo/LookInside/releases

Options:
  PREFIX    Install prefix (default: /usr/local). Example: PREFIX=~/.local install.sh

Examples:
  install.sh                # install ${DEFAULT_VERSION}
  install.sh 1.2.0          # install a specific version
  PREFIX=~/.local install.sh  # install without sudo

EOF
    exit 0
}

main() {
    local version arch asset_url use_sudo

    version="${1:-${DEFAULT_VERSION}}"
    [[ "$version" == "-h" || "$version" == "--help" ]] && print_help

    arch="arm64"
    if [[ "$(uname -m)" == "x86_64" ]]; then
        arch="x86_64"
    fi

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

    use_sudo=""
    if [[ -d "${INSTALL_DIR}" ]] && [[ ! -w "${INSTALL_DIR}" ]]; then
        use_sudo="sudo"
    elif [[ ! -d "${INSTALL_DIR}" ]]; then
        mkdir -p "${INSTALL_DIR}" 2>/dev/null || use_sudo="sudo"
    fi

    ${use_sudo} mkdir -p "${INSTALL_DIR}"
    ${use_sudo} mv -f "${tmpdir}/${BINARY}" "${INSTALL_DIR}/${BINARY}"
    ${use_sudo} chmod +x "${INSTALL_DIR}/${BINARY}"

    echo ""
    "${INSTALL_DIR}/${BINARY}" --version 2>/dev/null || echo "lookinside ${version} installed"
    echo "Done. Run 'lookinside --help' to get started."
}

main "$@"
