[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Destination,
    [Parameter(Mandatory=$true)][string]$Repository,
    [string]$Python = 'python',
    [ValidateRange(60,3600)][int]$BuildTimeoutSeconds = 2400
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Recipe = $PSScriptRoot
$Destination = [IO.Path]::GetFullPath($Destination)
$Repository = [IO.Path]::GetFullPath($Repository)
if (Test-Path -LiteralPath $Destination) { throw 'A new, nonexistent attempt directory is required.' }
if (-not (Test-Path -LiteralPath (Split-Path $Destination -Parent) -PathType Container)) { throw 'Existing approved parent required.' }
function Resolve-Application([string]$Name) {
    # Resolve one application in execution precedence order before reading Source.
    # Reading Source on the whole result can join several paths into one command.
    $Application = Get-Command -Name $Name -CommandType Application -All -ErrorAction Stop |
        Select-Object -First 1
    if ($null -eq $Application) { throw "Required application unavailable: $Name" }
    $Executable = $Application.Source
    if ($Executable -isnot [string] -or [string]::IsNullOrWhiteSpace($Executable) -or
        $Executable.IndexOfAny([char[]]"`r`n") -ge 0 -or
        -not [IO.Path]::IsPathRooted($Executable) -or
        [IO.Path]::GetExtension($Executable) -ine '.exe' -or
        -not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        throw "One actual executable path required: $Name"
    }
    return $Executable
}
$HostPython = Resolve-Application $Python
$EnvNames = @('PATH','INCLUDE','LIB','LIBPATH','VCToolsInstallDir','VCToolsVersion','VCINSTALLDIR',
              'WindowsSdkDir','WindowsSDKVersion','MSYSTEM','MSYS2_PATH_TYPE','PIP_CONFIG_FILE',
              'PYTHONUTF8','PYTHONUNBUFFERED','DISTUTILS_USE_SDK','MSSdk')
$BeforeEnv = @{}
foreach ($Name in $EnvNames) { $BeforeEnv[$Name] = [Environment]::GetEnvironmentVariable($Name,'Process') }
function CheckedPython([string]$Exe,[string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Owned helper failed: exit $LASTEXITCODE" }
}
function OwnedCommand([string]$Stem,[int]$Seconds,[string[]]$Command,[string]$WorkingDirectory=$Destination) {
    CheckedPython $script:CandidatePython (@((Join-Path $Recipe 'run_owned_command.py'),
        '--repository',$Repository,'--root',$Destination,'--cwd',$WorkingDirectory,
        '--stem',$Stem,'--timeout',"$Seconds",'--') + $Command)
}
try {
    $env:PYTHONUTF8='1'; $env:PYTHONUNBUFFERED='1'; $env:PIP_CONFIG_FILE='NUL'
    CheckedPython $HostPython @((Join-Path $Recipe 'recipe_support.py'),'acquire','--root',$Destination)
    CheckedPython $HostPython @('-m','venv',(Join-Path $Destination 'venv'))
    $script:CandidatePython = Join-Path $Destination 'venv/Scripts/python.exe'
    $Pins = Get-Content -LiteralPath (Join-Path $Recipe 'pins.json') -Raw -Encoding utf8 | ConvertFrom-Json
    $Wheels = @($Pins.wheels | ForEach-Object { Join-Path $Destination ('downloads/' + $_.filename) })
    OwnedCommand 'install-build-tools' 180 (@($CandidatePython,'-m','pip','install','--no-index','--no-deps') + $Wheels)
    $bash = Join-Path $Destination 'msys/msys64/usr/bin/bash.exe'
    if (-not (Test-Path -LiteralPath $bash -PathType Leaf)) { throw 'Pinned MSYS base layout differs.' }
    $env:MSYSTEM='MINGW64'; $env:MSYS2_PATH_TYPE='strict'
    OwnedCommand 'compiler-plan' 300 @($bash,'--noprofile','--norc',(Join-Path $Recipe 'acquire_compiler.sh'),$Destination)
    CheckedPython $CandidatePython @((Join-Path $Recipe 'recipe_support.py'),'package-lock','--root',$Destination)
    OwnedCommand 'compiler-install' 300 @($bash,'--noprofile','--norc',(Join-Path $Recipe 'install_compiler.sh'),$Destination)
    OwnedCommand 'stock-ffmpeg-build' $BuildTimeoutSeconds @($bash,'--noprofile','--norc',(Join-Path $Recipe 'build_ffmpeg.sh'),$Destination)

    # Use only the compiler already present on this disposable GitHub image.
    # No Visual Studio installer, user-wide setting, or system package mutation.
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw 'Runner MSVC unavailable.' }
    $VS = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or @($VS).Count -ne 1) { throw 'One actual runner MSVC installation required.' }
    $DevCmd = Join-Path $VS 'Common7/Tools/VsDevCmd.bat'
    if (-not (Test-Path -LiteralPath $DevCmd -PathType Leaf)) { throw 'Actual compiler environment script missing.' }
    $EnvironmentRows = & $env:ComSpec /d /s /c ('""' + $DevCmd + '" -no_logo -arch=x64 -host_arch=x64 && set"')
    if ($LASTEXITCODE -ne 0) { throw 'Actual MSVC environment unavailable.' }
    foreach ($Line in $EnvironmentRows) {
        $Split = $Line.IndexOf('=')
        if ($Split -gt 0) {
            $Key = $Line.Substring(0,$Split)
            if ($EnvNames -contains $Key) { [Environment]::SetEnvironmentVariable($Key,$Line.Substring($Split+1),'Process') }
        }
    }
    $Tools = @('cl.exe','link.exe','lib.exe') | ForEach-Object {
        $Tool = Resolve-Application $_
        [ordered]@{name=$_;path=$Tool;version=(Get-Item -LiteralPath $Tool).VersionInfo.FileVersion;
            sha256=(Get-FileHash -LiteralPath $Tool -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    [ordered]@{tools=@($Tools);VCToolsVersion=$env:VCToolsVersion;
        WindowsSDKVersion=$env:WindowsSDKVersion;ImageVersion=$env:ImageVersion;
        frozenBeforeBuild=$true;historicalVendorCompilerProven=$false} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Destination 'reports/msvc-lock.json') -Encoding utf8
    $LibTool = ($Tools | Where-Object name -eq 'lib.exe').path
    CheckedPython $CandidatePython @((Join-Path $Recipe 'recipe_support.py'),'import-libs','--root',$Destination,'--lib-tool',$LibTool)
    CheckedPython $CandidatePython @((Join-Path $Recipe 'recipe_support.py'),'dll-closure','--root',$Destination)
    $env:DISTUTILS_USE_SDK='1'; $env:MSSdk='1'
    $PyAVSource = Join-Path $Destination 'pyav-source/av-19.0.0'
    OwnedCommand 'pyav-source-wheel' $BuildTimeoutSeconds @($CandidatePython,'setup.py',
        ('--ffmpeg-dir=' + (Join-Path $Destination 'prefix')),'bdist_wheel',
        '--dist-dir',(Join-Path $Destination 'raw-wheel')) $PyAVSource
    $RawWheels = @(Get-ChildItem -LiteralPath (Join-Path $Destination 'raw-wheel') -Filter '*.whl' -File)
    if ($RawWheels.Count -ne 1) { throw 'One source-built wheel required.' }
    OwnedCommand 'repair-wheel' 180 @($CandidatePython,'-m','delvewheel','repair',
        '--add-path',(Join-Path $Destination 'prefix/bin'),'--wheel-dir',
        (Join-Path $Destination 'repaired-wheel'),$RawWheels[0].FullName)
    $Repaired = @(Get-ChildItem -LiteralPath (Join-Path $Destination 'repaired-wheel') -Filter '*.whl' -File)
    if ($Repaired.Count -ne 1) { throw 'One repaired candidate wheel required.' }
    OwnedCommand 'install-owned-wheel' 180 @($CandidatePython,'-m','pip','install','--no-index','--no-deps',$Repaired[0].FullName)
    OwnedCommand 'mf-native-smoke' 90 @($CandidatePython,(Join-Path $Recipe 'smoke.py'),$Destination)
    foreach ($Tool in $Tools) {
        if ((Get-FileHash -LiteralPath $Tool.path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Tool.sha256) { throw 'Acquired compiler changed during build.' }
    }
    [ordered]@{status='owned-core-build-and-native-smoke-complete';sourceComplete=$false;
        privateCandidateOnly=$true;allFormatsVerified=$false;QtIMEVerified=$false;
        appInstalled=$false;timelineP1Closed=$false;releaseApproved=$false} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination 'reports/outcome.json') -Encoding utf8
} catch {
    if (Test-Path -LiteralPath (Join-Path $Destination 'reports') -PathType Container) {
        [ordered]@{status='failed-or-incomplete';error=$_.Exception.Message;releaseApproved=$false} |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination 'reports/outcome.json') -Encoding utf8
    }
    throw
} finally {
    if (Test-Path -LiteralPath (Join-Path $Destination 'owned.json') -PathType Leaf) {
        # Preserve partial output; never remove other attempts or operating apps.
        & $HostPython (Join-Path $Recipe 'recipe_support.py') manifest --root $Destination
    }
    foreach ($Name in $EnvNames) { [Environment]::SetEnvironmentVariable($Name,$BeforeEnv[$Name],'Process') }
}
