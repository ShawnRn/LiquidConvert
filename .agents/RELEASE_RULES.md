# Release Sequence Enforcement (LiquidConvert)

> [!CRITICAL]
> **NEVER push `appcast.xml` before the GitHub Release is fully published and the assets are uploaded.**

## Anti-Pattern (What went wrong)
- Committing `appcast.xml` along with code changes and pushing them simultaneously.
- Result: Sparkle points to a non-existent download link, causing update failures for users.

## Correct Workflow
1.  **Commit & Push Code**: Handle everything except `appcast.xml`.
2.  **Create Release**: Use `gh release create` or the web UI. Upload the DMG (`LiquidConvert_x.x.x.dmg`).
3.  **Generate Appcast**: Local run of `release.sh`. This script must sign the bytes users actually download from GitHub Release, not blindly trust the local DMG.
4.  **Final Push**: Commit and push `appcast.xml` ONLY after step 2 is confirmed.

## CI And Manual Hotfix Concurrency Rule
- Release workflows triggered by tag pushes run from a detached tag checkout. They must not directly commit and push `appcast.xml` from that detached HEAD to `main`.
- Before committing generated `appcast.xml`, CI must snapshot the generated file, fetch the latest default branch, switch to `origin/main`, then re-apply the snapshot and commit from there.
- If the generated `appcast.xml` SHA already matches `origin/main:appcast.xml`, the workflow must exit successfully without committing.
- If a push is rejected because `main` advanced during a manual hotfix, CI must fetch `origin/main` again and re-compare. If the remote appcast now matches the generated snapshot, treat it as success, not a release failure.
- Manual hotfixes that replace an existing tag/release should either let CI own the appcast push or perform the final appcast push locally, but not rely on both writers racing. When both paths run, the SHA comparison rule above is mandatory.

## Sparkle Verification Rule
- Before `appcast.xml` is committed, re-download every release asset from GitHub and use those remote bytes to compute `sparkle:edSignature` and `length`.
- If the downloaded asset hash differs from the local DMG hash, treat the remote asset as the source of truth for Sparkle metadata, otherwise the app will show “更新未正确签名”.
- If the latest published update is broken, replace the existing release/appcast in place instead of minting a new user-visible version just to bypass the bad metadata.
- When replacing a broken package under the same user-visible version, bump `CURRENT_PROJECT_VERSION` before building so installed apps can detect the replacement build.

## Managed Runtime Rule
- AI document extraction must be self-bootstrapping on a clean Mac. Do not rely on `/usr/bin/python3` because macOS may provide Python 3.9, while `markitdown==0.1.5` requires Python 3.10+.
- If no compatible Python exists, the app must download and cache the project-pinned standalone Python runtime, then build the MarkItDown venv from that runtime.

## Workspace And Entry-Point Rule
- Never publish from a dirty worktree by accident. Before building the release DMG, verify `git status --short` is clean or that only the intended release files are staged and committed.
- When shipping a new feature module, confirm the release commit contains both the implementation files and the product entry points: enum/tab registration, sidebar/menu entry, top-level routing, and any required dependency/license declarations.
- If the shipped app “does not have the feature” even though source files exist, first compare the release commit against local uncommitted diffs for those entry-point files before debugging packaging or Sparkle.
