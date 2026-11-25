#!/usr/bin/env bash
# Install optional external dependencies for mirna-target-tools.
#
# Security posture:
#   * never calls sudo and never installs system packages automatically
#   * downloads over HTTPS only, into a private mktemp directory
#   * refuses to build a source tarball unless its SHA-256 is supplied
#     (MIRANDA_SHA256=... or --sha256 ...) or --allow-unverified is passed
#   * installs into a user prefix (~/.local by default), not /usr/local
#
# Usage:
#   bash scripts/install_dependencies.sh [--allow-unverified]
#                                        [--sha256 HASH] [--prefix DIR]
set -euo pipefail

ALLOW_UNVERIFIED=0
PREFIX="${MIRANDA_PREFIX:-$HOME/.local}"
MIRANDA_SHA256="${MIRANDA_SHA256:-}"
MIRANDA_VERSION="3.3a"
MIRANDA_URL="https://github.com/miRanda/miRanda/archive/refs/tags/${MIRANDA_VERSION}.tar.gz"

TMP_DIR=""
cleanup() {
    if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then
        rm -rf -- "${TMP_DIR}"
    fi
}
trap cleanup EXIT HUP INT TERM

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --allow-unverified) ALLOW_UNVERIFIED=1; shift ;;
        --sha256)
            [ "$#" -ge 2 ] || { echo "Error: --sha256 needs a value" >&2; exit 2; }
            MIRANDA_SHA256="$2"; shift 2 ;;
        --prefix)
            [ "$#" -ge 2 ] || { echo "Error: --prefix needs a value" >&2; exit 2; }
            PREFIX="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: unknown option '$1'" >&2; exit 2 ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }

sha256_of() {
    if have sha256sum; then
        sha256sum "$1" | awk '{print $1}'
    elif have shasum; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        echo "Error: no sha256sum/shasum available; cannot verify downloads." >&2
        return 1
    fi
}

install_python_deps() {
    echo "Installing Python packages (user site, no sudo) ..."
    if ! python3 -m pip install --user --upgrade pandas numpy mygene matplotlib; then
        echo "  pip install failed. On Debian/Ubuntu with EXTERNALLY-MANAGED Python, use a"
        echo "  virtualenv or your distro packages, e.g.:"
        echo "    sudo apt-get install -y python3-pandas python3-numpy python3-matplotlib"
        return 1
    fi
}

install_miranda_from_source() {
    local archive member_list got expected
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/miranda-build.XXXXXX")"
    archive="${TMP_DIR}/miRanda-${MIRANDA_VERSION}.tar.gz"

    echo "Downloading miRanda ${MIRANDA_VERSION} over HTTPS ..."
    curl -fsSL --proto '=https' --tlsv1.2 --max-time 300 \
        -o "${archive}" "${MIRANDA_URL}"

    member_list="$(tar -tzf "${archive}")"
    if printf '%s\n' "${member_list}" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
        echo "Error: archive contains absolute or parent-traversal paths; aborting." >&2
        exit 1
    fi

    got="$(sha256_of "${archive}")"
    if [ -n "${MIRANDA_SHA256}" ]; then
        expected="$(printf '%s' "${MIRANDA_SHA256}" | tr 'A-F' 'a-f')"
        if [ "${got}" != "${expected}" ]; then
            echo "Error: SHA-256 mismatch for miRanda tarball." >&2
            echo "  expected: ${expected}" >&2
            echo "  actual:   ${got}" >&2
            exit 1
        fi
        echo "SHA-256 verified: ${got}"
    elif [ "${ALLOW_UNVERIFIED}" -ne 1 ]; then
        echo "Refusing to build an unverified source tarball." >&2
        echo "  downloaded SHA-256: ${got}" >&2
        echo "  re-run with: --sha256 ${got}   (pin this hash)" >&2
        echo "  or, if you accept the risk: --allow-unverified" >&2
        exit 1
    else
        echo "WARNING: building an unverified tarball (SHA-256 ${got})." >&2
    fi

    tar -xzf "${archive}" -C "${TMP_DIR}"
    cd "${TMP_DIR}/miRanda-${MIRANDA_VERSION}"
    ./configure --prefix="${PREFIX}"
    make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
    make install
    echo "miRanda installed under ${PREFIX}"
    echo "Add to PATH if needed:  export PATH=\"${PREFIX}/bin:\$PATH\""
}

install_miranda() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -x "${script_dir}/install_miranda_conda.sh" ]; then
        echo "Installing the real miRanda 3.3a with conda (no sudo) ..."
        if bash "${script_dir}/install_miranda_conda.sh"; then
            return 0
        fi
        echo "  conda install did not complete; falling back to a pinned source build."
    fi
    install_miranda_from_source
}

echo "Installing optional dependencies for mirna-target-tools..."
echo "System packages are NEVER installed automatically (no sudo in this script)."
echo

install_python_deps || true

case "${OSTYPE:-}" in
    linux-gnu*|darwin*)
        install_miranda
        ;;
    *)
        echo "Unsupported OS '${OSTYPE:-unknown}': install miRanda manually." >&2
        ;;
esac

cat <<'EOF'

TargetScan is not distributed here. Download it yourself from:
  https://www.targetscan.org/cgi-bin/targetscan/data_download.cgi

Cytoscape (optional GUI) is available from:
  https://cytoscape.org/download.html

Finally, verify the environment:
  python3 scripts/check_env.py

Real miRanda 3.3a is required by the default workflow.
Verify it directly with:
  bash scripts/install_miranda_conda.sh --check
EOF
