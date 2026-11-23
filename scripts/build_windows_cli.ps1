param([string]$Python = "python.exe")

$ErrorActionPreference = "Stop"
$project = Split-Path $PSScriptRoot -Parent
$source = Join-Path $project "LiquidConvert.Cli"
$artifacts = Join-Path $project "artifacts/windows-cli"

$pythonHome = & $Python -c "import sys; assert sys.platform == 'win32' and sys.version_info[:2] == (3, 13); print(sys.base_prefix)"
if ($LASTEXITCODE -ne 0) { throw "A Windows Python 3.13 interpreter is required." }
$dll = [IO.BinaryReader]::new([IO.File]::OpenRead((Join-Path $pythonHome "python313.dll")))
try {
    $dll.BaseStream.Position = 0x3c
    $dll.BaseStream.Position = $dll.ReadUInt32() + 4
    $machine = $dll.ReadUInt16()
} finally {
    $dll.Dispose()
}
$arch = switch ($machine) {
    0xaa64 { "arm64" }
    0x8664 { "x64" }
    default { throw "Unsupported Python architecture: $machine" }
}

$build = Join-Path $artifacts "package-$arch"
$dist = Join-Path $build "dist"
$venv = Join-Path $build "venv"
New-Item -ItemType Directory -Path $build -Force | Out-Null
& $Python -m venv $venv
if ($LASTEXITCODE -ne 0) { throw "Unable to create the build environment." }
$buildPython = Join-Path $venv "Scripts/python.exe"
& $buildPython -m pip install --only-binary=:all: -r (Join-Path $source "requirements-build.txt")
if ($LASTEXITCODE -ne 0) { throw "Unable to install the build requirements." }

$pyInstallerArgs = @(
    "--noconfirm", "--clean", "--name", "liquidconvert", "--distpath", $dist, "--workpath", (Join-Path $build "work"),
    "--specpath", $build, "--collect-data", "magika", "--collect-data", "pdfminer",
    "--recursive-copy-metadata", "markitdown", (Join-Path $source "liquidconvert.py")
)
$env:PYINSTALLER_CONFIG_DIR = Join-Path $build "cache"
& $buildPython -m PyInstaller @pyInstallerArgs
if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed." }

$package = Join-Path $dist "liquidconvert"
$exe = Join-Path $package "liquidconvert.exe"
& $buildPython (Join-Path $source "smoke_test.py") $exe
if ($LASTEXITCODE -ne 0) { throw "The packaged CLI failed its smoke tests." }
$versionLine = & $exe --version
if ($LASTEXITCODE -ne 0 -or $versionLine -notmatch '^LiquidConvert CLI (\d+\.\d+\.\d+)$') {
    throw "Unable to read the CLI version."
}
$cliVersion = $Matches[1]
Copy-Item -LiteralPath (Join-Path $project "LICENSE") -Destination $package
Copy-Item -LiteralPath (Join-Path $source "README.md") -Destination $package
& $buildPython (Join-Path $source "copy_notices.py") $package
if ($LASTEXITCODE -ne 0) { throw "Unable to collect third-party notices." }

$archive = Join-Path $artifacts "LiquidConvert-CLI-$cliVersion-windows-$arch.zip"
Push-Location -LiteralPath $package
try {
    & $buildPython -m zipfile -c $archive liquidconvert.exe _internal LICENSE README.md third-party-notices
    if ($LASTEXITCODE -ne 0) { throw "Unable to create the release archive." }
} finally {
    Pop-Location
}
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
"$hash  $(Split-Path $archive -Leaf)" | Set-Content -LiteralPath "$archive.sha256" -Encoding Ascii
Write-Output $archive
