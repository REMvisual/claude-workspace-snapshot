#!/bin/bash
# terminal-workspace-snapshot installer
# Usage: curl -fsSL https://raw.githubusercontent.com/REMvisual/terminal-workspace-snapshot/master/install.sh | bash
#
# Pin to a specific version:
#   CWSS_BRANCH=v1.0.0 curl -fsSL ... | bash

set -euo pipefail

REPO="REMvisual/terminal-workspace-snapshot"
BRANCH="${CWSS_BRANCH:-master}"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/scripts"
SCRIPTS_DIR="${HOME}/.claude/scripts"

echo ""
echo "  Installing terminal-workspace-snapshot..."

mkdir -p "${SCRIPTS_DIR}"

FILES="workspace-snapshot.ps1 workspace-snapshot.bat workspace-restore.ps1 workspace-restore.bat"

for f in $FILES; do
    if curl -fsSL "${BASE_URL}/${f}" -o "${SCRIPTS_DIR}/${f}"; then
        echo "  Downloaded: ${f}"
    else
        echo "  FAILED: ${f}"
        exit 1
    fi
done

echo ""
echo "  Installed to: ${SCRIPTS_DIR}"
echo ""
echo "  Usage:"
echo "    Snapshot: ${SCRIPTS_DIR}/workspace-snapshot.bat"
echo "    Restore:  ${SCRIPTS_DIR}/workspace-restore.bat"
echo ""
