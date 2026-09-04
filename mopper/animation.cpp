//
// Spline-compressed animation, encoded and decoded through the Havok SDK.
//
// Two file formats, and the two commands are inverses over them.
//
//   HKANIMSC  a spline-compressed animation's fields, as they sit in the .hkx
//   HKANIMSM  the same animation sampled once per frame
//
//   -anim-decompress  HKANIMSC -> HKANIMSM
//   -anim-compress    HKANIMSM -> HKANIMSC
//
// Both are little-endian binary, which matters: the transforms are float data
// that has to survive the trip bit for bit, and a text round trip through a
// Windows stdout in text mode would corrupt it anyway.
//
//   HKANIMSC
//     char[8]  "HKANIMSC"
//     int32    version, currently 1
//     int32    numFrames, numBlocks, maxFramesPerBlock, maskAndQuantizationSize
//     float    blockDuration, blockInverseDuration, frameDuration, duration
//     int32    numberOfTransformTracks, numberOfFloatTracks
//     array    blockOffsets, floatBlockOffsets, transformOffsets, floatOffsets
//              each an int32 count followed by that many uint32
//     array    data, an int32 count followed by that many bytes
//
//   HKANIMSM
//     char[8]  "HKANIMSM"
//     int32    version, currently 1
//     int32    numFrames, numberOfTransformTracks, numberOfFloatTracks
//     float    duration, frameDuration
//     float    numFrames * numberOfTransformTracks * 10, frame-major:
//              translation xyz, rotation xyzw, scale xyz
//     float    numFrames * numberOfFloatTracks
//
// hkQsTransform carries a fourth lane in its translation and scale vectors that
// Havok does not use, so those are dropped rather than written out.
//
#include "stdafx.h"

#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <vector>

#include <Common/Base/hkBase.h>
#include <Common/Base/Reflection/hkClass.h>
#include <Common/Base/Reflection/hkClassMember.h>

#include <Animation/Animation/Animation/SplineCompressed/hkaSplineCompressedAnimation.h>
#include <Animation/Animation/Animation/Interleaved/hkaInterleavedUncompressedAnimation.h>

#include "animation.h"

namespace {

const int kFormatVersion = 1;

//
// A whole file in memory. These are a few hundred kilobytes at most, and having
// the bytes up front means a truncated file is caught by one length check per
// read rather than by an fread that half succeeds.
//
class Reader
{
public:
    bool open(const char* path)
    {
        FILE* f = std::fopen(path, "rb");
        if (!f) { std::fprintf(stderr, "mopper: cannot open %s\n", path); return false; }

        std::fseek(f, 0, SEEK_END);
        long n = std::ftell(f);
        std::fseek(f, 0, SEEK_SET);

        m_bytes.resize(n > 0 ? (size_t)n : 0);
        bool ok = m_bytes.empty() || std::fread(&m_bytes[0], 1, m_bytes.size(), f) == m_bytes.size();
        std::fclose(f);

        if (!ok) std::fprintf(stderr, "mopper: short read on %s\n", path);
        return ok;
    }

    bool take(void* dst, size_t n)
    {
        if (m_at + n > m_bytes.size())
        {
            std::fprintf(stderr, "mopper: input ends mid-record\n");
            return false;
        }
        std::memcpy(dst, &m_bytes[m_at], n);
        m_at += n;
        return true;
    }

    bool magic(const char* expected)
    {
        char got[8];
        if (!take(got, 8)) return false;
        if (std::memcmp(got, expected, 8) != 0)
        {
            std::fprintf(stderr, "mopper: not a %.8s file\n", expected);
            return false;
        }

        hkInt32 version = 0;
        if (!take(&version, 4)) return false;
        if (version != kFormatVersion)
        {
            std::fprintf(stderr, "mopper: %.8s version %d, expected %d\n",
                         expected, (int)version, kFormatVersion);
            return false;
        }
        return true;
    }

    bool i32(hkInt32& v)  { return take(&v, 4); }
    bool f32(hkReal& v)   { return take(&v, 4); }

private:
    std::vector<unsigned char> m_bytes;
    size_t m_at = 0;
};

class Writer
{
public:
    bool open(const char* path)
    {
        m_file = std::fopen(path, "wb");
        if (!m_file) std::fprintf(stderr, "mopper: cannot write %s\n", path);
        return m_file != HK_NULL;
    }

    ~Writer() { if (m_file) std::fclose(m_file); }

    void put(const void* src, size_t n)
    {
        if (m_file && std::fwrite(src, 1, n, m_file) != n)
        {
            std::fprintf(stderr, "mopper: write failed\n");
            std::fclose(m_file);
            m_file = HK_NULL;
        }
    }

    void magic(const char* tag) { put(tag, 8); i32(kFormatVersion); }
    void i32(hkInt32 v)  { put(&v, 4); }
    void f32(hkReal v)   { put(&v, 4); }

    bool ok() const { return m_file != HK_NULL; }

private:
    FILE* m_file = HK_NULL;
};

//
// hkaSplineCompressedAnimation keeps its fields private, so an object built here
// rather than deserialized has to be filled through the class metadata. That is
// the same route Havok's own serializer takes, and the offsets come from the
// same hkClass the SDK ships.
//
template <typename T>
T* memberOf(void* obj, const hkClass& klass, const char* name)
{
    const hkClassMember* m = klass.getMemberByName(name);
    if (!m)
    {
        std::fprintf(stderr, "mopper: no reflected member '%s' on %s\n", name, klass.getName());
        return HK_NULL;
    }
    return reinterpret_cast<T*>(reinterpret_cast<char*>(obj) + m->getOffset());
}

bool readU32Array(void* obj, const hkClass& k, const char* name, Reader& r)
{
    hkInt32 n = 0;
    if (!r.i32(n) || n < 0) return false;

    hkArray<hkUint32>* a = memberOf<hkArray<hkUint32> >(obj, k, name);
    if (!a) return false;

    a->setSize(n);
    return n == 0 || r.take(a->begin(), (size_t)n * 4);
}

void writeU32Array(void* obj, const hkClass& k, const char* name, Writer& w)
{
    hkArray<hkUint32>* a = memberOf<hkArray<hkUint32> >(obj, k, name);
    hkInt32 n = a ? a->getSize() : 0;
    w.i32(n);
    if (n > 0) w.put(a->begin(), (size_t)n * 4);
}

//
// sampleTracks leaves quantization error in the rotations on purpose. The SDK
// says so at the declaration: hkaAnimatedSkeleton renormalizes after blending,
// so the sampler does not pay for it. Anything reading samples directly has to,
// and not doing so costs about an order of magnitude of rotation accuracy.
//
void normalizeRotations(hkArray<hkQsTransform>& transforms)
{
    for (int i = 0; i < transforms.getSize(); ++i)
    {
        hkVector4& v = transforms[i].m_rotation.m_vec;
        hkReal lengthSquared = v.dot4(v);
        if (lengthSquared > 1e-16f) v.mul4(1.0f / hkMath::sqrt(lengthSquared));
    }
}

} // namespace

/*-------------------------------------------------------------------------*/
int mopperAnimDecompress(const char* inPath, const char* outPath)
{
    Reader r;
    if (!r.open(inPath) || !r.magic("HKANIMSC")) return 1;

    hkInt32 numFrames = 0, numBlocks = 0, maxFramesPerBlock = 0, maskAndQuantizationSize = 0;
    hkReal blockDuration = 0, blockInverseDuration = 0, frameDuration = 0, duration = 0;
    hkInt32 numTransformTracks = 0, numFloatTracks = 0;

    if (!r.i32(numFrames) || !r.i32(numBlocks) || !r.i32(maxFramesPerBlock)
        || !r.i32(maskAndQuantizationSize)
        || !r.f32(blockDuration) || !r.f32(blockInverseDuration)
        || !r.f32(frameDuration) || !r.f32(duration)
        || !r.i32(numTransformTracks) || !r.i32(numFloatTracks))
        return 1;

    if (numFrames <= 0 || numTransformTracks < 0 || numFloatTracks < 0)
    {
        std::fprintf(stderr, "mopper: nonsensical animation header\n");
        return 1;
    }

    //
    // Zero the storage first so every hkArray starts as a valid empty array that
    // owns nothing, then let the loaded-object constructor put the vtable in
    // place without touching the fields.
    //
    void* storage = std::calloc(1, sizeof(hkaSplineCompressedAnimation));
    if (!storage) return 1;

    hkFinishLoadedObjectFlag flag;
    flag.m_finishing = 0;
    hkaSplineCompressedAnimation* anim = new (storage) hkaSplineCompressedAnimation(flag);

    const hkClass& K = hkaSplineCompressedAnimationClass;

    anim->m_duration                = duration;
    anim->m_numberOfTransformTracks = numTransformTracks;
    anim->m_numberOfFloatTracks     = numFloatTracks;

    int failed = 0;
    struct { const char* name; hkInt32 value; } ints[] = {
        { "numFrames",               numFrames },
        { "numBlocks",               numBlocks },
        { "maxFramesPerBlock",       maxFramesPerBlock },
        { "maskAndQuantizationSize", maskAndQuantizationSize },
    };
    for (int i = 0; i < 4; ++i)
    {
        hkInt32* p = memberOf<hkInt32>(anim, K, ints[i].name);
        if (!p) { failed = 1; break; }
        *p = ints[i].value;
    }

    struct { const char* name; hkReal value; } reals[] = {
        { "blockDuration",        blockDuration },
        { "blockInverseDuration", blockInverseDuration },
        { "frameDuration",        frameDuration },
    };
    for (int i = 0; !failed && i < 3; ++i)
    {
        hkReal* p = memberOf<hkReal>(anim, K, reals[i].name);
        if (!p) { failed = 1; break; }
        *p = reals[i].value;
    }

    if (!failed)
        failed = !(readU32Array(anim, K, "blockOffsets",      r)
                && readU32Array(anim, K, "floatBlockOffsets", r)
                && readU32Array(anim, K, "transformOffsets",  r)
                && readU32Array(anim, K, "floatOffsets",      r));

    if (!failed)
    {
        hkInt32 n = 0;
        hkArray<hkUint8>* data = memberOf<hkArray<hkUint8> >(anim, K, "data");
        if (!data || !r.i32(n) || n < 0) failed = 1;
        else
        {
            data->setSize(n);
            failed = (n > 0 && !r.take(data->begin(), (size_t)n));
        }
    }

    int result = 1;
    if (!failed)
    {
        // hkQsTransform is SIMD data and wants 16-byte alignment, which hkArray
        // gives and std::vector does not promise on a 32-bit build.
        hkArray<hkQsTransform> transforms;
        hkArray<hkReal> floats;
        transforms.setSize(numTransformTracks * numFrames);
        floats.setSize(numFloatTracks > 0 ? numFloatTracks * numFrames : 1);

        hkArray<hkReal> frameFloats;
        frameFloats.setSize(numFloatTracks > 0 ? numFloatTracks : 1);

        for (int f = 0; f < numFrames; ++f)
        {
            anim->sampleTracks(f * frameDuration,
                               &transforms[f * numTransformTracks],
                               frameFloats.begin(), HK_NULL);

            for (int t = 0; t < numFloatTracks; ++t)
                floats[f * numFloatTracks + t] = frameFloats[t];
        }

        normalizeRotations(transforms);

        Writer w;
        if (w.open(outPath))
        {
            w.magic("HKANIMSM");
            w.i32(numFrames);
            w.i32(numTransformTracks);
            w.i32(numFloatTracks);
            w.f32(duration);
            w.f32(frameDuration);

            for (int i = 0; i < transforms.getSize(); ++i)
            {
                const hkQsTransform& q = transforms[i];
                for (int c = 0; c < 3; ++c) w.f32(q.m_translation(c));
                for (int c = 0; c < 4; ++c) w.f32(q.m_rotation.m_vec(c));
                for (int c = 0; c < 3; ++c) w.f32(q.m_scale(c));
            }

            for (int i = 0; i < numFloatTracks * numFrames; ++i) w.f32(floats[i]);

            result = w.ok() ? 0 : 1;
        }

        transforms.clearAndDeallocate();
        floats.clearAndDeallocate();
        frameFloats.clearAndDeallocate();
    }

    // Everything Havok allocated has to go before the caller shuts the memory
    // system down.
    const char* arrays[] = { "blockOffsets", "floatBlockOffsets",
                             "transformOffsets", "floatOffsets" };
    for (int i = 0; i < 4; ++i)
    {
        hkArray<hkUint32>* a = memberOf<hkArray<hkUint32> >(anim, K, arrays[i]);
        if (a) a->clearAndDeallocate();
    }
    if (hkArray<hkUint8>* d = memberOf<hkArray<hkUint8> >(anim, K, "data")) d->clearAndDeallocate();
    std::free(storage);

    return result;
}

/*-------------------------------------------------------------------------*/
int mopperAnimCompress(const char* inPath, const char* outPath,
                       float tolerance, int rotationQuantization)
{
    Reader r;
    if (!r.open(inPath) || !r.magic("HKANIMSM")) return 1;

    hkInt32 numFrames = 0, numTransformTracks = 0, numFloatTracks = 0;
    hkReal duration = 0, frameDuration = 0;

    if (!r.i32(numFrames) || !r.i32(numTransformTracks) || !r.i32(numFloatTracks)
        || !r.f32(duration) || !r.f32(frameDuration))
        return 1;

    if (numFrames <= 0 || numTransformTracks < 0 || numFloatTracks < 0)
    {
        std::fprintf(stderr, "mopper: nonsensical sample header\n");
        return 1;
    }

    int result = 1;
    {
        // Unlike the spline animation, this one is public all the way down, so
        // it can simply be filled in.
        hkaInterleavedUncompressedAnimation raw;
        raw.m_duration                = duration;
        raw.m_numberOfTransformTracks = numTransformTracks;
        raw.m_numberOfFloatTracks     = numFloatTracks;
        raw.m_transforms.setSize(numTransformTracks * numFrames);
        raw.m_floats.setSize(numFloatTracks * numFrames);

        bool ok = true;
        for (int i = 0; ok && i < raw.m_transforms.getSize(); ++i)
        {
            hkReal v[10];
            ok = r.take(v, sizeof(v));
            if (!ok) break;

            hkQsTransform& q = raw.m_transforms[i];
            q.m_translation.set(v[0], v[1], v[2], 0.0f);
            q.m_rotation.m_vec.set(v[3], v[4], v[5], v[6]);
            q.m_scale.set(v[7], v[8], v[9], 0.0f);
        }

        for (int i = 0; ok && i < raw.m_floats.getSize(); ++i)
            ok = r.f32(raw.m_floats[i]);

        if (ok)
        {
            hkaSplineCompressedAnimation::TrackCompressionParams tp;
            hkaSplineCompressedAnimation::AnimationCompressionParams ap;

            if (tolerance > 0.0f)
            {
                tp.m_rotationTolerance    = tolerance;
                tp.m_translationTolerance = tolerance;
                tp.m_scaleTolerance       = tolerance;
                tp.m_floatingTolerance    = tolerance;
            }

            if (rotationQuantization >= 0)
                tp.m_rotationQuantizationType =
                    (hkaSplineCompressedAnimation::TrackCompressionParams::RotationQuantization)
                        rotationQuantization;

            hkaSplineCompressedAnimation* anim = new hkaSplineCompressedAnimation(raw, tp, ap);
            const hkClass& K = hkaSplineCompressedAnimationClass;

            const hkInt32* numFramesOut         = memberOf<hkInt32>(anim, K, "numFrames");
            const hkInt32* numBlocks            = memberOf<hkInt32>(anim, K, "numBlocks");
            const hkInt32* maxFramesPerBlock    = memberOf<hkInt32>(anim, K, "maxFramesPerBlock");
            const hkInt32* maskAndQuantSize     = memberOf<hkInt32>(anim, K, "maskAndQuantizationSize");
            const hkReal*  blockDuration        = memberOf<hkReal>(anim, K, "blockDuration");
            const hkReal*  blockInverseDuration = memberOf<hkReal>(anim, K, "blockInverseDuration");
            const hkReal*  frameDurationOut     = memberOf<hkReal>(anim, K, "frameDuration");
            hkArray<hkUint8>* data              = memberOf<hkArray<hkUint8> >(anim, K, "data");

            Writer w;
            if (numFramesOut && numBlocks && maxFramesPerBlock && maskAndQuantSize
                && blockDuration && blockInverseDuration && frameDurationOut && data
                && w.open(outPath))
            {
                w.magic("HKANIMSC");
                w.i32(*numFramesOut);
                w.i32(*numBlocks);
                w.i32(*maxFramesPerBlock);
                w.i32(*maskAndQuantSize);
                w.f32(*blockDuration);
                w.f32(*blockInverseDuration);
                w.f32(*frameDurationOut);
                w.f32(anim->m_duration);
                w.i32(anim->m_numberOfTransformTracks);
                w.i32(anim->m_numberOfFloatTracks);

                writeU32Array(anim, K, "blockOffsets",      w);
                writeU32Array(anim, K, "floatBlockOffsets", w);
                writeU32Array(anim, K, "transformOffsets",  w);
                writeU32Array(anim, K, "floatOffsets",      w);

                w.i32(data->getSize());
                if (data->getSize() > 0) w.put(data->begin(), (size_t)data->getSize());

                result = w.ok() ? 0 : 1;
            }

            anim->removeReference();
        }
    }

    return result;
}
