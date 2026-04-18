#ifndef REGEXP_NIF_H
#define REGEXP_NIF_H

#include <stdint.h>

int qb_regexp_exec(const uint8_t *bc_buf, int bc_len,
                   const uint8_t *input, int input_len,
                   int last_index,
                   int *out_captures, int max_captures);

#endif
