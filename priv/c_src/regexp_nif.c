#include <stdlib.h>
#include <string.h>
#include "libregexp.h"
#include "quickjs.h"

/* Thin wrapper for calling lre_exec from the NIF */
int qb_regexp_exec(const uint8_t *bc_buf, int bc_len,
                   const uint8_t *input, int input_len,
                   int last_index,
                   int *out_captures, int max_captures) {
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) return -1;
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) { JS_FreeRuntime(rt); return -1; }

    int capture_count = lre_get_capture_count(bc_buf);
    if (capture_count <= 0 || capture_count > max_captures) {
        JS_FreeContext(ctx);
        JS_FreeRuntime(rt);
        return -1;
    }

    uint8_t **capture = calloc(capture_count * 2, sizeof(uint8_t*));
    if (!capture) {
        JS_FreeContext(ctx);
        JS_FreeRuntime(rt);
        return -1;
    }

    int ret = lre_exec(capture, bc_buf, input, last_index, input_len, 0, ctx);

    if (ret == 1) {
        for (int i = 0; i < capture_count * 2; i++) {
            if (capture[i])
                out_captures[i] = (int)(capture[i] - input);
            else
                out_captures[i] = -1;
        }
    }

    free(capture);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return ret == 1 ? capture_count : 0;
}
