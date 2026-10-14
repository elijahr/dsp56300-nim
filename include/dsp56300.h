/* dsp56300.h - Canonical C11 application binary interface for the Motorola
 * DSP56300 / DSP56311 digital signal processor emulator.
 *
 * Clean-room MIT implementation derived from the Motorola DSP56300 Family
 * Manual (DSP56300FM) and DSP56311 User's Manual (DSP56311UM).
 *
 * What crosses: fixed-width integers, opaque context pointers, C function
 * pointers with explicit parameters.
 * What never crosses: Nim runtime internals or GC pointers.
 */

#ifndef DSP56300_H
#define DSP56300_H

#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus) && __cplusplus >= 201703L
#  define DSP56300_MUST_USE [[nodiscard]]
#elif !defined(__cplusplus) && defined(__STDC_VERSION__) && \
      __STDC_VERSION__ >= 202311L
#  define DSP56300_MUST_USE [[nodiscard]]
#elif defined(__GNUC__) || defined(__clang__)
#  define DSP56300_MUST_USE __attribute__((warn_unused_result))
#else
#  define DSP56300_MUST_USE
#endif

#if defined(__GNUC__) || defined(__clang__)
#  define DSP56300_MUST_CHECK __attribute__((warn_unused_result))
#else
#  define DSP56300_MUST_CHECK
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ----------------------------------------------------------- Core context */

typedef struct dsp56300_ctx dsp56300_ctx;

/* ----------------------------------------------------------- Memory space */

typedef enum {
	DSP56300_SPACE_X = 0,
	DSP56300_SPACE_Y = 1,
	DSP56300_SPACE_P = 2
} dsp56300_space;

/* Memory read / write callbacks (24-bit words) */
typedef uint32_t (*dsp56300_mem_read_fn)(void* user, int space, uint32_t addr);
typedef void (*dsp56300_mem_write_fn)(void* user, int space, uint32_t addr, uint32_t val);

/* ----------------------------------------------------------- Configuration */

typedef struct dsp56300_config {
	void* user;
	dsp56300_mem_read_fn rd;
	dsp56300_mem_write_fn wr;
	uint32_t omr_init;
} dsp56300_config;

/* ------------------------------------------------------- Register indexing */

enum {
	/* Data ALU Input Registers (24-bit) */
	DSP56300_REG_X0   = 0,
	DSP56300_REG_X1   = 1,
	DSP56300_REG_Y0   = 2,
	DSP56300_REG_Y1   = 3,
	DSP56300_REG_X    = 4,  /* X1:X0 (48-bit) */
	DSP56300_REG_Y    = 5,  /* Y1:Y0 (48-bit) */

	/* Data ALU Accumulator Registers */
	DSP56300_REG_A0   = 6,  /* 24-bit LSP */
	DSP56300_REG_A1   = 7,  /* 24-bit MSP */
	DSP56300_REG_A2   = 8,  /* 8-bit EXT */
	DSP56300_REG_A10  = 9,  /* A1:A0 (48-bit) */
	DSP56300_REG_A    = 10, /* A2:A1:A0 (56-bit signed) */

	DSP56300_REG_B0   = 11,
	DSP56300_REG_B1   = 12,
	DSP56300_REG_B2   = 13,
	DSP56300_REG_B10  = 14,
	DSP56300_REG_B    = 15,

	/* Address Generation Unit (AGU) Registers (24-bit) */
	DSP56300_REG_R0   = 16,
	DSP56300_REG_R1   = 17,
	DSP56300_REG_R2   = 18,
	DSP56300_REG_R3   = 19,
	DSP56300_REG_R4   = 20,
	DSP56300_REG_R5   = 21,
	DSP56300_REG_R6   = 22,
	DSP56300_REG_R7   = 23,

	DSP56300_REG_N0   = 24,
	DSP56300_REG_N1   = 25,
	DSP56300_REG_N2   = 26,
	DSP56300_REG_N3   = 27,
	DSP56300_REG_N4   = 28,
	DSP56300_REG_N5   = 29,
	DSP56300_REG_N6   = 30,
	DSP56300_REG_N7   = 31,

	DSP56300_REG_M0   = 32,
	DSP56300_REG_M1   = 33,
	DSP56300_REG_M2   = 34,
	DSP56300_REG_M3   = 35,
	DSP56300_REG_M4   = 36,
	DSP56300_REG_M5   = 37,
	DSP56300_REG_M6   = 38,
	DSP56300_REG_M7   = 39,

	/* Program Control Unit (PCU) Registers (24-bit) */
	DSP56300_REG_PC   = 40,
	DSP56300_REG_SR   = 41,
	DSP56300_REG_OMR  = 42,
	DSP56300_REG_LA   = 43,
	DSP56300_REG_LC   = 44,
	DSP56300_REG_SP   = 45,
	DSP56300_REG_SSH  = 46,
	DSP56300_REG_SSL  = 47,
	DSP56300_REG_VBA  = 48,
	DSP56300_REG_EP   = 49,
	DSP56300_REG_SZ   = 50,
	DSP56300_REG_SC   = 51
};

/* ------------------------------------------------------------- Primary ABI */

DSP56300_MUST_CHECK int dsp56300_runtime_init(void);

dsp56300_ctx* dsp56300_create(const dsp56300_config* config);
void dsp56300_destroy(dsp56300_ctx* ctx);
void dsp56300_reset(dsp56300_ctx* ctx);

uint32_t dsp56300_exec(dsp56300_ctx* ctx, uint32_t max_cycles);

int dsp56300_set_reg(dsp56300_ctx* ctx, int reg_index, uint64_t value);
int dsp56300_get_reg(const dsp56300_ctx* ctx, int reg_index, uint64_t* value);

uint32_t dsp56300_mem_read(dsp56300_ctx* ctx, int space, uint32_t addr);
void dsp56300_mem_write(dsp56300_ctx* ctx, int space, uint32_t addr, uint32_t val);

int dsp56300_register_peripheral(dsp56300_ctx* ctx, int space, uint32_t base_addr,
                                uint32_t size, dsp56300_mem_read_fn rd,
                                dsp56300_mem_write_fn wr, void* user);

int dsp56300_halted(const dsp56300_ctx* ctx);

size_t dsp56300_state_size(void);
void dsp56300_state_save(const dsp56300_ctx* ctx, void* dst);
void dsp56300_state_load(dsp56300_ctx* ctx, const void* src);

/* ------------------------------------- DSP56311 Peripherals Subsystem ABI */

typedef struct dsp56311_peripherals dsp56311_peripherals;

dsp56311_peripherals* dsp56311_peripherals_create(void);
void dsp56311_peripherals_destroy(dsp56311_peripherals* peri);
void dsp56311_peripherals_reset(dsp56311_peripherals* peri);

uint32_t dsp56311_peripherals_read_x(dsp56311_peripherals* peri, uint32_t addr);
void dsp56311_peripherals_write_x(dsp56311_peripherals* peri, uint32_t addr, uint32_t val);

uint32_t dsp56311_peripherals_read_y(dsp56311_peripherals* peri, uint32_t addr);
void dsp56311_peripherals_write_y(dsp56311_peripherals* peri, uint32_t addr, uint32_t val);

uint8_t dsp56311_peripherals_host_read8(dsp56311_peripherals* peri, uint8_t reg_offset);
void dsp56311_peripherals_host_write8(dsp56311_peripherals* peri, uint8_t reg_offset, uint8_t val);

void dsp56311_peripherals_step(dsp56311_peripherals* peri, uint32_t cycles);

#ifdef __cplusplus
}
#endif

#endif /* DSP56300_H */
