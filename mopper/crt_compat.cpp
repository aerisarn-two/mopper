//
// CRT compatibility shims for linking Havok against a modern MSVC.
//
// The Havok libraries were built with Visual Studio 2008. Visual Studio 2015
// reorganised the C runtime into the Universal CRT, which turned many stdio
// functions into inline definitions and dropped some symbols entirely. Old
// object files still reference the symbols that used to exist, so linking them
// into a new build fails with unresolved externals such as:
//
//     _printf  __snprintf  __vsnprintf  _vsprintf  ___iob_func
//
// Most of those come back by linking legacy_stdio_definitions.lib, which the
// build does. __iob_func is not in it and has to be provided by hand, which is
// what this file is for. ck-cmd carries the same shim for the same reason.
//

#include <cstdio>

// The old CRT exposed the standard streams as an array reachable through
// __iob_func. Rebuild that array from the three stream pointers the modern CRT
// still provides.
//
// The array is deliberately *not* called _iob: the Universal CRT still defines
// that symbol itself, in libucrt.lib(_file.obj), and a second definition is a
// duplicate-symbol error. Only __iob_func has to keep its name.
static FILE mopper_iob[] = { *stdin, *stdout, *stderr };

extern "C" FILE* __cdecl __iob_func(void)
{
    return mopper_iob;
}
