#Requires -Version 5.1
<#
.SYNOPSIS
    Fetches the parts of the Havok 2010.2 SDK that mopper needs.

.DESCRIPTION
    The SDK is a 472 MB 7z holding 2.94 GB of demos, docs, tools and every
    library flavour. mopper needs two of those directories and nothing else, so
    this extracts only Source/ and one Lib/ flavour -- about 215 MB.

    Note that the archive is a single solid LZMA block (5,531 of its 5,545
    files), so a partial extract still decompresses the whole stream. This saves
    disk and cache space, not time. Budget a few minutes.

    The SDK is not redistributable, so nothing this downloads belongs in a
    commit, a release asset, or a package. Use it to build and let it go.

.PARAMETER Destination
    Where to put the SDK. Becomes HAVOK_SDK_DIR: it will contain Source/ and Lib/.

.PARAMETER LibSubdir
    Which Lib/ flavour to extract. Must match CMake's HAVOK_LIB_SUBDIR.

.PARAMETER Url
    Where to download from. Overridable because the default is a third-party
    re-upload that could disappear.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Destination,
    [string] $LibSubdir = 'win32_net_9-0/release_multithreaded',
    [string] $Url = 'https://archive.org/download/Havok2010HCTSDK/hk2010_2_0_r1.7z',
    [string] $ExpectedSha1 = '164b856d38f05b7a7a35b03bfffd3da8d761da2c'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Log { param([string] $Message) Write-Host "==> $Message" -ForegroundColor Cyan }

$sentinel = Join-Path $Destination 'Source/Common/Base/hkBase.h'

if (Test-Path -LiteralPath $sentinel) {
    Log "Havok SDK already present at $Destination, nothing to do"
    exit 0
}

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$archive = Join-Path ([System.IO.Path]::GetTempPath()) 'hk2010_2_0_r1.7z'

# curl.exe ships with Windows and is far quicker than Invoke-WebRequest, whose
# progress rendering dominates the runtime on a download this size.
Log "downloading $Url (472 MB)"
& curl.exe --location --fail --retry 3 --retry-delay 5 --output $archive $Url
if ($LASTEXITCODE -ne 0) { throw "download failed (curl exit $LASTEXITCODE)" }

Log 'verifying SHA1'
$actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA1).Hash.ToLowerInvariant()

if ($actual -ne $ExpectedSha1.ToLowerInvariant()) {
    Remove-Item -LiteralPath $archive -Force
    throw @"
SHA1 mismatch on the Havok archive.
  expected $ExpectedSha1
  got      $actual
Refusing to build against an archive that is not the one this was pinned to.
"@
}

# 7-Zip is preinstalled on GitHub's windows runners. Masks use backslashes so
# 7-Zip's matcher sees native separators.
$libMask = ('Lib/' + $LibSubdir).Replace('/', '\')

Log "extracting Source\ and $libMask\ into $Destination"
& 7z x -y "-o$Destination" $archive 'Source\*' "$libMask\*" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "7z failed (exit $LASTEXITCODE)" }

Remove-Item -LiteralPath $archive -Force

# The archive layout is the contract here, so check it rather than letting a
# change surface later as a confusing CMake error.
if (-not (Test-Path -LiteralPath $sentinel)) {
    throw "extracted, but there is no Source/Common/Base/hkBase.h under $Destination"
}

$libDir = Join-Path $Destination ('Lib/' + $LibSubdir)
if (-not (Test-Path -LiteralPath (Join-Path $libDir 'hkBase.lib'))) {
    throw "extracted, but there is no hkBase.lib under $libDir"
}

$size = (Get-ChildItem -LiteralPath $Destination -Recurse -File |
         Measure-Object -Property Length -Sum).Sum / 1MB
Log ("ready at {0} ({1:N0} MB)" -f $Destination, $size)
