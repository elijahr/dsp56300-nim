# Pre-generated C distribution integration for dsp56300.
#
# When Nim is not available, or when DSP56300_USE_C_DIST is set, this file
# defines the targets `dsp56300_nim_objs`, `dsp56300` and `dsp56300::dsp56300`
# directly from the pre-generated C translation units in `c_src/`.

if(APPLE)
	set(DSP56300_PLATFORM "macos")
elseif(WIN32 OR CMAKE_SYSTEM_NAME STREQUAL "Windows")
	set(DSP56300_PLATFORM "windows_x86_64")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
	set(DSP56300_PLATFORM "linux_x86_64")
else()
	message(FATAL_ERROR
		"dsp56300: pre-generated C distribution does not support ${CMAKE_SYSTEM_NAME}.\n"
		"Supported platforms: macos, linux_x86_64, windows_x86_64.")
endif()

set(DSP56300_C_DIST_DIR "${PROJECT_SOURCE_DIR}/c_src/${DSP56300_PLATFORM}")
set(DSP56300_C_COMMON_DIR "${PROJECT_SOURCE_DIR}/c_src/common")

if(NOT EXISTS "${DSP56300_C_DIST_DIR}" OR NOT EXISTS "${DSP56300_C_COMMON_DIR}/nimbase.h")
	message(FATAL_ERROR
		"dsp56300: C distribution for ${DSP56300_PLATFORM} was not found at ${DSP56300_C_DIST_DIR}.\n"
		"Run tools/generate_c_dist.sh to generate it.")
endif()

file(GLOB DSP56300_C_SOURCES CONFIGURE_DEPENDS "${DSP56300_C_DIST_DIR}/*.c")
if(DSP56300_C_SOURCES STREQUAL "")
	message(FATAL_ERROR
		"dsp56300: no C translation units found in ${DSP56300_C_DIST_DIR}.")
endif()

message(STATUS
	"dsp56300: using pre-generated C distribution for ${DSP56300_PLATFORM} from ${DSP56300_C_DIST_DIR}")

# ---------------------------------------------------------------------------
# The OBJECT library.
add_library(dsp56300_nim_objs OBJECT ${DSP56300_C_SOURCES})

target_include_directories(dsp56300_nim_objs SYSTEM PRIVATE
	"${DSP56300_C_COMMON_DIR}"
	"${DSP56300_C_DIST_DIR}")

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
# The static library.
add_library(dsp56300 STATIC $<TARGET_OBJECTS:dsp56300_nim_objs>)

target_include_directories(dsp56300 PUBLIC
	"$<BUILD_INTERFACE:${PROJECT_SOURCE_DIR}/include>")

if(TARGET Threads::Threads)
	target_link_libraries(dsp56300 PUBLIC Threads::Threads)
endif()

set_target_properties(dsp56300 PROPERTIES
	LINKER_LANGUAGE C)

# ---------------------------------------------------------------------------
# Exported alias for consumers.
add_library(dsp56300::dsp56300 ALIAS dsp56300)
