param(
    [string]$Python = "python",
    [string]$Version = "0.9.1.windows.local4",
    [string]$Destination = "",
    [string]$LicenseMaterials = "",
    [string]$LicenseReview = "",
    [string]$InputReceipt = "",
    [string]$ReceiptArtifacts = "",
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
if (-not $VerifyRuntimeOnly -and -not $PrepareForReview -and (-not $InputReceipt -or -not $ReceiptArtifacts)) {
    throw "Final ZIP requires an exact input receipt and its actual acquisition artifacts. PrepareForReview still permits a private candidate without them."
}

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

function Assert-PackageReceipt([string]$Mode, [string]$Materials, [string]$BundlePath = "", [string]$ManifestPath = "") {
    if (-not $InputReceipt -or -not $ReceiptArtifacts) { throw "Supply both InputReceipt and ReceiptArtifacts." }
    $Arguments = @("--mode", $Mode, "--receipt", $InputReceipt, "--artifacts-root", $ReceiptArtifacts,
        "--materials-root", $Materials, "--source-root", $RepoRoot)
    if ($Mode -eq "finalize") { $Arguments += @("--bundle", $BundlePath, "--bundle-manifest", $ManifestPath,
        "--license-review", $LicenseReview, "--version", $Version) }
    # Stdlib/file metadata only; the helper never imports codecs or grants a
    # license verdict. A supplied invalid receipt fails before native imports.
    $Json = & $Python -c "import subprocess,sys; subprocess.run([sys.executable,sys.argv[1],*sys.argv[2:]],check=True,timeout=300)" `
        (Join-Path $RepoRoot "shared/windows_package_receipt.py") @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Actual package input receipt failed. Preserve its diagnostics; no approximate provider mapping is accepted." }
    $Result = ($Json -join "`n") | ConvertFrom-Json
    if (-not $Result.ok -or $Result.host -cne "win32" -or
        $Result.receipt_sha256 -cne (Get-FileHash -LiteralPath $InputReceipt -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw "Receipt validation did not positively complete with unchanged exact bytes."
    }
    if ($Mode -eq "finalize" -and $Result.license_review_sha256 -cne
        (Get-FileHash -LiteralPath $LicenseReview -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw "Strictly validated review bytes changed before packaging."
    }
    return $Result.receipt_sha256
}

function Assert-DeclaredDependencyPins([switch]$IncludePackaging) {
    $PinArguments = @("--requirements", (Join-Path $PSScriptRoot "requirements-dev.txt"))
    if ($IncludePackaging) {
        $PinArguments += @("--requirements", (Join-Path $PSScriptRoot "installer/requirements-packaging.txt"))
    }
    # Read installed distribution metadata only. This check never installs or
    # imports codec DLLs and is not actual runtime/redistribution verification.
    & $Python -c "import subprocess,sys; subprocess.run([sys.executable,sys.argv[1],*sys.argv[2:]],check=True,timeout=30)" `
        (Join-Path $PSScriptRoot "verify_dependency_pins.py") @PinArguments
    if ($LASTEXITCODE -ne 0) { throw "Declared dependency pins do not match this interpreter. Install only in an approved isolated environment." }
}

function Assert-PinnedMediaRuntime {
    Assert-DeclaredDependencyPins
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
    # Each mandatory backend owns a fresh Qt application process. The runner
    # requires a positive completed summary, no backend skips, and a private
    # Windows Job Object deadline; it does not install or automate OS input.
    & $Python (Join-Path $RepoRoot "scripts/verify_windows.py") --required-backends-only --timeout 300
    if ($LASTEXITCODE -ne 0) { throw "Mandatory actual PDF/HEIF families failed, skipped or timed out. Inspect the preserved runner report." }
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

# Bind user-relative receipt inputs once, before Push-Location changes cwd.
# Resolve-Path retains the named input; the helper still rejects reparse paths.
if ($InputReceipt -or $ReceiptArtifacts) {
    if (-not $InputReceipt -or -not $ReceiptArtifacts) { throw "Supply both InputReceipt and ReceiptArtifacts." }
    $InputReceipt = (Resolve-Path -LiteralPath $InputReceipt).Path
    $ReceiptArtifacts = (Resolve-Path -LiteralPath $ReceiptArtifacts).Path
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
    foreach ($Pin in (@{ "pypdf" = "6.19.0"; "pillow-heif" = "1.8.0"; "pillow" = "12.3.0" }).GetEnumerator()) {
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
    $ReceiptHash = Assert-PackageReceipt "finalize" (Join-Path $BundlePath "licenses") $BundlePath $ManifestPath
    if ($Review.input_receipt_sha256 -cne $ReceiptHash) { throw "License review must bind this exact external input-receipt SHA-256." }
    return @{ manifestHash = $ManifestHash; reviewHash = (Get-FileHash -LiteralPath $ReviewPath -Algorithm SHA256).Hash.ToLowerInvariant(); receiptHash = $ReceiptHash }
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
    Assert-DeclaredDependencyPins -IncludePackaging
    $InputHash = $null
    if ($InputReceipt -or $ReceiptArtifacts) {
        $InputHash = Assert-PackageReceipt "prepare" $MaterialsPath
        $SelectedInputs = Get-Content -LiteralPath $InputReceipt -Raw | ConvertFrom-Json
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
        & $Python (Join-Path $RepoRoot "scripts/verify_windows.py") --timeout 300
        if ($LASTEXITCODE -ne 0) { throw "Windows engine/controller families failed, skipped or incomplete. Inspect the preserved runner report." }
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
        $AutoModels = Join-Path $RepoRoot "Resources/windows-auto-find"
        foreach ($ModelPin in (@{
            "face_detection_yunet_2023mar.onnx" = "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"
            "text_detection_cn_ppocrv3_2023may.onnx" = "03f550c6b406fda8bf54bd8327815f6c7e2edd98cea02348c93d879254366587"
        }).GetEnumerator()) {
            $ModelFile = Join-Path $AutoModels $ModelPin.Key
            Require-RegularFile $ModelFile
            if ((Get-FileHash -LiteralPath $ModelFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ModelPin.Value) {
                throw "Automatic finding model differs from its pinned bytes: $($ModelPin.Key)"
            }
        }
        $AutoModelArguments = @()
        foreach ($ModelName in @("face_detection_yunet_2023mar.onnx", "text_detection_cn_ppocrv3_2023may.onnx", "YuNet-LICENSE.txt", "PPOCR-LICENSE.txt", "README.md")) {
            $ModelFile = Join-Path $AutoModels $ModelName
            Require-RegularFile $ModelFile
            $AutoModelArguments += @("--add-data", "$ModelFile;auto-find-models")
        }
        # Destination and work paths are fresh; retain caches and prior outputs.
        & $Python -m PyInstaller --noconfirm --noupx --windowed --onedir --name BlurAction `
            --paths $RepoRoot --distpath $Dist --workpath $BuildWork --specpath $BuildWork `
            --additional-hooks-dir $Hooks --collect-all PySide6.QtPdf --collect-all av --collect-all cv2 `
            --collect-all pypdf --hidden-import pillow_heif --hidden-import _pillow_heif `
            @AutoModelArguments `
            (Join-Path $PSScriptRoot "launcher.py")
        if ($LASTEXITCODE -ne 0) { throw "Packaging failed." }
        if ($InputHash) {
            $AfterInputs = Assert-PackageReceipt "prepare" $MaterialsPath
            if ($AfterInputs -cne $InputHash) { throw "Selected receipt changed while packaging." }
            $ToolInput = @($SelectedInputs.artifacts | Where-Object { $_.kind -eq "wheel" -and $_.distribution -ieq "pyinstaller" })[0]
            $BuildRecord = [ordered]@{
                status = "pyinstaller-build-completed"; exit = 0; timed_out = $false
                source_archive_sha256 = $SelectedInputs.app_source.sha256
                python_executable_sha256 = $SelectedInputs.runtime.executable_sha256
                pyinstaller_wheel_sha256 = $ToolInput.sha256
                executable_sha256 = (Get-FileHash -LiteralPath (Join-Path $Dist "BlurAction/BlurAction.exe") -Algorithm SHA256).Hash.ToLowerInvariant()
                candidate_input_receipt_sha256 = $InputHash
            }
            # External sidecar: never insert this record or its receipt into
            # the hashed bundle. Curate its actual path/hash in the final receipt.
            $BuildRecord | ConvertTo-Json | Set-Content (Join-Path $Destination "pyinstaller-input-build.json") -Encoding utf8
        }
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
    if (-not $InputReceipt) { Write-Output "Input provenance pending: no receipt supplied. This candidate cannot be finalized without exact acquired inputs and an actual bound build record." }
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
    if ($After.manifestHash -cne $Before.manifestHash -or $After.reviewHash -cne $Before.reviewHash -or $After.receiptHash -cne $Before.receiptHash) {
        throw "Reviewed manifest/review bytes changed during archiving."
    }
} catch {
    Write-Warning "Archive attempt retained at $Zip; existing files are preserved."
    throw
}
Get-FileHash -LiteralPath $Zip -Algorithm SHA256 | Format-List
Write-Output "Reviewed portable ZIP prepared only. Installer and actual Windows user acceptance remain required."
