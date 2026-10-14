# CMake drives Nim for dsp56300.
#
# Integration steps:
#   1  Read .nim-version, run nim --version, verify match.
#   2  Run Nim compiler in compile-only mode with C backend.
#   3  Read compile-unit list from Nim's JSON build file.
#   4  Add listed .c files to an OBJECT library dsp56300_nim_objs.
#   5  Add STATIC library dsp56300 carrying objects and include/dsp56300.h.
#   6  Export dsp56300::dsp56300 alias for consumers.

find_program(DSP56300_NIM_EXECUTABLE nim REQUIRED
    DOC "The Nim compiler that builds the dsp56300 core")

set(DSP56300_NIM_VERSION_FILE "${PROJECT_SOURCE_DIR}/.nim-version")
if(NOT EXISTS "${DSP56300_NIM_VERSION_FILE}")
    message(FATAL_ERROR
        "dsp56300: step 1 failed: ${DSP56300_NIM_VERSION_FILE} does not exist.")
endif()

file(READ "${DSP56300_NIM_VERSION_FILE}" DSP56300_NIM_PIN_RAW)
string(STRIP "${DSP56300_NIM_PIN_RAW}" DSP56300_NIM_PIN)

execute_process(
    COMMAND "${DSP56300_NIM_EXECUTABLE}" --version
    OUTPUT_VARIABLE DSP56300_NIM_VERSION_OUTPUT
    ERROR_VARIABLE DSP56300_NIM_VERSION_ERROR
    RESULT_VARIABLE DSP56300_NIM_VERSION_RESULT)

if(NOT DSP56300_NIM_VERSION_RESULT EQUAL 0)
    message(FATAL_ERROR
        "dsp56300: step 1 failed: `${DSP56300_NIM_EXECUTABLE} --version` exited ${DSP56300_NIM_VERSION_RESULT}.\n"
        "  stdout : ${DSP56300_NIM_VERSION_OUTPUT}\n"
        "  stderr : ${DSP56300_NIM_VERSION_ERROR}")
endif()

string(REGEX REPLACE "\r?\n.*" "" DSP56300_NIM_VERSION_FIRST_LINE
    "${DSP56300_NIM_VERSION_OUTPUT}")

if(NOT DSP56300_NIM_VERSION_FIRST_LINE MATCHES "Version[ \t]+([0-9]+\\.[0-9]+\\.[0-9]+)")
    message(FATAL_ERROR
        "dsp56300: step 1 failed: no version number found in `${DSP56300_NIM_EXECUTABLE} --version`.")
endif()
set(DSP56300_NIM_INSTALLED "${CMAKE_MATCH_1}")

if(NOT DSP56300_NIM_INSTALLED STREQUAL DSP56300_NIM_PIN)
    message(FATAL_ERROR
        "dsp56300: step 1 failed: Nim version does not match pin.\n"
        "  pinned    : ${DSP56300_NIM_PIN} (from ${DSP56300_NIM_VERSION_FILE})\n"
        "  installed : ${DSP56300_NIM_INSTALLED} (from ${DSP56300_NIM_EXECUTABLE})")
endif()

message(STATUS "dsp56300: step 1 Nim version matches pin: ${DSP56300_NIM_PIN}")

# ---------------------------------------------------------------------------
# Step 2. Compile-only run of C backend.

set(DSP56300_NIMCACHE "${PROJECT_BINARY_DIR}/nimcache")
set(DSP56300_NIM_HEADER "dsp56300_nim.h")
set(DSP56300_NIM_FLAGS --mm:arc --panics:on -d:release)

if(CMAKE_C_COMPILER_ID STREQUAL "MSVC")
    set(DSP56300_NIM_CC vcc)
elseif(CMAKE_C_COMPILER_ID MATCHES "^(Clang|AppleClang|IntelLLVM|ARMClang)$")
    set(DSP56300_NIM_CC clang)
elseif(CMAKE_C_COMPILER_ID STREQUAL "GNU")
    set(DSP56300_NIM_CC gcc)
else()
    set(DSP56300_NIM_CC "")
endif()

if(NOT DSP56300_NIM_CC STREQUAL "")
    list(APPEND DSP56300_NIM_FLAGS "--cc:${DSP56300_NIM_CC}")
endif()

set(DSP56300_NIM_SOURCE "${PROJECT_SOURCE_DIR}/src/dsp56300.nim")
set(DSP56300_NIM_PATH "${PROJECT_SOURCE_DIR}/src")

set(DSP56300_NIM_COMMAND
    "${DSP56300_NIM_EXECUTABLE}" c
    --compileOnly
    --noMain
    "--nimcache:${DSP56300_NIMCACHE}"
    "--path:${DSP56300_NIM_PATH}"
    ${DSP56300_NIM_FLAGS}
    --nimMainPrefix:dsp56300_
    "--header:${DSP56300_NIM_HEADER}"
    "${DSP56300_NIM_SOURCE}")

execute_process(
    COMMAND ${DSP56300_NIM_COMMAND}
    WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}"
    OUTPUT_VARIABLE DSP56300_NIM_OUTPUT
    ERROR_VARIABLE DSP56300_NIM_ERROR
    RESULT_VARIABLE DSP56300_NIM_RESULT)

if(NOT DSP56300_NIM_RESULT EQUAL 0)
    message(FATAL_ERROR
        "dsp56300: step 2 failed: Nim compiler exited ${DSP56300_NIM_RESULT}.\n"
        "${DSP56300_NIM_OUTPUT}\n${DSP56300_NIM_ERROR}")
endif()

message(STATUS "dsp56300: step 2 Nim compile-only run succeeded")

# ---------------------------------------------------------------------------
# Step 3. Compile-unit list from JSON.

set(DSP56300_NIM_JSON "${DSP56300_NIMCACHE}/dsp56300.json")
if(NOT EXISTS "${DSP56300_NIM_JSON}")
    message(FATAL_ERROR "dsp56300: step 3 failed: ${DSP56300_NIM_JSON} not found.")
endif()

file(READ "${DSP56300_NIM_JSON}" DSP56300_NIM_JSON_TEXT)
string(JSON DSP56300_NIM_UNIT_COUNT LENGTH "${DSP56300_NIM_JSON_TEXT}" compile)

set(DSP56300_NIM_C_SOURCES "")
math(EXPR DSP56300_NIM_LAST_UNIT "${DSP56300_NIM_UNIT_COUNT} - 1")
foreach(index RANGE ${DSP56300_NIM_LAST_UNIT})
    string(JSON DSP56300_NIM_UNIT GET "${DSP56300_NIM_JSON_TEXT}" compile ${index} 0)
    file(TO_CMAKE_PATH "${DSP56300_NIM_UNIT}" DSP56300_NIM_UNIT)
    list(APPEND DSP56300_NIM_C_SOURCES "${DSP56300_NIM_UNIT}")
endforeach()

message(STATUS "dsp56300: step 3 read ${DSP56300_NIM_UNIT_COUNT} compile units")

# ---------------------------------------------------------------------------
# Step 4. Locate nimbase.h and build OBJECT library.

execute_process(
    COMMAND "${DSP56300_NIM_EXECUTABLE}" dump --dump.format:json "${DSP56300_NIM_SOURCE}"
    OUTPUT_VARIABLE DSP56300_NIM_DUMP_OUTPUT
    ERROR_VARIABLE DSP56300_NIM_DUMP_ERROR
    RESULT_VARIABLE DSP56300_NIM_DUMP_RESULT)

set(DSP56300_NIM_LIB_DIR "")
if(DSP56300_NIM_DUMP_RESULT EQUAL 0)
    string(JSON DSP56300_NIM_DUMP_LIBPATH
        ERROR_VARIABLE DSP56300_NIM_DUMP_JSON_ERROR
        GET "${DSP56300_NIM_DUMP_OUTPUT}" libpath)
    if(DSP56300_NIM_DUMP_JSON_ERROR STREQUAL "NOTFOUND" AND NOT DSP56300_NIM_DUMP_LIBPATH STREQUAL "")
        file(TO_CMAKE_PATH "${DSP56300_NIM_DUMP_LIBPATH}" DSP56300_NIM_LIB_DIR)
    endif()
endif()

if(DSP56300_NIM_LIB_DIR STREQUAL "" OR NOT EXISTS "${DSP56300_NIM_LIB_DIR}/nimbase.h")
    get_filename_component(DSP56300_NIM_REAL "${DSP56300_NIM_EXECUTABLE}" REALPATH)
    get_filename_component(DSP56300_NIM_BIN "${DSP56300_NIM_REAL}" DIRECTORY)
    get_filename_component(DSP56300_NIM_PREFIX "${DSP56300_NIM_BIN}" DIRECTORY)
    if(EXISTS "${DSP56300_NIM_PREFIX}/lib/nimbase.h")
        set(DSP56300_NIM_LIB_DIR "${DSP56300_NIM_PREFIX}/lib")
    endif()
endif()

if(DSP56300_NIM_LIB_DIR STREQUAL "" OR NOT EXISTS "${DSP56300_NIM_LIB_DIR}/nimbase.h")
    message(FATAL_ERROR "dsp56300: step 4 failed: nimbase.h was not found.")
endif()

message(STATUS "dsp56300: step 4 Nim library directory: ${DSP56300_NIM_LIB_DIR}")

add_library(dsp56300_nim_objs OBJECT ${DSP56300_NIM_C_SOURCES})

target_include_directories(dsp56300_nim_objs SYSTEM PRIVATE
    "${DSP56300_NIM_LIB_DIR}")

target_compile_options(dsp56300_nim_objs PRIVATE
    "$<IF:$<C_COMPILER_ID:MSVC>,/WX-,-Wno-error>")

set_target_properties(dsp56300_nim_objs PROPERTIES
    C_STANDARD 11
    POSITION_INDEPENDENT_CODE ON)

set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads)
if(TARGET Threads::Threads)
    target_link_libraries(dsp56300_nim_objs PUBLIC Threads::Threads)
endif()

# ---------------------------------------------------------------------------
# Step 5. Static library dsp56300.

add_library(dsp56300 STATIC $<TARGET_OBJECTS:dsp56300_nim_objs>)

target_include_directories(dsp56300 PUBLIC
    "$<BUILD_INTERFACE:${PROJECT_SOURCE_DIR}/include>")

if(TARGET Threads::Threads)
    target_link_libraries(dsp56300 PUBLIC Threads::Threads)
endif()

set_target_properties(dsp56300 PROPERTIES
    LINKER_LANGUAGE C)

# ---------------------------------------------------------------------------
# Step 6. Exported alias.
add_library(dsp56300::dsp56300 ALIAS dsp56300)
