param(
    [string]$Python = "python",
    [string]$Version = "0.8.0-dev1",
    [string]$Destination = "",
    [string]$LicenseMaterials = "",
    [string]$LicenseReview = "",
    [switch]$VerifyRuntimeOnly,
    [switch]$PrepareForReview,
    [switch]$FinalizeReviewedBundle
)
$ErrorActionPreference = "Stop"
if ($env:OS -ne "Windows_NT") { throw "Windows package must be built on Windows; macOS packaging is not proof." }
if ($Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw "Use a bounded filename-safe candidate version." }
if ($PrepareForReview -and $FinalizeReviewedBundle) { throw "Choose one packaging phase." }
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
if (-not $Destination) { $Destination = Join-Path $RepoRoot ".build/windows-packages/$Version" }
if (-not $VerifyRuntimeOnly -and -not $PrepareForReview -and -not $LicenseReview) { throw "ZIP creation requires an exact reviewed license record. Use PrepareForReview for a private review candidate." }

function Assert-PinnedMediaRuntime {
    $RuntimeCheck = @'
import pypdf, pillow_heif, _pillow_heif
if pypdf.__version__ != '6.19.0' or pillow_heif.__version__ != '1.8.0':
    raise SystemExit('Required exact pypdf 6.19.0 / pillow-heif 1.8.0 unavailable')
info = pillow_heif.libheif_info()
if not info.get('libheif') or not info.get('HEIF'):
    raise SystemExit('HEIF encoder/libheif unavailable')
print('pypdf', pypdf.__version__, 'pillow-heif', pillow_heif.__version__)
print('Actual libheif/codec inventory (not redistribution approval):', info)
'@
    & $Python -c "import subprocess,sys; subprocess.run([sys.executable,'-c',sys.argv[1]],check=True,timeout=60)" $RuntimeCheck
    if ($LASTEXITCODE -ne 0) { throw "Required PDF/HEIF backend missing or different from the reviewed pins." }
    $RequiredTests = @'
import sys, unittest
sys.path.insert(0, 'Tests/WindowsAppTests')
suite = unittest.TestSuite()
for name in ('test_pdf_legacy_geometry.ActualPDFMetadataTests', 'test_heif_codec.ActualHeifCodecTests'):
    required = unittest.defaultTestLoader.loadTestsFromName(name)
    if not required.countTestCases():
        raise SystemExit('Missing mandatory actual backend tests: ' + name)
    suite.addTests(required)
result = unittest.TextTestRunner(verbosity=2).run(suite)
if not result.testsRun or result.skipped or not result.wasSuccessful():
    raise SystemExit('Required actual PDF/HEIF tests failed or skipped; not a verified candidate')
'@
    & $Python -c "import subprocess,sys; subprocess.run([sys.executable,'-c',sys.argv[1]],check=True,timeout=300)" $RequiredTests
    if ($LASTEXITCODE -ne 0) { throw "Mandatory actual PDF/HEIF tests failed, skipped or timed out." }
}

if ($VerifyRuntimeOnly) {
    if ($PrepareForReview -or $FinalizeReviewedBundle) { throw "Runtime verification cannot be combined with a packaging phase." }
    $PriorQtPlatform = [Environment]::GetEnvironmentVariable('QT_QPA_PLATFORM', 'Process')
    Push-Location $RepoRoot
    try {
        [Environment]::SetEnvironmentVariable('QT_QPA_PLATFORM', 'offscreen', 'Process')
        Assert-PinnedMediaRuntime
    } finally {
        [Environment]::SetEnvironmentVariable('QT_QPA_PLATFORM', $PriorQtPlatform, 'Process')
        Pop-Location
    }
    Write-Output "Pinned actual PDF/HEIF backend checks completed. No package or installation created."
    return
}

function Require-RegularFile([string]$Path, [switch]$AllowEmpty) {
    $Item = Get-Item -LiteralPath $Path -Force
    if ($Item.PSIsContainer -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (-not $AllowEmpty -and $Item.Length -eq 0)) {
        throw "Required nonempty regular file missing: $Path"
    }
}

function Get-RegularBundleFiles([string]$Root) {
    $RootItem = Get-Item -LiteralPath $Root -Force
    if (-not $RootItem.PSIsContainer -or ($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Bundle/material root must be a regular directory." }
    $Ancestor = $RootItem.Parent
    while ($null -ne $Ancestor) {
        if ($Ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse directory in bundle/material path: $($Ancestor.FullName)" }
        $Ancestor = $Ancestor.Parent
    }
    $Pending = [System.Collections.Generic.Stack[string]]::new()
    $Files = [System.Collections.Generic.List[object]]::new()
    $Pending.Push($Root)
    while ($Pending.Count) {
        # Include hidden entries and inspect each directory before descending.
        foreach ($Item in (Get-ChildItem -LiteralPath ($Pending.Pop()) -Force)) {
            if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse entry in bundle/materials: $($Item.FullName)" }
            if ($Item.PSIsContainer) { $Pending.Push($Item.FullName) }
            else { $Files.Add($Item) }
        }
    }
    return $Files.ToArray()
}

function Assert-LicenseMaterials([string]$Directory) {
    $null = Get-RegularBundleFiles $Directory
    Require-RegularFile (Join-Path $Directory "NOTICE.txt")
    Require-RegularFile (Join-Path $Directory "dependencies.json")
    $Inventory = Get-Content -LiteralPath (Join-Path $Directory "dependencies.json") -Raw | ConvertFrom-Json
    if ($null -eq $Inventory.dependencies -or @($Inventory.dependencies).Count -eq 0) { throw "Dependency inventory is empty." }
    $Ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($Dependency in $Inventory.dependencies) {
        if (-not $Dependency.id -or -not $Dependency.version -or -not $Dependency.license -or -not $Dependency.redistribution_review) {
            throw "Every dependency needs id/version/license/redistribution_review based on its actual bundled binary."
        }
        if (-not $Ids.Add([string]$Dependency.id)) { throw "Duplicate dependency ID." }
        foreach ($Field in @("license_files", "evidence_files")) {
            $References = $Dependency.$Field
            if ($null -eq $References -or @($References).Count -eq 0) { throw "Missing $Field for $($Dependency.id)." }
            foreach ($Reference in $References) {
                $Relative = ([string]$Reference).Replace('\', '/')
                if (-not $Relative -or $Relative.Contains(':') -or $Relative.StartsWith('/') -or
                    ($Relative.Split('/') | Where-Object { $_ -eq '..' -or $_ -eq '.' -or $_ -eq '' })) {
                    throw "Unsafe license evidence path: $Relative"
                }
                Require-RegularFile (Join-Path $Directory $Relative)
            }
        }
    }
    foreach ($Id in @("python", "pyside6", "qt", "pdfium", "pyav", "ffmpeg", "opencv", "pillow", "numpy", "pyinstaller", "pypdf", "pillow-heif", "libheif", "heif-codecs")) {
        if (-not $Ids.Contains($Id)) { throw "Missing actual bundled dependency evidence: $Id" }
    }
    foreach ($Pin in (@{ "pypdf" = "6.19.0"; "pillow-heif" = "1.8.0" }).GetEnumerator()) {
        $Actual = @($Inventory.dependencies | Where-Object { $_.id -ieq $Pin.Key })[0]
        if ($Actual.version -cne $Pin.Value) { throw "Dependency evidence does not match the required runtime pin: $($Pin.Key)" }
    }
    # Evidence presence is not legal compatibility. Actual FFmpeg DLL
    # configuration/GPL components require a human redistribution review.
}

function Assert-ReviewedBundle([string]$BundlePath, [string]$ManifestPath, [string]$ReviewPath) {
    $AllFiles = @(Get-RegularBundleFiles $BundlePath)
    Require-RegularFile (Join-Path $BundlePath "BlurAction.exe")
    Require-RegularFile (Join-Path $BundlePath "LICENSE.txt")
    Assert-LicenseMaterials (Join-Path $BundlePath "licenses")
    Require-RegularFile $ManifestPath
    Require-RegularFile $ReviewPath
    $Review = Get-Content -LiteralPath $ReviewPath -Raw | ConvertFrom-Json
    $ManifestHash = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Review.status -ne "reviewed" -or $Review.version -ne $Version -or $Review.bundle_manifest_sha256 -cne $ManifestHash -or
        -not $Review.reviewed_by -or -not $Review.reviewed_at -or $null -eq $Review.dependencies -or @($Review.dependencies).Count -eq 0) {
        throw "A reviewed record tied to this exact version and manifest SHA-256 is required. Pending/example records are not approval."
    }
    $Entries = @(Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json)
    if ($Entries.Count -eq 0) { throw "The bundle manifest is empty." }
    $Recorded = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($Entry in $Entries) {
        $Relative = ([string]$Entry.path).Replace('\', '/')
        if (-not $Relative.StartsWith('BlurAction/', [StringComparison]::OrdinalIgnoreCase)) { throw "Unexpected manifest root." }
        $Relative = $Relative.Substring('BlurAction/'.Length)
        if (-not $Relative -or $Relative.Contains(':') -or
            ($Relative.Split('/') | Where-Object { $_ -eq '..' -or $_ -eq '.' -or $_ -eq '' })) { throw "Unsafe manifest path." }
        if (-not $Recorded.Add($Relative)) { throw "Duplicate manifest path." }
        $File = Join-Path $BundlePath $Relative
        Require-RegularFile $File -AllowEmpty
        if ((Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$Entry.sha256) {
            throw "Reviewed bundle changed: $Relative"
        }
    }
    $Prefix = $BundlePath.TrimEnd('\') + '\'
    foreach ($File in $AllFiles) {
        $Relative = $File.FullName.Substring($Prefix.Length).Replace('\', '/')
        if (-not $Recorded.Contains($Relative)) { throw "Unreviewed bundle file: $Relative" }
    }
    return @{ manifestHash = $ManifestHash; reviewHash = (Get-FileHash -LiteralPath $ReviewPath -Algorithm SHA256).Hash.ToLowerInvariant() }
}

if ($FinalizeReviewedBundle) {
    $Destination = (Resolve-Path -LiteralPath $Destination).Path
} else {
    if (Test-Path -LiteralPath $Destination) { throw "Destination exists. Choose a new candidate directory." }
    if (-not $LicenseMaterials) { throw "Supply real dependency notices and evidence before preparing a bundle; this script does not invent or download them." }
    $MaterialsPath = (Resolve-Path -LiteralPath $LicenseMaterials).Path
    Assert-LicenseMaterials $MaterialsPath
    $DestinationFullPath = [IO.Path]::GetFullPath($Destination)
    if ($DestinationFullPath.Equals($MaterialsPath, [StringComparison]::OrdinalIgnoreCase) -or
        $DestinationFullPath.StartsWith($MaterialsPath.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Candidate output must be outside source license materials."
    }
    & $Python -c "import PySide6, PIL, numpy, av, cv2, PyInstaller; assert hasattr(cv2,'TrackerCSRT_create')"
    if ($LASTEXITCODE -ne 0) { throw "Required dependencies are missing. Install only in an approved isolated environment." }
    New-Item -ItemType Directory -Path $Destination | Out-Null
    $Destination = (Resolve-Path -LiteralPath $Destination).Path
    $BuildWork = Join-Path $Destination "work"
    $Dist = Join-Path $Destination "dist"
    $PriorQtPlatform = [Environment]::GetEnvironmentVariable('QT_QPA_PLATFORM', 'Process')
    Push-Location $RepoRoot
    try {
        & $Python -c "import subprocess,sys; subprocess.run([sys.executable,'-m','unittest','discover','-s','Tests/PortableProjectTests','-v'],check=True,timeout=120)"
        if ($LASTEXITCODE -ne 0) { throw "Portable project tests failed or timed out." }
        [Environment]::SetEnvironmentVariable('QT_QPA_PLATFORM', 'offscreen', 'Process')
        Assert-PinnedMediaRuntime
        & $Python -c "import subprocess,sys; subprocess.run([sys.executable,'-m','unittest','discover','-s','Tests/WindowsAppTests','-v'],check=True,timeout=900)"
        if ($LASTEXITCODE -ne 0) { throw "Windows engine/controller tests failed or timed out." }
        # Official helpers collect package resources and delvewheel's sibling
        # .libs DLL directory. No dedicated pillow-heif hook was assumed present.
        # https://pyinstaller.org/en/stable/hooks.html#PyInstaller.utils.hooks.collect_delvewheel_libs_directory
        $Hooks = Join-Path $BuildWork "hooks"
        New-Item -ItemType Directory -Path $Hooks -Force | Out-Null
        @'
from PyInstaller.utils.hooks import collect_all, collect_delvewheel_libs_directory
datas, binaries, hiddenimports = collect_all('pillow_heif')
hiddenimports += ['_pillow_heif']
datas, binaries = collect_delvewheel_libs_directory('pillow_heif', datas=datas, binaries=binaries)
'@ | Set-Content (Join-Path $Hooks "hook-pillow_heif.py") -Encoding utf8
        & $Python -m PyInstaller --noconfirm --clean --windowed --onedir --name BlurAction `
            --paths $RepoRoot --distpath $Dist --workpath $BuildWork --specpath $BuildWork `
            --additional-hooks-dir $Hooks --collect-all PySide6.QtPdf --collect-all av --collect-all cv2 `
            --collect-all pypdf --hidden-import pillow_heif --hidden-import _pillow_heif `
            (Join-Path $PSScriptRoot "launcher.py")
        if ($LASTEXITCODE -ne 0) { throw "Packaging failed." }
        Copy-Item -LiteralPath (Join-Path $RepoRoot "LICENSE") -Destination (Join-Path $Dist "BlurAction/LICENSE.txt")
        Copy-Item -LiteralPath $MaterialsPath -Destination (Join-Path $Dist "BlurAction/licenses") -Recurse -Force
        Assert-LicenseMaterials (Join-Path $Dist "BlurAction/licenses")
        $Manifest = @(Get-RegularBundleFiles (Join-Path $Dist "BlurAction") | ForEach-Object {
            [ordered]@{ path = $_.FullName.Substring($Dist.Length + 1); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
        })
        ConvertTo-Json -InputObject $Manifest -Depth 6 | Set-Content (Join-Path $Destination "bundle-manifest.json") -Encoding utf8
    } finally {
        [Environment]::SetEnvironmentVariable('QT_QPA_PLATFORM', $PriorQtPlatform, 'Process')
        Pop-Location
    }
}

$BundlePath = Join-Path $Destination "dist/BlurAction"
$ManifestPath = Join-Path $Destination "bundle-manifest.json"
if ($PrepareForReview) {
    Write-Output "Private onedir candidate and exact manifest prepared for review. No ZIP, installer, installation or publication."
    Write-Output "Manifest: $ManifestPath"
    Write-Output "Review these actual DLLs; PyAV's wrapper license does not certify FFmpeg GPL configuration or patent rights."
    return
}
$ReviewPath = (Resolve-Path -LiteralPath $LicenseReview).Path
$Before = Assert-ReviewedBundle $BundlePath $ManifestPath $ReviewPath
$Zip = Join-Path $Destination "BlurAction-$Version-windows-x64-portable.zip"
if (Test-Path -LiteralPath $Zip) { throw "ZIP exists. Existing results are not overwritten." }
# ZipFile includes hidden files that Compress-Archive can omit. It refuses an
# existing destination and includes the BlurAction folder as the archive root.
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($BundlePath, $Zip, [IO.Compression.CompressionLevel]::Optimal, $true)
try {
    # Do not retain a ZIP if its input changed during archiving.
    $After = Assert-ReviewedBundle $BundlePath $ManifestPath $ReviewPath
    if ($After.manifestHash -cne $Before.manifestHash -or $After.reviewHash -cne $Before.reviewHash) {
        throw "Reviewed manifest/review bytes changed during archiving."
    }
} catch {
    Remove-Item -LiteralPath $Zip
    throw
}
Get-FileHash -LiteralPath $Zip -Algorithm SHA256 | Format-List
Write-Output "Reviewed portable ZIP prepared only. Installer and actual Windows user acceptance remain required."
