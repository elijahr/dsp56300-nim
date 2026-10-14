# tests/CMakeLists.txt - Clean-room MIT test suite for dsp56300

# 1. Canonical C11 ABI test
add_executable(t0_abi t0_abi.c)
target_include_directories(t0_abi PRIVATE "${PROJECT_SOURCE_DIR}/include")
target_link_libraries(t0_abi PRIVATE dsp56300)
set_target_properties(t0_abi PROPERTIES C_STANDARD 11)

add_test(NAME t0_abi COMMAND t0_abi)

set(ALL_TEST_TARGETS t0_abi)

# 2. Nim Unit Tests
if(DSP56300_NIM_EXECUTABLE AND NOT DSP56300_USE_C_DIST)
    macro(add_dsp56300_nim_test name source_file)
        add_custom_command(
            OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/${name}"
            COMMAND "${DSP56300_NIM_EXECUTABLE}" c
                    "--path:${PROJECT_SOURCE_DIR}/src"
                    --mm:arc --panics:on -d:release
                    "-o:${CMAKE_CURRENT_BINARY_DIR}/${name}"
                    "${CMAKE_CURRENT_SOURCE_DIR}/${source_file}"
            DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/${source_file}" ${ARGN}
            COMMENT "Compiling ${name} test"
        )
        add_custom_target("build_${name}" DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/${name}")
        add_test(NAME "${name}" COMMAND "${CMAKE_CURRENT_BINARY_DIR}/${name}")
        list(APPEND ALL_TEST_TARGETS "build_${name}")
    endmacro()

    add_dsp56300_nim_test(t0_alu t0_alu.nim
        "${PROJECT_SOURCE_DIR}/src/dsp56300/state.nim"
        "${PROJECT_SOURCE_DIR}/src/dsp56300/alu.nim"
    )

    add_dsp56300_nim_test(t0_agu t0_agu.nim
        "${PROJECT_SOURCE_DIR}/src/dsp56300/state.nim"
        "${PROJECT_SOURCE_DIR}/src/dsp56300/agu.nim"
    )

    add_dsp56300_nim_test(t0_loops t0_loops.nim
        "${PROJECT_SOURCE_DIR}/src/dsp56300/state.nim"
        "${PROJECT_SOURCE_DIR}/src/dsp56300/loops.nim"
    )

    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/t0_decode.nim")
        add_dsp56300_nim_test(t0_decode t0_decode.nim)
    endif()

    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/t0_dma.nim")
        add_dsp56300_nim_test(t0_dma t0_dma.nim)
    endif()

    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/t0_esai.nim")
        add_dsp56300_nim_test(t0_esai t0_esai.nim)
    endif()

    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/t0_hdi08.nim")
        add_dsp56300_nim_test(t0_hdi08 t0_hdi08.nim)
    endif()

    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/t0_ir_runner.nim")
        add_dsp56300_nim_test(t0_ir_runner t0_ir_runner.nim)
    endif()

    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/t0_jit_native.nim")
        add_dsp56300_nim_test(t0_jit_native t0_jit_native.nim)
    endif()

    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/t0_jit_wasm.nim")
        add_dsp56300_nim_test(t0_jit_wasm t0_jit_wasm.nim)
    endif()

    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/t0_kernel_differential.nim")
        add_dsp56300_nim_test(t0_kernel_differential t0_kernel_differential.nim)
    endif()

    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/t0_peripherals_integration.nim")
        add_dsp56300_nim_test(t0_peripherals_integration t0_peripherals_integration.nim)
    endif()

    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/t0_timers.nim")
        add_dsp56300_nim_test(t0_timers t0_timers.nim)
    endif()

endif()

add_custom_target(dsp56300_tests ALL DEPENDS ${ALL_TEST_TARGETS})
