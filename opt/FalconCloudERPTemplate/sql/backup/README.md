# Backup folder

Place `FalconTemplate.bak` here. This file is consumed by `run.sh` when it
materializes a new client environment on the server.

Steps to add or update the template backup:

1. Copy your `FalconTemplate.bak` into this folder.
2. Commit and push:
   ```
   git add opt/FalconTemplate/sql/backup/FalconTemplate.bak
   git commit -m "Update FalconTemplate backup"
   git push origin sqlexpress25
   ```

Size limits:

- GitHub rejects any single file over 100 MB unless tracked with Git LFS.
- If your backup is larger than 100 MB, run `git lfs install` and
  `git lfs track "*.bak"` before committing.
