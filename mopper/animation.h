//
// Havok spline-compressed animation, encoded and decoded through the SDK.
//
// Havok's spline compression is proprietary and there is no independent encoder
// worth trusting: reproducing its curve fitting and quantization choices well
// enough that animations behave in game is a research project. The SDK we
// already link does both directions, so this exposes them.
//
// The SDK cannot be handed a Skyrim SE file to do it. Those are 64-bit
// packfiles, and this Win32 2010 build reports them as not loadable through
// hkSerializeUtil::isLoadable. So nothing here reads or writes .hkx: the caller
// parses the file (HKX2 does it in C#) and passes the animation's fields across
// in the flat formats described in animation.cpp.
//
#ifndef MOPPER_ANIMATION_H
#define MOPPER_ANIMATION_H

// Spline-compressed animation in, per-frame transforms out.
int mopperAnimDecompress(const char* inPath, const char* outPath);

// Per-frame transforms in, spline-compressed animation out.
//
// tolerance < 0 and rotationQuantization < 0 leave the SDK's defaults alone.
// Note that Bethesda did not use the defaults: recompressing a vanilla
// animation at them produces a noticeably larger block than it started as.
int mopperAnimCompress(const char* inPath, const char* outPath,
                       float tolerance, int rotationQuantization);

#endif // MOPPER_ANIMATION_H
