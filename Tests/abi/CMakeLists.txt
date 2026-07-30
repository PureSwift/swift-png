# Conformance programs.
#
# These are C programs, deliberately.  The claim being tested is that a C client
# built for libpng works against this library, and only a C client can test that.

set(SPNG_SCRIPTS ${CMAKE_CURRENT_SOURCE_DIR}/../../scripts)

# Asserts the dynamic symbol table matches the published API exactly: nothing
# missing, and nothing internal exposed.
add_test(NAME abi_exports
    COMMAND ${SPNG_SCRIPTS}/check_exports.sh
            $<TARGET_FILE:png16>
            ${SPNG_SCRIPTS}/symbols.txt)

# The committed generated sources have to match what the generators produce from
# the current header and implementation manifest, otherwise the export check
# above is comparing against a stale expectation.
add_test(NAME generated_sources
    COMMAND ${SPNG_SCRIPTS}/check_generated.sh)

# Where to find the reference libpng headers.  Compiling the conformance
# programs against those rather than our own copy is what makes them a test of
# substitutability instead of a test of internal consistency.  pkg-config is
# asked rather than the filesystem searched, because several unrelated
# frameworks ship a bundled png.h that would otherwise be picked up.
find_package(PkgConfig)

if(PkgConfig_FOUND AND NOT DEFINED SPNG_REFERENCE_INCLUDE_DIR)
    pkg_check_modules(SPNG_REFERENCE QUIET libpng16)

    if(SPNG_REFERENCE_FOUND AND SPNG_REFERENCE_INCLUDE_DIRS)
        list(GET SPNG_REFERENCE_INCLUDE_DIRS 0 SPNG_REFERENCE_INCLUDE_DIR)
    endif()
endif()

set(SPNG_REFERENCE_INCLUDE_DIR "${SPNG_REFERENCE_INCLUDE_DIR}" CACHE PATH
    "Reference libpng headers, used to prove clients need no changes")

add_executable(version_probe version_probe.c)
target_link_libraries(version_probe PRIVATE png16)

if(SPNG_REFERENCE_INCLUDE_DIR AND EXISTS ${SPNG_REFERENCE_INCLUDE_DIR}/png.h)
    # Ahead of our own include directory, so these declarations win.
    target_include_directories(version_probe BEFORE PRIVATE
        ${SPNG_REFERENCE_INCLUDE_DIR})
    message(STATUS
        "Conformance programs compile against the reference headers in ${SPNG_REFERENCE_INCLUDE_DIR}")
else()
    message(STATUS
        "Reference libpng headers not found; conformance programs compile against the vendored copy")
endif()

add_test(NAME version_probe COMMAND version_probe)

# The same program, linked against the reference library instead of ours.
#
# A conformance program is only as good as its expectations, and an expectation
# written from memory rather than from observation is worse than no test: it
# passes against us and enshrines behaviour the reference never had.  Running the
# identical source against the reference is what rules that out, so every check
# added to a probe has to hold for both libraries.
if(SPNG_REFERENCE_FOUND AND SPNG_REFERENCE_LINK_LIBRARIES)
    add_executable(version_probe_reference version_probe.c)
    target_include_directories(version_probe_reference BEFORE PRIVATE
        ${SPNG_REFERENCE_INCLUDE_DIRS})
    target_link_libraries(version_probe_reference PRIVATE
        ${SPNG_REFERENCE_LINK_LIBRARIES})

    add_test(NAME version_probe_reference COMMAND version_probe_reference)
else()
    message(STATUS
        "Reference libpng library not found; probe expectations will not be cross-checked")
endif()
