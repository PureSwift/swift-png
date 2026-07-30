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
    message(STATUS
        "Reference libpng library not found; probe expectations will not be cross-checked")
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

    add_test(NAME differential_decode
        COMMAND ${SPNG_SCRIPTS}/compare_decode.sh
                $<TARGET_FILE:pngdump>
                $<TARGET_FILE:pngdump_reference>
                ${SPNG_CORPUS})
endif()
