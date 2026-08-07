# CMakeLists.txt - builds the installable C library
#
# SwiftPM covers development and the Swift library, but it cannot set an install
# name, a soname, or an export list, and those are exactly what make a library
# substitutable for another one.  So the artifact that gets installed is built
# here.
#
# CMake compiles Swift only under the Ninja and Xcode generators, and a single
# target cannot mix Swift with another language, so the engine builds as a static
# Swift archive and the C shim links it into the shared library.

cmake_minimum_required(VERSION 3.29) # CMP0157, for Swift compilation mode

project(swift-png
    VERSION 1.6.58
    DESCRIPTION "libpng, implemented in Swift"
    LANGUAGES C Swift)

include(GNUInstallDirs)

option(SPNG_USE_SYSTEM_ZLIB
    "Compress with the system zlib rather than the Swift implementation" ON)
option(SPNG_STATIC_STDLIB
    "Link the Swift runtime statically, so the library needs no toolchain at run time" OFF)
option(SPNG_BUILD_TESTS "Build the conformance programs" ON)

# ON, OFF, or AUTO, which probes the toolchain: the fixed-size array type needs a compiler and
# deployment target new enough to have it, and the portable fallback is what every other build gets.
set(SPNG_INLINE_ARRAYS AUTO CACHE STRING
    "Use the standard library's fixed-size arrays where small fixed storage is needed")

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

# The ABI we are compatible with.  16 is the soname generation; 75 is the Mach-O
# compatibility version the reference build carries.  Clients bind to these, so
# they are part of the contract rather than our own version number.
set(SPNG_ABI_SONAME 16)
set(SPNG_MACHO_COMPATIBILITY_VERSION 75)

set(SPNG_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/Sources/CPNG/include)
set(SPNG_MODULE_MAP ${SPNG_INCLUDE_DIR}/module.modulemap)

find_package(Python3 REQUIRED COMPONENTS Interpreter)

if(SPNG_USE_SYSTEM_ZLIB)
    find_package(ZLIB REQUIRED)
endif()

# -- generated sources -------------------------------------------------------
#
# These are committed as well as generated, so a checkout builds without Python
# and CI can diff the regenerated output to catch a stale file.

set(SPNG_EXPORT_LIST ${CMAKE_CURRENT_BINARY_DIR}/png16.exp)
set(SPNG_VERSION_SCRIPT ${CMAKE_CURRENT_BINARY_DIR}/png16.vers)

add_custom_command(
    OUTPUT ${SPNG_EXPORT_LIST} ${SPNG_VERSION_SCRIPT}
    COMMAND ${Python3_EXECUTABLE}
            ${CMAKE_CURRENT_SOURCE_DIR}/scripts/gen_symbols.py
            ${CMAKE_CURRENT_BINARY_DIR}
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/scripts/gen_symbols.py
            ${CMAKE_CURRENT_SOURCE_DIR}/scripts/symbols.txt
    COMMENT "Generating linker export lists")

add_custom_target(spng_export_lists
    DEPENDS ${SPNG_EXPORT_LIST} ${SPNG_VERSION_SCRIPT})

# -- the engine --------------------------------------------------------------
#
# One CMake target per Swift module, matching the package's layout.  Building
# them as separate modules rather than compiling every source into one is what
# lets the same `import` lines work under both build systems, and it keeps the
# engine unable to reach the C API by accident.

# Whole-module optimisation matters here: the row pipeline crosses several files
# per scanline, and the inlining that removes those boundaries is what keeps it
# competitive.
set(SPNG_COMPILATION_MODE $<IF:$<CONFIG:Release>,wholemodule,incremental>)

function(spng_add_swift_module_at name directory)
    file(GLOB_RECURSE sources CONFIGURE_DEPENDS ${directory}/*.swift)

    add_library(${name} STATIC ${sources})

    set_target_properties(${name} PROPERTIES
        POSITION_INDEPENDENT_CODE ON
        Swift_MODULE_NAME ${name}
        Swift_COMPILATION_MODE ${SPNG_COMPILATION_MODE})

    # The API's own contract is one structure per thread, so the dynamic
    # bookkeeping that catches overlapping exclusive accesses at run time has
    # nothing to catch; what it costs is measurable on every row.  Debug builds
    # keep the checking.
    target_compile_options(${name} PRIVATE
        $<$<CONFIG:Release>:-enforce-exclusivity=unchecked>)
endfunction()

# The ordinary case: a module whose sources are this repository's own.
function(spng_add_swift_module name)
    spng_add_swift_module_at(${name} ${CMAKE_CURRENT_SOURCE_DIR}/Sources/${name})
endfunction()

# DEFLATE and INFLATE come from the sibling package rather than being carried here, so that the
# two libraries share one implementation instead of each keeping its own copy.  Only the sources
# are wanted: that package's own CMakeLists builds a C library this build has no use for, so
# SOURCE_SUBDIR names a directory that does not exist and nothing of it is configured.
include(FetchContent)

FetchContent_Declare(swift_zlib
    GIT_REPOSITORY https://github.com/PureSwift/swift-zlib.git
    GIT_TAG 1.0.0
    GIT_SHALLOW TRUE
    SOURCE_SUBDIR sources-only)

FetchContent_MakeAvailable(swift_zlib)

spng_add_swift_module_at(LZ77 ${swift_zlib_SOURCE_DIR}/Sources/LZ77)
spng_add_swift_module_at(Zlib ${swift_zlib_SOURCE_DIR}/Sources/Zlib)
spng_add_swift_module(PNG)
spng_add_swift_module(PNGABI)

target_link_libraries(Zlib PUBLIC LZ77)
target_link_libraries(PNG PUBLIC Zlib)
target_link_libraries(PNGABI PUBLIC PNG)

# Only the boundary module sees the C API.
target_compile_options(PNGABI PRIVATE
    "SHELL:-Xcc -I${SPNG_INCLUDE_DIR}"
    "SHELL:-Xcc -fmodule-map-file=${SPNG_MODULE_MAP}")

if(SPNG_INLINE_ARRAYS STREQUAL "AUTO")
    file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/inline_array_probe.swift
        "let probe = InlineArray<8, Int32>(repeating: 0)\nlet _ = probe[0]\n")
    execute_process(
        COMMAND ${CMAKE_Swift_COMPILER} -typecheck
            ${CMAKE_CURRENT_BINARY_DIR}/inline_array_probe.swift
        RESULT_VARIABLE SPNG_INLINE_ARRAY_PROBE
        OUTPUT_QUIET ERROR_QUIET)

    if(SPNG_INLINE_ARRAY_PROBE EQUAL 0)
        set(SPNG_INLINE_ARRAYS ON)
    else()
        set(SPNG_INLINE_ARRAYS OFF)
    endif()
endif()

if(SPNG_INLINE_ARRAYS)
    target_compile_definitions(PNG PRIVATE InlineArrays)
endif()

if(SPNG_USE_SYSTEM_ZLIB)
    target_compile_definitions(PNG PRIVATE SystemZlib)

    # The module map has to be visible to everything that imports PNG, not just
    # to PNG itself: a clang module a Swift module depends on has to be
    # loadable wherever that Swift module is imported.
    set(SPNG_ZLIB_MODULE_MAP
        ${CMAKE_CURRENT_SOURCE_DIR}/Sources/CSystemZlib/module.modulemap)

    foreach(target PNG PNGABI)
        target_compile_options(${target} PRIVATE
            "SHELL:-Xcc -fmodule-map-file=${SPNG_ZLIB_MODULE_MAP}")
    endforeach()
endif()

# -- the shared library ------------------------------------------------------

add_library(png16 SHARED
    Sources/CPNG/swift_error.c
    Sources/CPNG/swift_memory.c
    Sources/CPNG/swift_lifecycle.c
    Sources/CPNG/swift_callbacks.c
    Sources/CPNG/swift_simplified.c
    Sources/CPNG/gen/swift_stubs.c)

add_dependencies(png16 spng_export_lists)

target_include_directories(png16
    PUBLIC $<BUILD_INTERFACE:${SPNG_INCLUDE_DIR}>
           $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}/libpng${SPNG_ABI_SONAME}>)

# The engine's archives reach the link differently per format, so they are added in
# the platform branches below.
add_dependencies(png16 PNGABI)

if(SPNG_USE_SYSTEM_ZLIB)
    target_link_libraries(png16 PRIVATE ZLIB::ZLIB)
endif()

# Driving the link with swiftc is what pulls in the Swift runtime and the
# metadata registration object the static archive needs.
set_target_properties(png16 PROPERTIES
    LINKER_LANGUAGE Swift
    OUTPUT_NAME png${SPNG_ABI_SONAME}
    VERSION ${SPNG_ABI_SONAME}
    SOVERSION ${SPNG_ABI_SONAME})

if(APPLE)
    set_target_properties(png16 PROPERTIES
        INSTALL_NAME_DIR ${CMAKE_INSTALL_FULL_LIBDIR})

    # A client records the compatibility version of what it linked against, and
    # dyld refuses a library that offers a lower one, so this has to match the
    # reference build rather than track our own version number.
    #
    # The MACHO_COMPATIBILITY_VERSION and MACHO_CURRENT_VERSION properties do not
    # reach the link when the link is driven by swiftc, so the flags are passed
    # directly.
    target_link_options(png16 PRIVATE
        "LINKER:-compatibility_version,${SPNG_MACHO_COMPATIBILITY_VERSION}"
        "LINKER:-current_version,${SPNG_MACHO_COMPATIBILITY_VERSION}")

    # Without this the Swift engine's symbols would also be exported, letting a
    # client bind to something outside the published API.
    target_link_options(png16 PRIVATE
        "LINKER:-exported_symbols_list,${SPNG_EXPORT_LIST}")

    target_link_libraries(png16 PRIVATE PNGABI)
else()
    target_link_options(png16 PRIVATE
        "LINKER:--version-script=${SPNG_VERSION_SCRIPT}")

    # The published entry points live in the boundary archive and nothing inside the
    # library calls them, so an ELF link would drop their objects as unreferenced —
    # ld64 resolves the export list from the archive, but GNU ld versions only what
    # is already in the link.  The whole archive is what the dynamic symbol table
    # is made from, and the version script then hides everything unpublished.
    #
    # The engine's archives follow *in these options* rather than through
    # target_link_libraries: the driver places linker options and libraries in
    # separate runs of the final command, and an archive scanned before the whole
    # archive raised its undefined references contributes nothing to them.
    target_link_options(png16 PRIVATE
        "LINKER:--whole-archive,$<TARGET_FILE:PNGABI>,--no-whole-archive"
        "LINKER:$<TARGET_FILE:PNG>"
        "LINKER:$<TARGET_FILE:Zlib>"
        "LINKER:$<TARGET_FILE:LZ77>")

    if(SPNG_STATIC_STDLIB)
        target_link_options(png16 PRIVATE -static-stdlib)
    endif()
endif()

# -- install -----------------------------------------------------------------
#
# The layout mirrors the reference build's, including the unversioned aliases,
# because build systems and pkg-config files in the wild look for those names.

set(SPNG_HEADER_SUBDIR ${CMAKE_INSTALL_INCLUDEDIR}/libpng${SPNG_ABI_SONAME})

install(TARGETS png16
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR})

install(FILES
    ${SPNG_INCLUDE_DIR}/png.h
    ${SPNG_INCLUDE_DIR}/pngconf.h
    ${SPNG_INCLUDE_DIR}/pnglibconf.h
    DESTINATION ${SPNG_HEADER_SUBDIR})

# Clients include either <png.h> or <libpng16/png.h>; both have to resolve.
install(CODE "
    execute_process(COMMAND \${CMAKE_COMMAND} -E create_symlink
        libpng${SPNG_ABI_SONAME}/png.h
        \$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_INCLUDEDIR}/png.h)
    execute_process(COMMAND \${CMAKE_COMMAND} -E create_symlink
        libpng${SPNG_ABI_SONAME}/pngconf.h
        \$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_INCLUDEDIR}/pngconf.h)
    execute_process(COMMAND \${CMAKE_COMMAND} -E create_symlink
        libpng${SPNG_ABI_SONAME}/pnglibconf.h
        \$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_INCLUDEDIR}/pnglibconf.h)
")

if(APPLE)
    set(SPNG_UNVERSIONED_ALIAS libpng${CMAKE_SHARED_LIBRARY_SUFFIX})
    set(SPNG_VERSIONED_TARGET libpng${SPNG_ABI_SONAME}${CMAKE_SHARED_LIBRARY_SUFFIX})
else()
    set(SPNG_UNVERSIONED_ALIAS libpng${CMAKE_SHARED_LIBRARY_SUFFIX})
    set(SPNG_VERSIONED_TARGET libpng${SPNG_ABI_SONAME}${CMAKE_SHARED_LIBRARY_SUFFIX})
endif()

install(CODE "
    execute_process(COMMAND \${CMAKE_COMMAND} -E create_symlink
        ${SPNG_VERSIONED_TARGET}
        \$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_LIBDIR}/${SPNG_UNVERSIONED_ALIAS})
")

# pkg-config is how most build systems find libpng, so shipping these is part of
# being a drop-in rather than a nicety.
configure_file(cmake/libpng16.pc.in
    ${CMAKE_CURRENT_BINARY_DIR}/libpng${SPNG_ABI_SONAME}.pc @ONLY)

install(FILES ${CMAKE_CURRENT_BINARY_DIR}/libpng${SPNG_ABI_SONAME}.pc
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/pkgconfig)

install(CODE "
    execute_process(COMMAND \${CMAKE_COMMAND} -E create_symlink
        libpng${SPNG_ABI_SONAME}.pc
        \$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_LIBDIR}/pkgconfig/libpng.pc)
")

# -- conformance -------------------------------------------------------------

if(SPNG_BUILD_TESTS)
    enable_testing()
    add_subdirectory(Conformance)
endif()
