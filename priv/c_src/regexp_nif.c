#include <stdlib.h>
#include <string.h>
#include "libregexp.h"
#include "quickjs.h"

/* Persistent runtime/context for regex execution — created once, reused. */
static JSRuntime *regexp_rt = NULL;
static JSContext *regexp_ctx = NULL;

static void ensure_regexp_ctx(void) {
    if (!regexp_rt) {
        regexp_rt = JS_NewRuntime();
        if (regexp_rt) {
            JS_SetMemoryLimit(regexp_rt, 8 * 1024 * 1024); /* 8MB limit for regex */
            regexp_ctx = JS_NewContext(regexp_rt);
        }
    }
}

int qb_regexp_exec(const uint8_t *bc_buf, int bc_len,
                   const uint8_t *input, int input_len,
                   int last_index,
                   int *out_captures, int max_captures) {
    ensure_regexp_ctx();
    if (!regexp_ctx) return -1;

    int capture_count = lre_get_capture_count(bc_buf);
    if (capture_count <= 0 || capture_count > max_captures)
        return -1;

    uint8_t **capture = calloc(capture_count * 2, sizeof(uint8_t*));
    if (!capture) return -1;

    int ret = lre_exec(capture, bc_buf, input, last_index, input_len, 0, regexp_ctx);

    if (ret == 1) {
        for (int i = 0; i < capture_count * 2; i++) {
            if (capture[i])
                out_captures[i] = (int)(capture[i] - input);
            else
                out_captures[i] = -1;
        }
    }

    free(capture);
    return ret == 1 ? capture_count : 0;
}
