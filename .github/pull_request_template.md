## Description

What does this PR do and why?

## Related Issues

Closes #<!-- issue number -->

## Testing Checklist

- [ ] Tested on Windows 10 or Windows 11 with Windows Terminal
- [ ] Ran `workspace-snapshot.bat` with 2+ active Claude Code sessions and verified correct detection
- [ ] Ran `workspace-restore.bat` and verified tabs open with correct working directory, tab name, and color
- [ ] Verified no personal data, hardcoded paths, or session content in the code
- [ ] Tested with PowerShell 5.1 (not only PowerShell 7)
- [ ] Tested with both process-based (`[P]`) and file-activity-based (`[F]`) session detection

## Notes

Anything reviewers should know -- edge cases, decisions made, areas that need extra scrutiny.
