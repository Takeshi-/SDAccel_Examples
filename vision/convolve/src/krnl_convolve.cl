/**********
Copyright (c) 2016, Xilinx, Inc.
All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation
and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors
may be used to endorse or promote products derived from this software
without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
**********/

#define FILTER_WIDTH 11
#define FILTER_HEIGHT 11

#define IMAGE_WIDTH 1024
#define IMAGE_HEIGHT 1024


#define B (8)
#define M(x) (((x)-1)/(B) + 1)

#if(B == 32)
typedef uint16 bus_t;
#elif(B == 16)
typedef uint8 bus_t;
#elif(B == 8)
typedef uint4 bus_t;
#elif(B == 4)
typedef uint2 bus_t;
#elif(B == 2)
typedef uint bus_t;
#endif

typedef union {
	bus_t b;
	short s[B];
} bus_to_short_t;

void bus_to_short(bus_t in, short out[B]) {
	bus_to_short_t val;

	val.b = in;

	for(int i = 0; i < B; i++) {
		out[i] = val.s[i];
	}
}

bus_t short_to_bus(short in[B]) {
	bus_to_short_t val;

	for(int i = 0; i < B; i++) {
		val.s[i] = in[i];
	}

	return val.b;
}

void get_coef(
	__global bus_t *coef,
	short coef_buf[FILTER_WIDTH*FILTER_HEIGHT]
) {
	//printf("get_coef {\n");

	__attribute__((xcl_pipeline_loop))
	for(int i = 0; i < M(FILTER_WIDTH*FILTER_HEIGHT); i++) {
		short tmp[B] __attribute__((xcl_array_partition(complete,1)));
		bus_to_short(coef[i], tmp);

		for(int j = 0; j < B; j++) {
			coef_buf[i*B + j] = tmp[j];
		}
	}

	//printf("get_coef }\n");
}

void filter(
	short coef_buf[FILTER_WIDTH*FILTER_HEIGHT],
	global bus_t* input, global bus_t* output
) {
	//printf("filter {\n");

	/* Registers to read values from */
	#define REG_WIDTH (M(FILTER_WIDTH+B-1)*B)

	short line_reg[FILTER_HEIGHT][REG_WIDTH]
		__attribute__((xcl_array_partition(complete,1)))
		__attribute__((xcl_array_partition(complete,2)));

	/* Line buffers to store values */
	short line_buf[FILTER_HEIGHT-1][M(IMAGE_WIDTH-REG_WIDTH)*B]
		__attribute__((xcl_array_partition(complete, 1)))
/* The following could be used with incrementing pointers in a BRAM to reduce FF usage and hit 4k/8k image sizes */
		__attribute__((xcl_array_partition(cyclic, B, 2)));
//		__attribute__((xcl_array_partition(complete, 2)));

	__attribute__((xcl_pipeline_loop))
	for(size_t i = 0; i < M(IMAGE_WIDTH*IMAGE_HEIGHT); i++) {
		short input_buf[B] __attribute__((xcl_array_partition(complete, 1)));

		/* Read pixels from the input image */
		bus_to_short(input[i], input_buf);

		/* Rotate Buffers */
		for(size_t y = 0; y < FILTER_HEIGHT-1; y++) {
			for(size_t x = 0; x < REG_WIDTH - B; x++) {
				line_reg[y][x] = line_reg[y][x+B];
			}
			for(size_t j = 0; j < B; j++) {
				line_reg[y][REG_WIDTH - B + j] = line_buf[y][j + B*(i % (M(IMAGE_WIDTH-REG_WIDTH)))];
			}
			for(size_t j = 0; j < B; j++) {
				line_buf[y][j + B*(i % (M(IMAGE_WIDTH-REG_WIDTH)))] = line_reg[y+1][j];
			}
		}
		for(size_t x = 0; x < ((M(FILTER_WIDTH+B)-1)*B); x++) {
			line_reg[FILTER_HEIGHT-1][x] = line_reg[FILTER_HEIGHT-1][x+B];
		}
		for(size_t j = 0; j < B; j++) {
			line_reg[FILTER_HEIGHT-1][REG_WIDTH - B + j] = input_buf[j];
		}

		short filter_sums[B];

		for(size_t j = 0; j < B; j++) {
			int sum = 0;

			for(size_t y = 0; y < FILTER_HEIGHT; y++) {
				for(size_t x = 0; x < FILTER_WIDTH; x++) {
					const size_t offset = REG_WIDTH - FILTER_WIDTH - B + 1;
					short val = line_reg[y][offset + x + j];

					sum += (int) coef_buf[y * FILTER_WIDTH + x] *
					       (int) val;
				}
			}

			/* Handle Saturation */
			if (sum > SHRT_MAX) {
				sum = SHRT_MAX;
			} else if (sum < SHRT_MIN) {
				sum = SHRT_MIN;
			}

			filter_sums[j] = sum;
		}

		output[i] = short_to_bus(filter_sums);

		//printf("i = %d x = %d-%d y = %d\r", i, xpos, xpos + 31, ypos);
	}
	//printf("\n");

	//printf("filter }\n");
}

__attribute__((reqd_work_group_size(1,1,1)))
__kernel void krnl_convolve(
   __global bus_t *coef,
   __global bus_t *img_input,
   __global bus_t *img_output
) {
	//printf("krnl_convolve {\n");

	short coef_buf[FILTER_WIDTH*FILTER_HEIGHT]
		__attribute__((xcl_array_partition(complete, 1)));

	get_coef(coef, coef_buf);

	filter(coef_buf, img_input, img_output);

	//printf("krnl_convolve }\n");
}
