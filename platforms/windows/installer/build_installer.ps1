param(
    [Parameter(Mandatory=$true)][string]$Bundle,
    [Parameter(Mandatory=$true)][string]$BundleManifest,
    [Parameter(Mandatory=$true)][string]$LicenseReview,
    [Parameter(Mandatory=$true)][string]$Version,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$Compiler = "",
    [string]$Python = "python",
    [string]$InputReceipt = "",
    [string]$ReceiptArtifacts = ""
)
$ErrorActionPreference = "Stop"
if ($env:OS -ne "Windows_NT") { throw "Compile the Windows installer on Windows; macOS is not installer evidence." }
# Resolve an explicit executable or a PATH command in the caller's directory.
# Keep the exact application after Push-Location; aliases/functions/scripts are
# not Python interpreters. This only resolves a file and never installs tools.
if ([string]::IsNullOrWhiteSpace($Python)) { throw "Python executable is required." }
if ([IO.Path]::IsPathRooted($Python) -or $Python.Contains('\') -or $Python.Contains('/')) {
    $PythonItem = Get-Item -LiteralPath $Python -Force
} else {
    if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Python)) {
        throw "Use an exact Python application name or literal executable path."
    }
    $PythonCommand = @(Get-Command -Name $Python -CommandType Application -ErrorAction Stop)[0]
    $PythonItem = Get-Item -LiteralPath $PythonCommand.Source -Force
}
if ($PythonItem.PSIsContainer -or $PythonItem.Extension -ine '.exe') {
    throw "Python must resolve to an actual executable application."
}
$Python = $PythonItem.FullName

if (-not $InputReceipt -or -not $ReceiptArtifacts) { throw "Installer requires an exact external input receipt and actual acquisition artifacts." }
# Fix the caller's relative input paths once. The helper's regular/reparse
# guards remain mandatory; this creates no copied receipt or acquisition files.
$InputReceipt = (Resolve-Path -LiteralPath $InputReceipt).Path
$ReceiptArtifacts = (Resolve-Path -LiteralPath $ReceiptArtifacts).Path
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../../..")).Path
if ($Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw "Use a bounded filename-safe candidate version." }
$BundlePath = (Resolve-Path -LiteralPath $Bundle).Path
$ManifestPath = (Resolve-Path -LiteralPath $BundleManifest).Path
$ReviewPath = (Resolve-Path -LiteralPath $LicenseReview).Path
if (-not (Test-Path -LiteralPath (Join-Path $BundlePath "BlurAction.exe") -PathType Leaf)) { throw "Windows executable missing." }
if (Test-Path -LiteralPath $OutputDirectory) { throw "Output exists. Choose a new candidate directory; no results are overwritten." }

function Get-RegularBundleFiles([string]$Root) {
    $RootItem = Get-Item -LiteralPath $Root -Force
    if (-not $RootItem.PSIsContainer -or ($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Bundle root must be a regular directory." }
    $Ancestor = $RootItem.Parent
    while ($null -ne $Ancestor) {
        if ($Ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse directory in bundle path: $($Ancestor.FullName)" }
        $Ancestor = $Ancestor.Parent
    }
    $Pending = [System.Collections.Generic.Stack[string]]::new()
    $Files = [System.Collections.Generic.List[object]]::new()
    $Pending.Push($Root)
    while ($Pending.Count) {
        # Inspect before descending; never traverse a junction/symlink directory.
        foreach ($Item in Get-ChildItem -LiteralPath ($Pending.Pop()) -Force) {
            if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse entry in bundle: $($Item.FullName)" }
            if ($Item.PSIsContainer) { $Pending.Push($Item.FullName) }
            else { $Files.Add($Item) }
        }
    }
    return $Files.ToArray()
}

function Assert-ReviewedInputs {
$AllFiles = @(Get-RegularBundleFiles $BundlePath)
$ReviewItem = Get-Item -LiteralPath $ReviewPath -Force
$ManifestItem = Get-Item -LiteralPath $ManifestPath -Force
if ($ReviewItem.PSIsContainer -or $ManifestItem.PSIsContainer -or
    ($ReviewItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
    ($ManifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Review and manifest must be regular files." }
$Review = Get-Content -LiteralPath $ReviewPath -Raw | ConvertFrom-Json
$ManifestHash = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($Review.status -ne "reviewed" -or $Review.version -ne $Version -or $Review.bundle_manifest_sha256 -cne $ManifestHash) {
    throw "A reviewed license record tied to this exact version and bundle-manifest SHA-256 is required. The example is not approval."
}
if (-not $Review.reviewed_by -or -not $Review.reviewed_at -or $null -eq $Review.dependencies -or @($Review.dependencies).Count -eq 0) {
    throw "The license review must identify its reviewer, date and dependency findings."
}
foreach ($Required in @("LICENSE.txt", "licenses/NOTICE.txt", "licenses/dependencies.json")) {
    $RequiredPath = Join-Path $BundlePath $Required
    if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf) -or (Get-Item -LiteralPath $RequiredPath -Force).Length -eq 0) {
        throw "Required license material missing: $Required"
    }
}

$Inventory = Get-Content -LiteralPath (Join-Path $BundlePath "licenses/dependencies.json") -Raw | ConvertFrom-Json
if ($null -eq $Inventory.dependencies -or @($Inventory.dependencies).Count -eq 0) { throw "Actual dependency inventory missing." }
$Ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($Dependency in $Inventory.dependencies) {
    if (-not $Dependency.id -or -not $Dependency.version -or -not $Dependency.license -or -not $Dependency.redistribution_review) {
        throw "Incomplete actual dependency evidence."
    }
    if (-not $Ids.Add([string]$Dependency.id)) { throw "Duplicate dependency ID." }
    foreach ($Field in @("license_files", "evidence_files")) {
        $References = $Dependency.$Field
        if ($null -eq $References -or @($References).Count -eq 0) { throw "Missing $Field for $($Dependency.id)." }
        foreach ($Reference in $References) {
            $Relative = ([string]$Reference).Replace('\', '/')
            if (-not $Relative -or $Relative.Contains(':') -or $Relative.StartsWith('/') -or
                ($Relative.Split('/') | Where-Object { $_ -eq '..' -or $_ -eq '.' -or $_ -eq '' })) { throw "Unsafe dependency reference." }
            $Item = Get-Item -LiteralPath (Join-Path (Join-Path $BundlePath "licenses") $Relative) -Force
            if ($Item.PSIsContainer -or $Item.Length -eq 0 -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Missing actual license/evidence file." }
        }
    }
}
foreach ($Id in @("python", "pyside6", "qt", "pdfium", "pyav", "ffmpeg", "opencv", "pillow", "numpy", "pyinstaller", "pypdf", "pillow-heif", "libheif", "heif-codecs")) {
    if (-not $Ids.Contains($Id)) { throw "Missing actual bundled dependency evidence: $Id" }
}
foreach ($Pin in (@{ "pypdf" = "6.19.0"; "pillow-heif" = "1.8.0"; "pillow" = "12.3.0" }).GetEnumerator()) {
    $Actual = @($Inventory.dependencies | Where-Object { $_.id -ieq $Pin.Key })[0]
    if ($Actual.version -cne $Pin.Value) { throw "Dependency evidence does not match the required runtime pin: $($Pin.Key)" }
}

# Recheck all reviewed bytes and refuse hidden additions or path traversal.
$Entries = @(Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json)
if ($Entries.Count -eq 0) { throw "The bundle manifest is empty." }
$Recorded = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($Entry in $Entries) {
    $Relative = ([string]$Entry.path).Replace('\', '/')
    if (-not $Relative.StartsWith('BlurAction/', [StringComparison]::OrdinalIgnoreCase)) { throw "Unexpected manifest root: $Relative" }
    $Relative = $Relative.Substring('BlurAction/'.Length)
    if (-not $Relative -or ($Relative.Split('/') | Where-Object { $_ -eq '..' -or $_ -eq '.' -or $_ -eq '' }) -or $Relative.Contains(':')) {
        throw "Unsafe manifest path: $Relative"
    }
    if (-not $Recorded.Add($Relative)) { throw "Duplicate manifest path: $Relative" }
    $File = Join-Path $BundlePath $Relative
    $Item = Get-Item -LiteralPath $File -Force
    if ($Item.PSIsContainer -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Only regular bundle files are accepted: $Relative" }
    $Actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Actual -cne [string]$Entry.sha256) { throw "Reviewed bundle changed: $Relative" }
}
$Prefix = $BundlePath.TrimEnd('\') + '\'
foreach ($File in $AllFiles) {
    $Relative = $File.FullName.Substring($Prefix.Length).Replace('\', '/')
    if (-not $Recorded.Contains($Relative)) { throw "Unreviewed bundle file: $Relative" }
}
$Arguments = @("--mode", "finalize", "--receipt", $InputReceipt, "--artifacts-root", $ReceiptArtifacts,
    "--materials-root", (Join-Path $BundlePath "licenses"), "--source-root", $RepoRoot,
    "--bundle", $BundlePath, "--bundle-manifest", $ManifestPath,
    "--license-review", $ReviewPath, "--version", $Version)
$Json = & $Python -c "import subprocess,sys; subprocess.run([sys.executable,sys.argv[1],*sys.argv[2:]],check=True,timeout=300)" `
    (Join-Path $RepoRoot "shared/windows_package_receipt.py") @Arguments
if ($LASTEXITCODE -ne 0) { throw "Installer input receipt did not positively complete. No package input/source guess is accepted." }
$Receipt = ($Json -join "`n") | ConvertFrom-Json
$ReceiptHash = (Get-FileHash -LiteralPath $InputReceipt -Algorithm SHA256).Hash.ToLowerInvariant()
if (-not $Receipt.ok -or $Receipt.host -cne "win32" -or $Receipt.receipt_sha256 -cne $ReceiptHash -or
    $Review.input_receipt_sha256 -cne $ReceiptHash -or $Receipt.license_review_sha256 -cne
    (Get-FileHash -LiteralPath $ReviewPath -Algorithm SHA256).Hash.ToLowerInvariant()) { throw "Reviewed receipt bytes changed or do not match the license record." }
return @{ manifestHash = $ManifestHash; reviewHash = (Get-FileHash -LiteralPath $ReviewPath -Algorithm SHA256).Hash.ToLowerInvariant(); receiptHash = $ReceiptHash }
}

$Before = Assert-ReviewedInputs
$ManifestHash = $Before.manifestHash

if (-not $Compiler) {
    $Located = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($Located) { $Compiler = $Located.Source }
    else { $Compiler = Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6/ISCC.exe" }
}
if (-not (Test-Path -LiteralPath $Compiler -PathType Leaf)) {
    throw "Inno Setup compiler not present. Prepare its exact official installer/version and request tool-install approval; this script does not install it."
}
$OutputFullPath = [IO.Path]::GetFullPath($OutputDirectory)
if ($OutputFullPath.Equals($BundlePath, [StringComparison]::OrdinalIgnoreCase) -or
    $OutputFullPath.StartsWith($BundlePath.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Installer output must be outside the reviewed bundle."
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$OutputPath = (Resolve-Path -LiteralPath $OutputDirectory).Path
& $Compiler "/DSourceDir=$BundlePath" "/DAppVersion=$Version" "/DBundleManifestFile=$ManifestPath" "/DLicenseReviewFile=$ReviewPath" "/O$OutputPath" (Join-Path $PSScriptRoot "BlurAction.iss")
if ($LASTEXITCODE -ne 0) { throw "Installer compilation failed. Preserve diagnostic output and repair the source before retrying." }
$Installer = Join-Path $OutputPath "BlurAction-$Version-windows-x64-setup.exe"
if (-not (Test-Path -LiteralPath $Installer -PathType Leaf)) { throw "Compiler returned without the expected installer." }
# Compiler inputs must still be the exact reviewed bytes, including hidden files
# and directory entries. A failed recheck never produces an accepted report.
$After = Assert-ReviewedInputs
if ($After.manifestHash -cne $Before.manifestHash -or $After.reviewHash -cne $Before.reviewHash -or $After.receiptHash -cne $Before.receiptHash) { throw "Reviewed inputs changed during compilation; installer remains unverified." }
$Record = [ordered]@{
    state = "installer_compiled_not_installed_or_user_accepted"
    version = $Version
    bundle_manifest_sha256 = $ManifestHash
    input_receipt_sha256 = $Before.receiptHash
    installer = [IO.Path]::GetFileName($Installer)
    installer_sha256 = (Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash.ToLowerInvariant()
    signature_status = (Get-AuthenticodeSignature -LiteralPath $Installer).Status.ToString()
    compiler = [IO.Path]::GetFileName($Compiler)
    compiled_at_utc = [DateTime]::UtcNow.ToString('o')
}
$Record | ConvertTo-Json | Set-Content (Join-Path $OutputPath "installer-report.json") -Encoding utf8
$Record | ConvertTo-Json
Write-Output "Installer prepared only. Clean Windows installation/manual acceptance and publication approval remain separate."
