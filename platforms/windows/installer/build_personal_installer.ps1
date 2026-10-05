param(
    [Parameter(Mandatory=$true)][string]$Bundle,
    [Parameter(Mandatory=$true)][string]$BundleManifest,
    [Parameter(Mandatory=$true)][string]$InputReceipt,
    [Parameter(Mandatory=$true)][string]$ReceiptArtifacts,
    [Parameter(Mandatory=$true)][string]$Version,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [Parameter(Mandatory=$true)][string]$FrozenReport,
    [string]$Compiler = "",
    [string]$Python = "python"
)
$ErrorActionPreference = "Stop"
if ($env:OS -ne "Windows_NT") { throw "Actual Windows required." }
if ($Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw "Invalid candidate version." }
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../../..")).Path
if ([IO.Path]::IsPathRooted($Python) -or $Python.Contains('\') -or $Python.Contains('/')) {
    $PythonItem = Get-Item -LiteralPath $Python -Force
} else {
    if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Python)) { throw "Exact Python command required." }
    $PythonItem = Get-Item -LiteralPath (@(Get-Command $Python -CommandType Application -ErrorAction Stop)[0].Source) -Force
}
if ($PythonItem.PSIsContainer -or $PythonItem.Extension -ine '.exe') { throw "Python executable required." }
$Python = $PythonItem.FullName
$Bundle = (Resolve-Path -LiteralPath $Bundle).Path
$BundleManifest = (Resolve-Path -LiteralPath $BundleManifest).Path
$InputReceipt = (Resolve-Path -LiteralPath $InputReceipt).Path
$ReceiptArtifacts = (Resolve-Path -LiteralPath $ReceiptArtifacts).Path
$FrozenReport = (Resolve-Path -LiteralPath $FrozenReport).Path
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) { throw "Output already exists; no overwrite." }
if (-not $Compiler) {
    $Located = Get-Command ISCC.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($Located) { $Compiler = $Located.Source }
    else { $Compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe' }
}
$Compiler = (Resolve-Path -LiteralPath $Compiler).Path
$Recipe = Join-Path $PSScriptRoot 'BlurAction-personal.iss'
# Read-only validation shared by before/after compilation. No review fabrication.
$Validator = @'
import hashlib,json,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
from shared import windows_package_receipt as f
root,bundle,manifest,receipt,artifacts,frozen,compiler,recipe,out=map(Path,sys.argv[1:])
if sys.platform != 'win32': raise ValueError('Actual Windows required')
for p in (root,bundle,artifacts,out.parent): f.plain(p,directory=True)
if out.exists(): f.plain(out,directory=True)
for p in (manifest,receipt,frozen,compiler,recipe): f.plain(p)
if out == root or out in root.parents: raise ValueError('Output cannot replace source tree')
for protected in (bundle,artifacts,frozen.parent):
    if out == protected or out in protected.parents or protected in out.parents:
        raise ValueError('Output must be separate from all input trees')
actual={name.replace('\\','/'):f.sha(path) for name,path in f.tree_files(bundle).values()}
entries=f.read_json(manifest)
if not isinstance(entries,list) or not entries: raise ValueError('Empty manifest')
recorded={}; folded=set()
for entry in entries:
    name=entry['path'].replace('\\','/')
    if not name.startswith('BlurAction/'): raise ValueError('Unexpected manifest root')
    name=name[len('BlurAction/'):]
    if not name or ':' in name or any(x in ('','.','..') for x in name.split('/')) or name.casefold() in folded:
        raise ValueError('Unsafe or duplicate manifest entry')
    folded.add(name.casefold());recorded[name]=entry['sha256']
if actual != recorded: raise ValueError('Bundle census or hashes differ')
for name in ('BlurAction.exe','LICENSE.txt','licenses/NOTICE.txt','licenses/dependencies.json'):
    if name not in actual or (bundle/name).stat().st_size == 0: raise ValueError('Required candidate material missing')
f.require_amd64(bundle/'BlurAction.exe')
ob=f.read_json(frozen)
bundle_hash=hashlib.sha256(json.dumps(actual,sort_keys=True,separators=(',',':')).encode()).hexdigest()
if (ob.get('status')!='frozen-smoke-pass' or ob.get('actualWindows') is not True or
    ob.get('bundleUnchanged') is not True or ob.get('exit') != 0 or ob.get('timedOut') is not False or
    ob.get('executableSHA256') != actual['BlurAction.exe'] or ob.get('bundleSHA256') != bundle_hash or
    any(ob.get(k) is not False for k in ('OSInput','installerVerified','userAcceptanceVerified','redistributionApproved'))):
    raise ValueError('Exact candidate frozen verification required')
smoke=f.plain(frozen.parent/'smoke/report.json'); log=f.plain(frozen.parent/'execution.log')
if f.sha(smoke)!=ob.get('smokeReportSHA256') or f.sha(log)!=ob.get('logSHA256'):
    raise ValueError('Frozen evidence changed')
r=f.read_json(receipt)
result=f.validate_receipt(r,artifacts_root=artifacts,materials_root=bundle/'licenses',source_root=root,mode='prepare',receipt_sha256=f.sha(receipt))
if result.get('ok') is not True or result.get('host')!='win32':
    raise ValueError('Actual input receipt failed: '+str(result.get('errors')))
# Full source archive/checkout identity remains enforced by prepare, on both calls.
print(json.dumps({'manifest':f.sha(manifest),'receipt':f.sha(receipt),'frozen':f.sha(frozen),
 'compiler':f.sha(compiler),'recipe':f.sha(recipe),'executable':actual['BlurAction.exe'],
 'source':r['app_source']['sha256']},sort_keys=True))
'@
function Assert-PersonalInputs {
    $Json = & $Python -c $Validator $RepoRoot $Bundle $BundleManifest $InputReceipt $ReceiptArtifacts $FrozenReport $Compiler $Recipe $OutputDirectory
    if ($LASTEXITCODE -ne 0) { throw "Personal candidate input validation failed." }
    return ($Json -join "`n")
}
$Before = Assert-PersonalInputs
$Hashes = $Before | ConvertFrom-Json
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$StatusPath = Join-Path $OutputDirectory 'personal-test-status.json'
$Status = [ordered]@{
    state='personal-test-not-for-redistribution'; version=$Version
    licenseReview='pending'; redistributionApproved=$false
    installerVerified=$false; userAcceptanceVerified=$false
    actualWindowsFrozenSmokeVerified=$true
    bundle_manifest_sha256=$Hashes.manifest; input_receipt_sha256=$Hashes.receipt
    source_archive_sha256=$Hashes.source; executable_sha256=$Hashes.executable
    frozen_report_sha256=$Hashes.frozen
}
$Status | ConvertTo-Json | Set-Content -LiteralPath $StatusPath -Encoding utf8
$StatusHash = (Get-FileHash -LiteralPath $StatusPath -Algorithm SHA256).Hash.ToLowerInvariant()
& $Compiler "/DSourceDir=$Bundle" "/DAppVersion=$Version" "/DBundleManifestFile=$BundleManifest" "/DPersonalStatusFile=$StatusPath" "/O$OutputDirectory" $Recipe
if ($LASTEXITCODE -ne 0) { throw "Personal installer compilation failed." }
$Installer = Join-Path $OutputDirectory "BlurAction-$Version-windows-x64-personal-setup.exe"
if (-not (Test-Path -LiteralPath $Installer -PathType Leaf)) { throw "Installer output missing." }
$After = Assert-PersonalInputs
if ($After -cne $Before -or (Get-FileHash -LiteralPath $StatusPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $StatusHash) {
    throw "Inputs changed during compilation; installer is not accepted."
}
$InstallerItem = Get-Item -LiteralPath $Installer -Force
if ($InstallerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Installer must be regular." }
$Report = [ordered]@{
    state='personal-test-installer-compiled-not-installed'; version=$Version
    redistributionApproved=$false; licenseReview='pending'; userAcceptanceVerified=$false; installerVerified=$false
    installer=$InstallerItem.Name; installer_bytes=$InstallerItem.Length
    installer_sha256=(Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash.ToLowerInvariant()
    signature_status=(Get-AuthenticodeSignature -LiteralPath $Installer).Status.ToString()
    compiler_sha256=$Hashes.compiler; compiler_version=(Get-Item -LiteralPath $Compiler).VersionInfo.FileVersion
    compiler_signature_status=(Get-AuthenticodeSignature -LiteralPath $Compiler).Status.ToString()
    bundle_manifest_sha256=$Hashes.manifest; input_receipt_sha256=$Hashes.receipt
    frozen_report_sha256=$Hashes.frozen; source_archive_sha256=$Hashes.source
    personal_status_sha256=$StatusHash; compiled_at_utc=[DateTime]::UtcNow.ToString('o')
}
$Report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'personal-installer-record.json') -Encoding utf8
$Report | ConvertTo-Json
