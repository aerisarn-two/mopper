# Continuous integration and packaging

Two workflows, both deliberately not on every push.

| Workflow | Runs on | What it does |
| --- | --- | --- |
| `windows.yml` | a `v*` tag, or manually | Builds with native MSVC, tests the binary and the animation codec, packs `Mopper.Native`, publishes to GitHub Packages |
| `linux.yml` | manually only | Rebuilds through msvc-wine, to check `README-linux.md` still describes reality |

Building and releasing share one workflow because they share a trigger. Split
across two, a tag would build the same binary twice and could publish one that
was never the one tested.

## The Havok SDK in CI

Neither workflow can build without the SDK, and the SDK is not in this
repository and must not be. `scripts/fetch-havok.{ps1,sh}` downloads it, checks
it, and extracts the part that is needed:

- Downloads `hk2010_2_0_r1.7z`, 472 MB.
- Verifies SHA1 `164b856d38f05b7a7a35b03bfffd3da8d761da2c` and refuses to go on
  if it does not match.
- Extracts `Source/` and one `Lib/` flavour: about 215 MB of the archive's
  2.94 GB. The rest is demos, docs, tools and library flavours nothing links.
- Asserts `Source/Common/Base/hkBase.h` and `hkBase.lib` arrived, so a change in
  the archive fails here rather than as a puzzling CMake error later.

The result is cached under a key pinned to that SHA1, so the download happens
once. GitHub evicts caches unused for 7 days, which is the only thing that
brings it back.

Extraction is not fast. The archive is a single solid LZMA block holding 5,531
of its 5,545 files, so a partial extract still decompresses the whole stream.
Taking only two directories saves disk and cache space, not time.

### If the download disappears

The default URL is a third-party re-upload of an SDK whose official download was
withdrawn. Both workflows take a `havok-url` input on manual runs, so you can
point at your own copy without editing anything. A cached run never touches the
network at all.

## What the smoke test checks

`scripts/smoke-test.ps1` runs the built binary, which is worth doing because a
32-bit executable runs natively on the Windows runner. `-msm` writes a fixed
shape:

    offset x, offset y, offset z, scale     4 lines
    <n>                                     MOPP byte count
    <n bytes>                               each 0..255
    <t>                                     triangle count
    <t welding values>

The test asserts that whole structure against `mopper/testmesh.txt`, checks
`-ccm` produces output for `mopper/testmesh_ccm.txt`, and checks unparseable
input is refused rather than crashed on. That catches an empty tree, a truncated
write, and a binary that runs but computes nothing — none of which a build alone
would notice.

It also round-trips the animation codec: build a set of per-frame samples,
`-anim-compress` them, `-anim-decompress` the result, and check the samples came
back. The samples are synthetic, deliberately — real animations are game data
that cannot live here or reach a runner, and the property worth checking does
not need them. It catches the codec being linked but not working: a missing
`hka` library, a class that was never registered, a reflected member name that
moved.

Once you have blessed a known-good MOPP code, this can tighten to a golden-file
comparison; both fixtures are deterministic.

## Releasing

Tag and push:

    git tag v1.0.0
    git push origin v1.0.0

The tag is the single source of the version. Minus its `v` it becomes:

- the NuGet package version,
- the `VERSIONINFO` resource compiled into `mopper.exe`,
- the GitHub release name.

A tag that is not a version is rejected in the first step, before the SDK
download, rather than ten minutes later when `nuget pack` would have noticed.
`v1.2.3` and `v1.2.3-rc.1` are accepted; `v1.2` is not. A `-` in the version
marks the release as a prerelease.

Manual runs pack a `0.0.0-ci.<run>` version and skip both the publish and the
release, so packaging breakage surfaces before a tag rather than during one.

Publishing uses the built-in `GITHUB_TOKEN`, so there is no secret to configure.
The job needs `packages: write` to publish and `contents: write` to create the
release.

The release is created *after* the package push, so a failed push never leaves a
release advertising a version that is not on the feed. It carries the same
`mopper.exe` the smoke test ran and the same `.nupkg` that was published.

### The version resource

`mopper/version.rc.in` is a CMake template. `MOPPER_VERSION` drives it:

    cmake -B build ... -DMOPPER_VERSION=1.2.3

or, through the Linux script, `MOPPER_VERSION=1.2.3 ./scripts/build.sh ...`.

It defaults to `0.0.0`, which is the honest answer for an untagged local build.
`VERSIONINFO`'s numeric fields take four integers, so a prerelease suffix is
dropped there but kept in the `FileVersion` and `ProductVersion` strings:
`1.2.3-rc.1` stamps `1,2,3,0` alongside the string `1.2.3-rc.1`.

The resource is only compiled on a Windows target. msvc-wine ships `rc` next to
`cl`, so this works from Linux too.

## Consuming the package

`Mopper.Native` carries `mopper.exe` and an MSBuild targets file. It has no
managed assembly — this is a native tool, not a library.

Add a `nuget.config` beside your solution:

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="github" value="https://nuget.pkg.github.com/aerisarn-two/index.json" />
  </packageSources>
  <packageSourceCredentials>
    <github>
      <add key="Username" value="%GITHUB_USER%" />
      <add key="ClearTextPassword" value="%GITHUB_TOKEN%" />
    </github>
  </packageSourceCredentials>
</configuration>
```

GitHub Packages requires authentication even for public packages, and the token
needs `read:packages`. That is the one rough edge of this feed compared with
nuget.org.

Then:

```xml
<PackageReference Include="Mopper.Native" Version="1.0.0" />
```

`mopper.exe` is copied next to your output, and `$(MopperExePath)` points at it
inside the package if you would rather not rely on the copy:

```csharp
var psi = new ProcessStartInfo(
    Path.Combine(AppContext.BaseDirectory, "mopper.exe"),
    "-msm --")
{
    RedirectStandardInput = true,
    RedirectStandardOutput = true,
    UseShellExecute = false,
};
```

Feed the mesh on stdin and read the MOPP tree back on stdout, in the line format
above. The binary is 32-bit, which does not constrain you: it runs as a separate
process, so a 64-bit .NET application drives it fine.

## Licensing

`mopper.exe` statically links the Havok SDK, so the package contains Havok object
code and ships with `NOTICE-Havok.txt` saying so. The SDK itself is not
redistributed, in source or library form, by this repository or the package.

Publishing to a GitHub Packages feed rather than nuget.org keeps that binary
within an audience you control. That was a deliberate choice; see the licence
agreement shipped with the SDK before widening it.
