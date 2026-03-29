#!/bin/bash
# claude-workspace-snapshot uninstaller

set -euo pipefail

SCRIPTS_DIR="${HOME}/.claude/scripts"
FILES="workspace-snapshot.ps1 workspace-snapshot.bat workspace-restore.ps1 workspace-restore.bat"

echo ""
echo "  Uninstalling claude-workspace-snapshot..."

for f in $FILES; do
    path="${SCRIPTS_DIR}/${f}"
    if [ -f "$path" ]; then
        rm "$path"
        echo "  Removed: ${f}"
    fi
done

echo ""
echo "  Uninstalled. Your workspace.json was not removed."
echo ""
