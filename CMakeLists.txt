cmake_minimum_required(VERSION 3.26)

project(dsp56300
    VERSION 0.1.0
    DESCRIPTION "Clean-room MIT Motorola DSP56300 / DSP56311 CPU core"
    LANGUAGES C CXX)

enable_testing()

option(DSP56300_USE_C_DIST
    "Compile libdsp56300 directly from pre-generated C distribution" OFF)

find_program(DSP56300_NIM_EXECUTABLE nim
    DOC "The Nim compiler that builds the dsp56300 core")

if(DSP56300_USE_C_DIST OR NOT DSP56300_NIM_EXECUTABLE)
    if(NOT DSP56300_NIM_EXECUTABLE AND NOT DSP56300_USE_C_DIST)
        message(STATUS
            "dsp56300: Nim compiler not found; falling back to pre-generated C distribution")
    endif()
    include(cmake/CDist.cmake)
else()
    include(cmake/Nim.cmake)
endif()

add_subdirectory(tests)
