# LiquidConvert CLI for Windows

The portable Windows build extracts Markdown from local documents and publicly accessible web pages. Download the ZIP for your architecture from [GitHub Releases](https://github.com/ShawnRn/LiquidConvert/releases), and keep `liquidconvert.exe` and the adjacent `_internal` directory together. The package includes Python and its runtime dependencies.

```powershell
.\liquidconvert.exe 'C:\新闻稿\发布稿件.docx' --output '.\发布稿件.md'
.\liquidconvert.exe 'https://example.com/article' --no-ocr
.\liquidconvert.exe --batch '.\a.pdf' '.\b.pptx' --output-dir '.\markdown' --json
```

Supported inputs include DOCX, text-layer PDF, PPTX, XLSX, XLS, CSV, JSON, XML, UTF-8 and BOM-marked UTF-16 text/Markdown, HTML, and public HTTP(S) pages. Web extraction reads the HTML response and supports the WeChat article container when the server returns it. Legacy .doc, OCR, JavaScript rendering, and signed-in browser sessions are outside this CLI's feature set.

A single source prints UTF-8 Markdown unless `--output` is set. The macOS alias `--extract-markdown` is accepted as the first argument. `--no-ocr` is accepted for compatibility. In batch mode, failures are reported per source and the other inputs continue. Exit codes are 0 for success, 1 for an extraction or output error, and 2 for invalid command usage. Both single-source Markdown and batch JSON use UTF-8.

To use the executable with the morning-news pipeline, set `LIQUIDCONVERT_BIN` to the absolute path of `liquidconvert.exe` in the process that runs the pipeline.

## Build

Use a Windows Python 3.13 interpreter for the target architecture. From the repository root:

```powershell
.\scripts\build_windows_cli.ps1 -Python python.exe
```

The script runs packaged CLI smoke tests and writes a release ZIP and SHA-256 file to `artifacts/windows-cli`.
