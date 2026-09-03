<#
.SYNOPSIS
    Runs mopper.exe against the checked-in fixtures and checks the output is a
    well-formed MOPP tree.

.DESCRIPTION
    A 32-bit binary runs natively on a 64-bit Windows runner, so CI can do more
    than check that the thing links. -msm writes a fixed line-oriented shape:

        offset x, offset y, offset z, scale     4 lines
        <n>                                     1 line, MOPP byte count
        <n bytes>                               n lines, each 0..255
        <t>                                     1 line, triangle count
        <t welding values>                      t lines

    Checking that shape catches an empty tree, a truncated write, and a build
    that produces a binary that runs but computes nothing.

.PARAMETER Exe
    Path to mopper.exe.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Exe
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$failures = 0

function Fail { param([string] $Message) Write-Host "  FAIL $Message" -ForegroundColor Red; $script:failures++ }
function Pass { param([string] $Message) Write-Host "  ok   $Message" -ForegroundColor Green }

Write-Host "==> smoke testing $Exe" -ForegroundColor Cyan

# --- it starts at all -------------------------------------------------------

$help = & $Exe --help
if ($LASTEXITCODE -ne 0) { Fail "--help exited $LASTEXITCODE" }
elseif ($help -join "`n" -notmatch 'usage: mopper') { Fail '--help printed no usage' }
else { Pass '--help' }

# --- -msm produces a MOPP tree over the simple mesh fixture -----------------

$fixture = Join-Path $root 'mopper/testmesh.txt'
$out = & $Exe -msm $fixture

if ($LASTEXITCODE -ne 0) {
    Fail "-msm exited $LASTEXITCODE"
} else {
    $lines = @($out | Where-Object { $_ -ne '' })

    if ($lines.Count -lt 6) {
        Fail "-msm wrote only $($lines.Count) lines"
    } else {
        $moppSize = 0
        if (-not [int]::TryParse($lines[4], [ref] $moppSize) -or $moppSize -le 0) {
            Fail "-msm reported a MOPP size of '$($lines[4])', expected a positive integer"
        } else {
            # 4 header lines + the size + its bytes + the triangle count + welding
            $expected = 5 + $moppSize + 1 + 12

            if ($lines.Count -ne $expected) {
                Fail "-msm wrote $($lines.Count) lines, expected $expected for a $moppSize-byte tree over 12 triangles"
            } elseif ($lines[(5 + $moppSize)] -ne '12') {
                Fail "-msm reported $($lines[5 + $moppSize]) triangles, expected 12"
            } else {
                $bytes = $lines[5..(4 + $moppSize)]
                $bad = @($bytes | Where-Object { $_ -notmatch '^\d+$' -or [int] $_ -gt 255 })

                if ($bad.Count -gt 0) {
                    Fail "-msm wrote $($bad.Count) MOPP values outside 0..255"
                } else {
                    Pass "-msm produced a $moppSize-byte MOPP tree over 12 triangles"
                }
            }
        }
    }
}

# --- -ccm builds a compressed mesh shape ------------------------------------

$ccmFixture = Join-Path $root 'mopper/testmesh_ccm.txt'
$ccm = & $Exe -ccm $ccmFixture

if ($LASTEXITCODE -ne 0) { Fail "-ccm exited $LASTEXITCODE" }
elseif (@($ccm | Where-Object { $_ -ne '' }).Count -lt 10) { Fail '-ccm wrote almost nothing' }
else { Pass "-ccm produced $(@($ccm).Count) lines" }

# --- -ccmm reads a material table and an index per geometry ------------------

#
# Same mesh as testmesh_ccm.txt, with the two numbers -ccmm adds: a material
# count in front, and the table entry this geometry is made of. The table is a
# count only -- no names are read from the stream -- which is easy to get wrong
# when writing input by hand.
#
$ccmmFixture = Join-Path $root 'mopper/testmesh_ccmm.txt'
$ccmm = & $Exe -ccmm $ccmmFixture

if ($LASTEXITCODE -ne 0) { Fail "-ccmm exited $LASTEXITCODE" }
elseif (@($ccmm | Where-Object { $_ -ne '' }).Count -lt 10) { Fail '-ccmm wrote almost nothing' }
else { Pass "-ccmm produced $(@($ccmm).Count) lines" }

# --- bad input is refused, not crashed on ------------------------------------

#
# Every mode has to answer for what it was given. Reading it is not the point --
# saying so in the exit status is, because a caller has nothing else to go on.
# -msm and -clm used to exit 0 here, -clm even after printing the diagnosis.
#
function Test-Rejects {
    param([string] $Label, [string[]] $MopperArgs, [string] $Stdin)

    $Stdin | & $Exe @MopperArgs 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) { Fail "$Label was accepted, expected a non-zero exit" }
    else { Pass "$Label refused (exit $LASTEXITCODE)" }
}

Test-Rejects -Label 'unparseable -msm input'  -MopperArgs @('-msm', '--')  -Stdin 'not a mesh'
Test-Rejects -Label 'unparseable -ccm input'  -MopperArgs @('-ccm', '--')  -Stdin 'not a mesh'
Test-Rejects -Label 'unparseable -clm input'  -MopperArgs @('-clm', '--')  -Stdin 'not a shape'
Test-Rejects -Label 'unparseable -ccmm input' -MopperArgs @('-ccmm', '--') -Stdin 'not a mesh'
Test-Rejects -Label 'empty -msm input'        -MopperArgs @('-msm', '--')  -Stdin ''

# A count larger than the vertices that follow it: the mesh stops mid-list.
Test-Rejects -Label 'truncated -msm input'    -MopperArgs @('-msm', '--')  -Stdin "8`n1 1 1`n"

if ($failures -gt 0) {
    Write-Host "==> $failures check(s) failed" -ForegroundColor Red
    exit 1
}

Write-Host '==> all checks passed' -ForegroundColor Green
