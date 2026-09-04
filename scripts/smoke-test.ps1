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

# --- animation codec round trip ----------------------------------------------

#
# Synthetic on purpose: real animations are game data that cannot live in this
# repository or reach a runner, and the property worth checking does not need
# them. Build a set of per-frame samples, compress it, decompress it again, and
# see whether the samples came back.
#
# This catches the codec being linked but not working -- a missing hka library,
# an unregistered class, a wrong reflected member name -- which a build alone
# would not notice.
#
$animDir = Join-Path ([System.IO.Path]::GetTempPath()) "mopper-anim-$PID"
New-Item -ItemType Directory -Force -Path $animDir | Out-Null

try {
    $frames = 30
    $tracks = 3
    $frameDuration = 1.0 / 30.0
    $samples = Join-Path $animDir 'in.sm'
    $packed  = Join-Path $animDir 'packed.sc'
    $back    = Join-Path $animDir 'out.sm'

    $writer = [System.IO.BinaryWriter]::new([System.IO.File]::Create($samples))
    try {
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('HKANIMSM'))
        $writer.Write([int] 1)
        $writer.Write([int] $frames)
        $writer.Write([int] $tracks)
        $writer.Write([int] 0)
        $writer.Write([float] ($frameDuration * ($frames - 1)))
        $writer.Write([float] $frameDuration)

        # A track sliding along X, one rotating about Z, one held still. Enough
        # movement that a codec dropping a track shows up as a big deviation.
        for ($f = 0; $f -lt $frames; $f++) {
            $t = $f / [double] ($frames - 1)
            for ($k = 0; $k -lt $tracks; $k++) {
                $x = if ($k -eq 0) { [float] ($t * 10.0) } else { [float] 0.0 }
                $angle = if ($k -eq 1) { $t * [Math]::PI * 0.5 } else { 0.0 }

                $writer.Write([float] $x); $writer.Write([float] 0); $writer.Write([float] 0)
                $writer.Write([float] 0); $writer.Write([float] 0)
                $writer.Write([float] [Math]::Sin($angle / 2.0))
                $writer.Write([float] [Math]::Cos($angle / 2.0))
                $writer.Write([float] 1); $writer.Write([float] 1); $writer.Write([float] 1)
            }
        }
    }
    finally { $writer.Dispose() }

    & $Exe -anim-compress $samples $packed | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "-anim-compress exited $LASTEXITCODE" }
    elseif (-not (Test-Path $packed)) { Fail '-anim-compress wrote no output' }
    else {
        Pass "-anim-compress produced $((Get-Item $packed).Length) bytes"

        & $Exe -anim-decompress $packed $back | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "-anim-decompress exited $LASTEXITCODE" }
        elseif (-not (Test-Path $back)) { Fail '-anim-decompress wrote no output' }
        else {
            $a = [System.IO.File]::ReadAllBytes($samples)
            $b = [System.IO.File]::ReadAllBytes($back)

            if ($a.Length -ne $b.Length) {
                Fail "round trip changed the sample count ($($a.Length) -> $($b.Length) bytes)"
            }
            else {
                # Compare the floats after the 28-byte header.
                $worst = 0.0
                for ($i = 28; $i -lt $a.Length; $i += 4) {
                    $x = [BitConverter]::ToSingle($a, $i)
                    $y = [BitConverter]::ToSingle($b, $i)
                    $d = [Math]::Abs($x - $y)
                    if ($d -gt $worst) { $worst = $d }
                }

                # Lossy by design; this only has to show the animation survived.
                if ($worst -gt 0.05) { Fail "round trip deviates by $worst" }
                else { Pass "codec round trip within $([Math]::Round($worst, 5))" }
            }
        }
    }
}
finally { Remove-Item -Recurse -Force $animDir -ErrorAction SilentlyContinue }

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

# The animation modes take paths, so they answer for a file that is not one of
# theirs rather than for stdin.
$notAnAnimation = Join-Path ([System.IO.Path]::GetTempPath()) "mopper-notanim-$PID"
Set-Content -Path $notAnAnimation -Value 'not an animation' -NoNewline
try {
    Test-Rejects -Label 'unparseable -anim-decompress input' `
        -MopperArgs @('-anim-decompress', $notAnAnimation, "$notAnAnimation.out") -Stdin ''
    Test-Rejects -Label 'unparseable -anim-compress input' `
        -MopperArgs @('-anim-compress', $notAnAnimation, "$notAnAnimation.out") -Stdin ''
}
finally { Remove-Item -Force $notAnAnimation, "$notAnAnimation.out" -ErrorAction SilentlyContinue }

if ($failures -gt 0) {
    Write-Host "==> $failures check(s) failed" -ForegroundColor Red
    exit 1
}

Write-Host '==> all checks passed' -ForegroundColor Green

#
# Explicit, and not decoration. GitHub's pwsh shell ends with
# `exit $LASTEXITCODE`, which is the exit code of the last *native* command --
# here the last Test-Rejects case, where mopper is supposed to exit 1. Falling
# off the end of the script therefore failed the step with every check green.
#
exit 0
