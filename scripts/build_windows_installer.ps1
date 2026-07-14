[CmdletBinding()]
param(
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $repositoryRoot "LiquidConvert.Windows\LiquidConvert.Windows.csproj"
$publishDirectory = Join-Path $repositoryRoot "artifacts\windows\publish"
$dependencyDirectory = Join-Path $repositoryRoot "artifacts\windows\installer-deps"
$webViewRuntime = Join-Path $dependencyDirectory "MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
$installerDefinition = Join-Path $repositoryRoot "installer\LiquidConvert.iss"
$iscc = @(
    (Get-Command iscc.exe -ErrorAction SilentlyContinue).Source,
    "$env:ProgramFiles(x86)\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if (-not $iscc) {
    throw "Inno Setup 6 was not found. Install it from https://jrsoftware.org/isinfo.php and run this script again."
}

Remove-Item -LiteralPath $publishDirectory -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $dependencyDirectory -Force | Out-Null
if (-not (Test-Path $webViewRuntime)) {
    & curl.exe --fail --location --retry 3 --output $webViewRuntime "https://go.microsoft.com/fwlink/p/?LinkId=2124701"
    if ($LASTEXITCODE -ne 0) { throw "Unable to download the Microsoft WebView2 offline runtime." }
}
dotnet publish $project -c $Configuration -r win-x64 --self-contained true -o $publishDirectory
& $iscc "/DMyPublishDir=$publishDirectory" "/DMyWebViewRuntime=$webViewRuntime" $installerDefinition
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup failed with exit code $LASTEXITCODE."
}
