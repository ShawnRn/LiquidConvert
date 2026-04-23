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

## Sparkle Verification Rule
- Before `appcast.xml` is committed, re-download every release asset from GitHub and use those remote bytes to compute `sparkle:edSignature` and `length`.
- If the downloaded asset hash differs from the local DMG hash, treat the remote asset as the source of truth for Sparkle metadata, otherwise the app will show “更新未正确签名”.
- If the latest published update is broken, replace the existing release/appcast in place instead of minting a new user-visible version just to bypass the bad metadata.
