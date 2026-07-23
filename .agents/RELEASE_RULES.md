# Release Sequence Enforcement (LiquidConvert)

> [!CRITICAL]
> **NEVER push `appcast.xml` before the GitHub Release is fully published and the assets are uploaded.**

## Anti-Pattern (What went wrong)
- Committing `appcast.xml` along with code changes and pushing them simultaneously.
- Result: Sparkle points to a non-existent download link, causing update failures for users.

## Correct Workflow
1.  **Commit & Push Code**: Handle everything except `appcast.xml`.
2.  **Build Dual-Arch DMGs Locally**: Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build.sh release` and verify both `LiquidConvert_<version>_arm64.dmg` and `LiquidConvert_<version>_x86_64.dmg` exist.
3.  **Create Release**: Use `gh release create` or the web UI. Upload both architecture-specific DMGs.
4.  **Generate Appcast**: Local run of `release.sh`. This script must sign the bytes users actually download from GitHub Release, not blindly trust the local DMG. If the local machine does not have `SPARKLE_PRIVATE_KEY` or the Sparkle Keychain private key, do not fabricate or copy signatures; use the manual Release workflow after the script and workflow safety checks are committed.
5.  **Final Push**: Commit and push `appcast.xml` ONLY after step 3 is confirmed.

## Local Xcode Packaging Rule
- GitHub Actions automated Mac releases are deprecated. Routine Mac releases MUST be built and packaged using local Xcode via `./scripts/build.sh release`.
- `release.sh` runs locally to download published release assets, calculate byte lengths, generate Sparkle EdDSA signatures (`sparkle:edSignature`), and update `appcast.xml`.

## Sparkle Verification Rule
- Before `appcast.xml` is committed, re-download every release asset from GitHub and use those remote bytes to compute `sparkle:edSignature` and `length`.
- If the downloaded asset hash differs from the local DMG hash, treat the remote asset as the source of truth for Sparkle metadata, otherwise the app will show “更新未正确签名”.
- `release.sh` must hard-fail if `sign_update` exits non-zero, emits an empty signature, emits text containing `ERROR`, or `xmllint` rejects the generated XML. Never let a signing error string become `sparkle:edSignature`.
- If the latest published update is broken, replace the existing release/appcast in place instead of minting a new user-visible version just to bypass the bad metadata.
- When replacing a broken package under the same user-visible version, bump `CURRENT_PROJECT_VERSION` before building so installed apps can detect the replacement build.

## Managed Runtime Rule
- AI document extraction must be self-bootstrapping on a clean Mac. Do not rely on `/usr/bin/python3` because macOS may provide Python 3.9, while `markitdown==0.1.5` requires Python 3.10+.
- If no compatible Python exists, the app must download and cache the project-pinned standalone Python runtime, then build the MarkItDown venv from that runtime.
- Dragged image files in AI document extraction are not MarkItDown inputs. They must go straight through Vision OCR and return OCR text as the Markdown result.
- Embedded or referenced images in Word / PPT / Excel / PDF / HTML / web extraction should have OCR inserted next to the corresponding Markdown image reference. Do not append all OCR text to the end unless there is no reliable image position.
- OCR output should merge fragmented visual lines into readable paragraphs while preserving clear list/paragraph boundaries.

## Workspace And Entry-Point Rule
- Never publish from a dirty worktree by accident. Before building the release DMG, verify `git status --short` is clean or that only the intended release files are staged and committed.
- When shipping a new feature module, confirm the release commit contains both the implementation files and the product entry points: enum/tab registration, sidebar/menu entry, top-level routing, and any required dependency/license declarations.
- If the shipped app “does not have the feature” even though source files exist, first compare the release commit against local uncommitted diffs for those entry-point files before debugging packaging or Sparkle.
