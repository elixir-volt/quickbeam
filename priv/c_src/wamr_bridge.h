/*
 * WAMR bridge for QuickBEAM NIFs.
 * Thin C wrapper around WAMR's embedding API.
 */

#ifndef _WAMR_BRIDGE_H_
#define _WAMR_BRIDGE_H_

#include <stdint.h>
#include <stdbool.h>

typedef struct WamrModule WamrModule;
typedef struct WamrInstance WamrInstance;

/* Initialize the WAMR runtime. Call once at NIF load. */
bool wamr_bridge_init(void);

/* Destroy the WAMR runtime. Call at NIF unload. */
void wamr_bridge_destroy(void);

/* Compile a WASM binary into a module. Returns NULL on error. */
WamrModule *wamr_bridge_compile(const uint8_t *bytes, uint32_t len,
                                char *err_buf, uint32_t err_buf_size);

/* Free a compiled module. */
void wamr_bridge_free_module(WamrModule *mod);

/* Validate a WASM binary without full compilation. */
bool wamr_bridge_validate(const uint8_t *bytes, uint32_t len);

/* Instantiate a compiled module. Returns NULL on error. */
WamrInstance *wamr_bridge_start(WamrModule *mod,
                                uint32_t stack_size,
                                uint32_t heap_size,
                                char *err_buf, uint32_t err_buf_size);

/* Destroy an instance. */
void wamr_bridge_stop(WamrInstance *inst);

/* Call an exported function by name.
 * params/results are arrays of uint64_t (wasm values packed).
 * Returns false on error (check err_buf). */
bool wamr_bridge_call(WamrInstance *inst,
                       const char *func_name,
                       uint32_t *params, uint32_t param_count,
                       uint32_t *results, uint32_t result_count,
                       char *err_buf, uint32_t err_buf_size);

/* Get the number of exports. */
int32_t wamr_bridge_export_count(WamrModule *mod);

/* Get export info by index. Returns false if index out of range. */
bool wamr_bridge_export_info(WamrModule *mod, int32_t index,
                              const char **name, int32_t *kind);

/* Get the number of imports. */
int32_t wamr_bridge_import_count(WamrModule *mod);

/* Get import info by index. Returns false if index out of range. */
bool wamr_bridge_import_info(WamrModule *mod, int32_t index,
                              const char **module_name, const char **name,
                              int32_t *kind);

/* Memory operations on an instance. */
uint32_t wamr_bridge_memory_size(WamrInstance *inst);
int32_t wamr_bridge_memory_grow(WamrInstance *inst, uint32_t delta);
bool wamr_bridge_read_memory(WamrInstance *inst, uint32_t offset,
                              uint8_t *buf, uint32_t len);
bool wamr_bridge_write_memory(WamrInstance *inst, uint32_t offset,
                               const uint8_t *buf, uint32_t len);

#endif /* _WAMR_BRIDGE_H_ */
