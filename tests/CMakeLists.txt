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
        add_dsp56300_nim_test(t0_dma t0_dma.nim
            "${PROJECT_SOURCE_DIR}/src/dsp56300/peripherals/dma.nim"
        )
    endif()

    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/t0_esai.nim")
        add_dsp56300_nim_test(t0_esai t0_esai.nim
            "${PROJECT_SOURCE_DIR}/src/dsp56300/peripherals/esai.nim"
        )
    endif()

    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/t0_hdi08.nim")
        add_dsp56300_nim_test(t0_hdi08 t0_hdi08.nim
            "${PROJECT_SOURCE_DIR}/src/dsp56300/peripherals/hdi08.nim"
        )
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

    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/t0_jit_x86_64.nim")
        add_dsp56300_nim_test(t0_jit_x86_64 t0_jit_x86_64.nim)
    endif()

    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/t0_wasm_v8_exec.nim")
        add_dsp56300_nim_test(t0_wasm_v8_exec t0_wasm_v8_exec.nim)
    endif()

    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/t0_peripherals_integration.nim")
        add_dsp56300_nim_test(t0_peripherals_integration t0_peripherals_integration.nim
            "${PROJECT_SOURCE_DIR}/src/dsp56300/peripherals/peripherals56311.nim"
            "${PROJECT_SOURCE_DIR}/src/dsp56300/peripherals/hdi08.nim"
            "${PROJECT_SOURCE_DIR}/src/dsp56300/peripherals/esai.nim"
            "${PROJECT_SOURCE_DIR}/src/dsp56300/peripherals/dma.nim"
            "${PROJECT_SOURCE_DIR}/src/dsp56300/peripherals/timers.nim"
        )
    endif()

    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/t0_timers.nim")
        add_dsp56300_nim_test(t0_timers t0_timers.nim
            "${PROJECT_SOURCE_DIR}/src/dsp56300/peripherals/timers.nim"
        )
    endif()

    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/t0_asm_roundtrip.nim")
        add_dsp56300_nim_test(t0_asm_roundtrip t0_asm_roundtrip.nim
            "${PROJECT_SOURCE_DIR}/src/dsp56300/asm.nim"
            "${PROJECT_SOURCE_DIR}/src/dsp56300/decode.nim"
            "${PROJECT_SOURCE_DIR}/src/dsp56300/ir.nim"
            "${PROJECT_SOURCE_DIR}/src/dsp56300/runner.nim"
        )
    endif()

    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/t0_asm_file_assembler.nim")
        add_dsp56300_nim_test(t0_asm_file_assembler t0_asm_file_assembler.nim
            "${PROJECT_SOURCE_DIR}/src/dsp56300/asm.nim"
            "${PROJECT_SOURCE_DIR}/src/dsp56300/asm_parser.nim"
            "${PROJECT_SOURCE_DIR}/src/dsp56300/decode.nim"
            "${PROJECT_SOURCE_DIR}/src/dsp56300/ir.nim"
            "${PROJECT_SOURCE_DIR}/src/dsp56300/runner.nim"
        )
    endif()

endif()

add_custom_target(dsp56300_tests ALL DEPENDS ${ALL_TEST_TARGETS})
