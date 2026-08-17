cmake_minimum_required(VERSION 3.25)

#
# MSVC's /Zi writes debug info to a .pdb through mspdbsrv.exe, a background
# service that does not work under Wine -- it fails with
# "fatal error C1902: Program database manager mismatch".
#
# /Z7 puts the same debug info straight into the object files and needs no
# service, so select it before project() runs, while it can still affect the
# compiler checks. Requires CMake 3.25 for CMP0141.
#
set(CMAKE_MSVC_DEBUG_INFORMATION_FORMAT "Embedded" CACHE STRING
    "Debug information format (Embedded avoids mspdbsrv, which Wine cannot run)")

#
# Embedding a side-by-side manifest runs mt.exe, which fails under Wine when
# CMake drives it through vs_link_exe. A console tool has no use for one, so
# switch it off. This must be in the linker flags before project() so the
# compiler check links too.
#
set(CMAKE_EXE_LINKER_FLAGS_INIT "/MANIFEST:NO")

project(mopper CXX)

#
# mopper builds against the Havok SDK, which is only distributed as MSVC-compiled
# 32-bit static libraries. That means MSVC is required even when building from
# Linux: MinGW cannot link MSVC C++ static libs, because the two use different C++
# ABIs and name mangling. scripts/install-deps.sh sets up an MSVC toolchain that
# runs under Wine so the whole thing can be driven from Linux.
#
# The flags below mirror ck-cmd, which is known to build this exact SDK
# (havok_2010_2_0, Lib/win32_net_9-0) with a modern MSVC.
#

set(HAVOK_SDK_DIR "" CACHE PATH
    "Root of the Havok SDK, i.e. the directory containing Source/ and Lib/")

set(HAVOK_LIB_SUBDIR "win32_net_9-0/release_multithreaded" CACHE STRING
    "Path under Lib/ holding the static libraries to link")

if(NOT HAVOK_SDK_DIR)
    message(FATAL_ERROR
        "HAVOK_SDK_DIR is not set. Pass -DHAVOK_SDK_DIR=/path/to/havok_2010_2_0 "
        "(the directory containing Source/ and Lib/).")
endif()

set(HAVOK_INCLUDE_DIR "${HAVOK_SDK_DIR}/Source")
set(HAVOK_LIB_DIR "${HAVOK_SDK_DIR}/Lib/${HAVOK_LIB_SUBDIR}")

if(NOT EXISTS "${HAVOK_INCLUDE_DIR}/Common/Base/hkBase.h")
    message(FATAL_ERROR
        "No Havok headers under ${HAVOK_INCLUDE_DIR}. Is HAVOK_SDK_DIR correct?")
endif()

if(NOT IS_DIRECTORY "${HAVOK_LIB_DIR}")
    message(FATAL_ERROR
        "No Havok libraries at ${HAVOK_LIB_DIR}. Set HAVOK_LIB_SUBDIR to one of the "
        "directories under ${HAVOK_SDK_DIR}/Lib.")
endif()

#
# Libraries mopper needs. The hkcd* pair only exists from Havok 2011 onwards, where
# some of hkBase and hkInternal was split out, so we link whatever is actually
# present rather than hard-coding one SDK version.
#
set(HAVOK_CANDIDATE_LIBS
    hkBase
    hkCompat
    hkGeometryUtilities
    hkInternal
    hkSceneData
    hkSerialize
    hkpCollide
    hkpConstraintSolver
    hkpDynamics
    hkpInternal
    hkpUtilities
    hkpVehicle
    hkcdCollide
    hkcdInternal
)

set(HAVOK_LIBS "")

foreach(lib IN LISTS HAVOK_CANDIDATE_LIBS)
    if(EXISTS "${HAVOK_LIB_DIR}/${lib}.lib")
        list(APPEND HAVOK_LIBS "${HAVOK_LIB_DIR}/${lib}.lib")
    else()
        message(STATUS "Havok: ${lib}.lib not in this SDK, skipping")
    endif()
endforeach()

if(NOT HAVOK_LIBS)
    message(FATAL_ERROR "Found no Havok libraries in ${HAVOK_LIB_DIR}.")
endif()

add_executable(mopper
    mopper/mopper.cpp
    mopper/stdafx.cpp
    mopper/crt_compat.cpp
)

target_include_directories(mopper PRIVATE
    "${HAVOK_INCLUDE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/mopper"
)

target_link_libraries(mopper PRIVATE ${HAVOK_LIBS})

# CMake links the Havok libs, so the source must not also name them in #pragma
# comment(lib), which would hard-code one SDK's library set.
target_compile_definitions(mopper PRIVATE
    MOPPER_NO_LIB_PRAGMAS
    _CRT_SECURE_NO_WARNINGS=1
    _SCL_SECURE_NO_WARNINGS=1
    _CRT_NONSTDC_NO_DEPRECATE=1
)

if(MSVC)
    # The Havok libraries are built against the static runtime. Mixing in the
    # dynamic one produces duplicate-symbol and unresolved-external errors, so
    # force /MT and explicitly exclude the dynamic CRT, exactly as ck-cmd does.
    set_property(TARGET mopper PROPERTY
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

    target_compile_options(mopper PRIVATE /EHsc /bigobj)

    target_link_options(mopper PRIVATE
        /NODEFAULTLIB:MSVCRT
        /NODEFAULTLIB:MSVCRTD
        /STACK:4194304
    )

    # The Havok libraries are Visual Studio 2008 objects. VS2015 reorganised the
    # C runtime into the Universal CRT and made many stdio functions inline, so
    # those old objects reference symbols that no longer exist (_printf,
    # __snprintf, __vsnprintf, _vsprintf). This library defines them again.
    # __iob_func is not covered by it and is shimmed in mopper/crt_compat.cpp.
    target_link_libraries(mopper PRIVATE legacy_stdio_definitions.lib)
endif()

install(TARGETS mopper RUNTIME DESTINATION bin)
