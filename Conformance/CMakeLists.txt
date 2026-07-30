# Conformance programs.
#
# These are C programs, deliberately.  The claim being tested is that a C client
# built for libpng works against this library, and only a C client can test that.

set(SPNG_SCRIPTS ${CMAKE_CURRENT_SOURCE_DIR}/../scripts)

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

# Asked on every configure, not only the first.  Gating this on whether the include
# directory was already known would skip it as soon as that variable was cached, and the
# comparison targets below would quietly cease to exist — leaving a suite that reports
# success while comparing nothing.
if(PkgConfig_FOUND)
    pkg_check_modules(SPNG_REFERENCE QUIET libpng16)
endif()

# An explicit setting wins, for a reference build that pkg-config does not know about.
if(NOT SPNG_REFERENCE_INCLUDE_DIR AND SPNG_REFERENCE_INCLUDE_DIRS)
    list(GET SPNG_REFERENCE_INCLUDE_DIRS 0 SPNG_REFERENCE_INCLUDE_DIR)
endif()

set(SPNG_REFERENCE_INCLUDE_DIR "${SPNG_REFERENCE_INCLUDE_DIR}" CACHE PATH
    "Reference libpng headers, used to prove clients need no changes" FORCE)

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

add_test(NAME version_probe COMMAND $<TARGET_FILE:version_probe>)

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

    add_test(NAME version_probe_reference COMMAND $<TARGET_FILE:version_probe_reference>)
else()
    message(WARNING
        "Reference libpng not found: the differential comparison, which is the primary "
        "correctness check, will not run")
endif()

# -- the differential decode ------------------------------------------------
#
# The primary correctness check.  One program, compiled twice, run over the corpus;
# any difference in what the two libraries report is a defect here.  It needs both
# libraries, so it is skipped when the reference is absent.

add_executable(pngdump pngdump.c)
target_link_libraries(pngdump PRIVATE png16)

if(SPNG_REFERENCE_INCLUDE_DIR AND EXISTS ${SPNG_REFERENCE_INCLUDE_DIR}/png.h)
    target_include_directories(pngdump BEFORE PRIVATE ${SPNG_REFERENCE_INCLUDE_DIR})
endif()

if(SPNG_REFERENCE_FOUND AND SPNG_REFERENCE_LINK_LIBRARIES)
    add_executable(pngdump_reference pngdump.c)
    target_include_directories(pngdump_reference BEFORE PRIVATE
        ${SPNG_REFERENCE_INCLUDE_DIRS})
    target_link_libraries(pngdump_reference PRIVATE ${SPNG_REFERENCE_LINK_LIBRARIES})

    # Generated into the build tree rather than checked in, so the awkward cases
    # are described by the script that makes them rather than by opaque binaries.
    set(SPNG_CORPUS ${CMAKE_CURRENT_BINARY_DIR}/corpus)

    add_custom_command(
        OUTPUT ${SPNG_CORPUS}/.stamp
        COMMAND ${Python3_EXECUTABLE} ${SPNG_SCRIPTS}/make_corpus.py ${SPNG_CORPUS}
        COMMAND ${CMAKE_COMMAND} -E touch ${SPNG_CORPUS}/.stamp
        DEPENDS ${SPNG_SCRIPTS}/make_corpus.py
        COMMENT "Generating the test corpus")

    add_custom_target(spng_corpus DEPENDS ${SPNG_CORPUS}/.stamp)
    add_dependencies(pngdump spng_corpus)

    # The setters, which the decode comparison never reaches: a decoded file arrives through
    # the parsers, never through png_set_gAMA and its neighbours.
    add_executable(metadata_roundtrip metadata_roundtrip.c)
    target_link_libraries(metadata_roundtrip PRIVATE png16)

    add_executable(metadata_roundtrip_reference metadata_roundtrip.c)
    target_include_directories(metadata_roundtrip_reference BEFORE PRIVATE
        ${SPNG_REFERENCE_INCLUDE_DIRS})
    target_link_libraries(metadata_roundtrip_reference PRIVATE
        ${SPNG_REFERENCE_LINK_LIBRARIES})

    if(SPNG_REFERENCE_INCLUDE_DIR AND EXISTS ${SPNG_REFERENCE_INCLUDE_DIR}/png.h)
        target_include_directories(metadata_roundtrip BEFORE PRIVATE
            ${SPNG_REFERENCE_INCLUDE_DIR})
    endif()

    add_test(NAME metadata_roundtrip
        COMMAND ${SPNG_SCRIPTS}/compare_output.sh
                $<TARGET_FILE:metadata_roundtrip>
                $<TARGET_FILE:metadata_roundtrip_reference>)

    # The transforms, over combinations rather than one at a time: the interesting defects are in
    # the interactions, and in whether the order the client asked in leaks into the result.
    add_test(NAME differential_transforms
        COMMAND ${SPNG_SCRIPTS}/compare_transforms.sh
                $<TARGET_FILE:pngdump>
                $<TARGET_FILE:pngdump_reference>
                ${SPNG_CORPUS}
                ${CMAKE_CURRENT_SOURCE_DIR}/known-transform-differences.txt)

    add_test(NAME differential_decode
        COMMAND ${SPNG_SCRIPTS}/compare_decode.sh
                $<TARGET_FILE:pngdump>
                $<TARGET_FILE:pngdump_reference>
                ${SPNG_CORPUS}
                ${CMAKE_CURRENT_SOURCE_DIR}/known-differences.txt)
endif()
