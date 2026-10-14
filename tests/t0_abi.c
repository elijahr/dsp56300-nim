/* t0_abi.c - Clean-room C11 test verifying dsp56300.h canonical ABI */

#include "dsp56300.h"
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <string.h>

static uint32_t s_mock_hcr = 0;

static uint32_t mock_peripheral_read(void* user, int space, uint32_t address) {
	(void)user;
	(void)space;
	if (address == 0xFFFFC2) {
		return s_mock_hcr;
	}
	return 0;
}

static void mock_peripheral_write(void* user, int space, uint32_t address, uint32_t val) {
	(void)user;
	(void)space;
	if (address == 0xFFFFC2) {
		s_mock_hcr = val;
	}
}

int main(void) {
	printf("[TEST] DSP56300 C11 Canonical ABI verification\n");

	int init_res = dsp56300_runtime_init();
	assert(init_res == 0);

	dsp56300_config config;
	memset(&config, 0, sizeof(config));
	config.omr_init = 0;

	dsp56300_ctx* ctx = dsp56300_create(&config);
	assert(ctx != NULL);

	/* 1. Register get/set */
	int rc;
	uint64_t val = 0;

	/* X0 */
	rc = dsp56300_set_reg(ctx, DSP56300_REG_X0, 0x123456);
	assert(rc == 0);
	rc = dsp56300_get_reg(ctx, DSP56300_REG_X0, &val);
	assert(rc == 0);
	assert(val == 0x123456);

	/* 56-bit Accumulator A */
	rc = dsp56300_set_reg(ctx, DSP56300_REG_A, 0x00123456789ABCULL);
	assert(rc == 0);
	rc = dsp56300_get_reg(ctx, DSP56300_REG_A, &val);
	assert(rc == 0);
	assert(val == 0x00123456789ABCULL);

	/* AGU R0 */
	rc = dsp56300_set_reg(ctx, DSP56300_REG_R0, 0x004000);
	assert(rc == 0);
	rc = dsp56300_get_reg(ctx, DSP56300_REG_R0, &val);
	assert(rc == 0);
	assert(val == 0x004000);

	/* PC & SR */
	rc = dsp56300_set_reg(ctx, DSP56300_REG_PC, 0x000100);
	assert(rc == 0);
	rc = dsp56300_get_reg(ctx, DSP56300_REG_PC, &val);
	assert(rc == 0);
	assert(val == 0x000100);

	rc = dsp56300_get_reg(ctx, DSP56300_REG_SR, &val);
	assert(rc == 0);
	/* Reset SR should have CP1=1, CP0=1, I1=1, I0=1 -> 0xC00300 */
	assert((val & 0xC00300) == 0xC00300);

	/* 2. Memory read / write for X, Y, and P spaces */
	dsp56300_mem_write(ctx, DSP56300_SPACE_P, 0x000100, 0x60F800);
	uint32_t p_val = dsp56300_mem_read(ctx, DSP56300_SPACE_P, 0x000100);
	assert(p_val == 0x60F800);

	dsp56300_mem_write(ctx, DSP56300_SPACE_X, 0x000500, 0x112233);
	uint32_t x_val = dsp56300_mem_read(ctx, DSP56300_SPACE_X, 0x000500);
	assert(x_val == 0x112233);

	dsp56300_mem_write(ctx, DSP56300_SPACE_Y, 0x000600, 0x445566);
	uint32_t y_val = dsp56300_mem_read(ctx, DSP56300_SPACE_Y, 0x000600);
	assert(y_val == 0x445566);

	/* 3. Peripheral Hook Registration */
	rc = dsp56300_register_peripheral(ctx, DSP56300_SPACE_X, 0xFFFFC2, 1,
	                                 mock_peripheral_read, mock_peripheral_write, NULL);
	assert(rc == 0);

	dsp56300_mem_write(ctx, DSP56300_SPACE_X, 0xFFFFC2, 0x000007);
	assert(s_mock_hcr == 0x000007);
	uint32_t hook_read = dsp56300_mem_read(ctx, DSP56300_SPACE_X, 0xFFFFC2);
	assert(hook_read == 0x000007);

	/* 4. State serialization */
	size_t state_sz = dsp56300_state_size();
	assert(state_sz > 0);
	void* state_buf = malloc(state_sz);
	assert(state_buf != NULL);

	dsp56300_state_save(ctx, state_buf);

	/* Reset and verify change */
	dsp56300_reset(ctx);
	rc = dsp56300_get_reg(ctx, DSP56300_REG_X0, &val);
	assert(rc == 0);
	assert(val == 0);

	/* Load state back */
	dsp56300_state_load(ctx, state_buf);
	rc = dsp56300_get_reg(ctx, DSP56300_REG_X0, &val);
	assert(rc == 0);
	assert(val == 0x123456);

	free(state_buf);
	dsp56300_destroy(ctx);

	/* 5. DSP56311 Peripherals Subsystem ABI */
	dsp56311_peripherals* peri = dsp56311_peripherals_create();
	assert(peri != NULL);
	dsp56311_peripherals_reset(peri);
	assert(dsp56311_peripherals_read_x(peri, 0xFFFF83) == 0);

	dsp56311_peripherals_write_x(peri, 0xFFFF83, 0x000007);
	assert(dsp56311_peripherals_read_x(peri, 0xFFFF83) == 0x000007);

	dsp56311_peripherals_host_write8(peri, 0x05, 0xDE);
	dsp56311_peripherals_host_write8(peri, 0x06, 0xAD);
	dsp56311_peripherals_host_write8(peri, 0x07, 0xBE);
	assert(dsp56311_peripherals_read_x(peri, 0xFFFFC6) == 0xDEADBE);

	dsp56311_peripherals_step(peri, 10);
	dsp56311_peripherals_destroy(peri);

	printf("[PASS] All C11 ABI assertions passed successfully.\n");
	return 0;
}

