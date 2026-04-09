/*
 * WAMR bridge for QuickBEAM NIFs.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wamr_bridge.h"
#include "wamr/include/wasm_export.h"
#include "wamr/interpreter/wasm.h"

struct WamrModule {
    wasm_module_t module;
    uint8_t *wasm_buf;
    uint8_t *source_buf;
    uint32_t wasm_len;
};

struct WamrInstance {
    wasm_module_inst_t inst;
    wasm_exec_env_t exec_env;
    WamrModule *mod;
    wasm_module_t loaded_module;
    uint8_t *loaded_wasm_buf;
};

static bool g_initialized = false;

bool
wamr_bridge_init(void)
{
    if (g_initialized)
        return true;

    if (!wasm_runtime_init()) {
        return false;
    }

    g_initialized = true;
    return true;
}

void
wamr_bridge_destroy(void)
{
    if (g_initialized) {
        wasm_runtime_destroy();
        g_initialized = false;
    }
}

WamrModule *
wamr_bridge_compile(const uint8_t *bytes, uint32_t len,
                    char *err_buf, uint32_t err_buf_size)
{
    if (!g_initialized) {
        snprintf(err_buf, err_buf_size, "WAMR not initialized");
        return NULL;
    }

    uint8_t *buf = malloc(len);
    uint8_t *source_buf = malloc(len);
    if (!buf || !source_buf) {
        free(buf);
        free(source_buf);
        snprintf(err_buf, err_buf_size, "out of memory");
        return NULL;
    }
    memcpy(buf, bytes, len);
    memcpy(source_buf, bytes, len);

    wasm_module_t module = wasm_runtime_load(buf, len, err_buf, err_buf_size);
    if (!module) {
        free(buf);
        free(source_buf);
        return NULL;
    }

    WamrModule *mod = malloc(sizeof(WamrModule));
    if (!mod) {
        wasm_runtime_unload(module);
        free(buf);
        free(source_buf);
        snprintf(err_buf, err_buf_size, "out of memory");
        return NULL;
    }

    mod->module = module;
    mod->wasm_buf = buf;
    mod->source_buf = source_buf;
    mod->wasm_len = len;
    return mod;
}

void
wamr_bridge_free_module(WamrModule *mod)
{
    if (!mod)
        return;
    if (mod->module)
        wasm_runtime_unload(mod->module);
    free(mod->wasm_buf);
    free(mod->source_buf);
    free(mod);
}

bool
wamr_bridge_validate(const uint8_t *bytes, uint32_t len)
{
    if (!g_initialized && !wamr_bridge_init())
        return false;

    uint8_t *buf = malloc(len);
    if (!buf)
        return false;
    memcpy(buf, bytes, len);

    char err[128];
    wasm_module_t module = wasm_runtime_load(buf, len, err, sizeof(err));
    if (!module) {
        free(buf);
        return false;
    }
    wasm_runtime_unload(module);
    free(buf);
    return true;
}

static void
unregister_native_modules(const WamrNativeModule *modules,
                          uint32_t module_count)
{
    uint32_t i;

    if (!modules)
        return;

    for (i = 0; i < module_count; i++) {
        if (modules[i].module_name && modules[i].symbols) {
            wasm_runtime_unregister_natives(modules[i].module_name,
                                            modules[i].symbols);
        }
    }
}

static bool
register_native_modules(const WamrNativeModule *modules,
                        uint32_t module_count,
                        char *err_buf, uint32_t err_buf_size)
{
    uint32_t i;

    if (module_count == 0)
        return true;

    for (i = 0; i < module_count; i++) {
        if (!wasm_runtime_register_natives_raw(modules[i].module_name,
                                               modules[i].symbols,
                                               modules[i].symbol_count)) {
            snprintf(err_buf, err_buf_size, "failed to register host imports");
            unregister_native_modules(modules, i);
            return false;
        }
    }

    return true;
}

static WamrInstance *
start_instance(WamrModule *mod,
               uint32_t stack_size,
               uint32_t heap_size,
               const WamrNativeModule *modules,
               uint32_t module_count,
               char *err_buf, uint32_t err_buf_size)
{
    uint8_t *loaded_wasm_buf = NULL;
    wasm_module_t loaded_module = NULL;
    wasm_module_inst_t inst;
    wasm_exec_env_t exec_env;
    WamrInstance *wi;

    if (!mod || !mod->module) {
        snprintf(err_buf, err_buf_size, "null module");
        return NULL;
    }

    if (!register_native_modules(modules, module_count, err_buf, err_buf_size)) {
        return NULL;
    }

    if (module_count > 0) {
        loaded_wasm_buf = malloc(mod->wasm_len);
        if (!loaded_wasm_buf) {
            unregister_native_modules(modules, module_count);
            snprintf(err_buf, err_buf_size, "out of memory");
            return NULL;
        }
        memcpy(loaded_wasm_buf, mod->source_buf, mod->wasm_len);
        loaded_module = wasm_runtime_load(loaded_wasm_buf, mod->wasm_len,
                                          err_buf, err_buf_size);
        if (!loaded_module) {
            free(loaded_wasm_buf);
            unregister_native_modules(modules, module_count);
            return NULL;
        }
    }

    inst = wasm_runtime_instantiate(loaded_module ? loaded_module : mod->module,
                                    stack_size, heap_size, err_buf,
                                    err_buf_size);
    if (!inst) {
        if (loaded_module)
            wasm_runtime_unload(loaded_module);
        free(loaded_wasm_buf);
        unregister_native_modules(modules, module_count);
        return NULL;
    }

    exec_env = wasm_runtime_create_exec_env(inst, stack_size);
    if (!exec_env) {
        wasm_runtime_deinstantiate(inst);
        if (loaded_module)
            wasm_runtime_unload(loaded_module);
        free(loaded_wasm_buf);
        unregister_native_modules(modules, module_count);
        snprintf(err_buf, err_buf_size, "failed to create exec env");
        return NULL;
    }

    wi = calloc(1, sizeof(WamrInstance));
    if (!wi) {
        wasm_runtime_destroy_exec_env(exec_env);
        wasm_runtime_deinstantiate(inst);
        if (loaded_module)
            wasm_runtime_unload(loaded_module);
        free(loaded_wasm_buf);
        unregister_native_modules(modules, module_count);
        snprintf(err_buf, err_buf_size, "out of memory");
        return NULL;
    }

    wi->inst = inst;
    wi->exec_env = exec_env;
    wi->mod = mod;
    wi->loaded_module = loaded_module;
    wi->loaded_wasm_buf = loaded_wasm_buf;
    return wi;
}

WamrInstance *
wamr_bridge_start(WamrModule *mod,
                  uint32_t stack_size,
                  uint32_t heap_size,
                  char *err_buf, uint32_t err_buf_size)
{
    return start_instance(mod, stack_size, heap_size, NULL, 0, err_buf,
                          err_buf_size);
}

WamrInstance *
wamr_bridge_start_with_native_modules(WamrModule *mod,
                                      uint32_t stack_size,
                                      uint32_t heap_size,
                                      const WamrNativeModule *modules,
                                      uint32_t module_count,
                                      char *err_buf, uint32_t err_buf_size)
{
    return start_instance(mod, stack_size, heap_size, modules, module_count,
                          err_buf, err_buf_size);
}

void
wamr_bridge_unregister_native_modules(const WamrNativeModule *modules,
                                      uint32_t module_count)
{
    unregister_native_modules(modules, module_count);
}

void
wamr_bridge_stop(WamrInstance *inst)
{
    if (!inst)
        return;
    if (inst->exec_env)
        wasm_runtime_destroy_exec_env(inst->exec_env);
    if (inst->inst)
        wasm_runtime_deinstantiate(inst->inst);
    if (inst->loaded_module)
        wasm_runtime_unload(inst->loaded_module);
    free(inst->loaded_wasm_buf);
    free(inst);
}

bool
wamr_bridge_function_signature(WamrInstance *inst,
                               const char *func_name,
                               uint32_t *param_count,
                               wasm_valkind_t *param_types,
                               uint32_t *result_count,
                               wasm_valkind_t *result_types,
                               char *err_buf, uint32_t err_buf_size)
{
    if (!inst || !inst->inst) {
        snprintf(err_buf, err_buf_size, "null instance");
        return false;
    }

    wasm_function_inst_t func = wasm_runtime_lookup_function(inst->inst, func_name);
    if (!func) {
        snprintf(err_buf, err_buf_size, "function '%s' not found", func_name);
        return false;
    }

    uint32_t params_len = wasm_func_get_param_count(func, inst->inst);
    uint32_t results_len = wasm_func_get_result_count(func, inst->inst);

    if (param_count)
        *param_count = params_len;
    if (result_count)
        *result_count = results_len;
    if (param_types && params_len > 0)
        wasm_func_get_param_types(func, inst->inst, param_types);
    if (result_types && results_len > 0)
        wasm_func_get_result_types(func, inst->inst, result_types);

    return true;
}

void
wamr_bridge_set_instruction_limit(WamrInstance *inst, int instruction_count)
{
    if (!inst || !inst->exec_env)
        return;
    wasm_runtime_set_instruction_count_limit(inst->exec_env, instruction_count);
}

bool
wamr_bridge_call_typed(WamrInstance *inst,
                       const char *func_name,
                       const wasm_val_t *params,
                       uint32_t param_count,
                       wasm_val_t *results,
                       uint32_t result_count,
                       char *err_buf, uint32_t err_buf_size)
{
    if (!inst || !inst->inst) {
        snprintf(err_buf, err_buf_size, "null instance");
        return false;
    }

    wasm_function_inst_t func = wasm_runtime_lookup_function(inst->inst, func_name);
    if (!func) {
        snprintf(err_buf, err_buf_size, "function '%s' not found", func_name);
        return false;
    }

    if (!wasm_runtime_call_wasm_a(inst->exec_env, func, result_count, results,
                                  param_count, (wasm_val_t *)params)) {
        const char *exception = wasm_runtime_get_exception(inst->inst);
        snprintf(err_buf, err_buf_size, "%s",
                 exception ? exception : "unknown error");
        wasm_runtime_clear_exception(inst->inst);
        return false;
    }

    return true;
}

int32_t
wamr_bridge_export_count(WamrModule *mod)
{
    if (!mod || !mod->module)
        return 0;
    return wasm_runtime_get_export_count(mod->module);
}

bool
wamr_bridge_export_info(WamrModule *mod, int32_t index,
                        const char **name, int32_t *kind)
{
    if (!mod || !mod->module)
        return false;

    wasm_export_t export_info;
    wasm_runtime_get_export_type(mod->module, index, &export_info);
    *name = export_info.name;
    *kind = (int32_t)export_info.kind;
    return true;
}

int32_t
wamr_bridge_import_count(WamrModule *mod)
{
    if (!mod || !mod->module)
        return 0;
    return wasm_runtime_get_import_count(mod->module);
}

bool
wamr_bridge_import_info(WamrModule *mod, int32_t index,
                        const char **module_name, const char **name,
                        int32_t *kind)
{
    if (!mod || !mod->module)
        return false;

    wasm_import_t import_info;
    wasm_runtime_get_import_type(mod->module, index, &import_info);
    *module_name = import_info.module_name;
    *name = import_info.name;
    *kind = (int32_t)import_info.kind;
    return true;
}

uint32_t
wamr_bridge_memory_size(WamrInstance *inst)
{
    if (!inst || !inst->inst)
        return 0;

    wasm_memory_inst_t mem = wasm_runtime_get_default_memory(inst->inst);
    if (!mem)
        return 0;

    return (uint32_t)(wasm_memory_get_cur_page_count(mem) * 65536);
}

int32_t
wamr_bridge_memory_grow(WamrInstance *inst, uint32_t delta_pages)
{
    if (!inst || !inst->inst)
        return -1;
    uint32_t cur = wamr_bridge_memory_size(inst) / 65536;
    if (!wasm_runtime_enlarge_memory(inst->inst, (cur + delta_pages) * 65536))
        return -1;
    return (int32_t)cur;
}

bool
wamr_bridge_read_memory(WamrInstance *inst, uint32_t offset,
                        uint8_t *buf, uint32_t len)
{
    if (!inst || !inst->inst)
        return false;

    uint32_t mem_size = wamr_bridge_memory_size(inst);
    if ((uint64_t)offset + len > mem_size)
        return false;

    void *native = wasm_runtime_addr_app_to_native(inst->inst, (uint64_t)offset);
    if (!native)
        return false;

    memcpy(buf, native, len);
    return true;
}

bool
wamr_bridge_write_memory(WamrInstance *inst, uint32_t offset,
                         const uint8_t *buf, uint32_t len)
{
    if (!inst || !inst->inst)
        return false;

    uint32_t mem_size = wamr_bridge_memory_size(inst);
    if ((uint64_t)offset + len > mem_size)
        return false;

    void *native = wasm_runtime_addr_app_to_native(inst->inst, (uint64_t)offset);
    if (!native)
        return false;

    memcpy(native, buf, len);
    return true;
}

static bool
read_global_value(const wasm_global_inst_t *global, wasm_val_t *value,
                  char *err_buf, uint32_t err_buf_size)
{
    value->kind = global->kind;
    switch (global->kind) {
        case WASM_I32:
            value->of.i32 = *(int32_t *)global->global_data;
            return true;
        case WASM_I64:
            value->of.i64 = *(int64_t *)global->global_data;
            return true;
        case WASM_F32:
            value->of.f32 = *(float *)global->global_data;
            return true;
        case WASM_F64:
            value->of.f64 = *(double *)global->global_data;
            return true;
        default:
            snprintf(err_buf, err_buf_size, "unsupported global type");
            return false;
    }
}

static bool
write_global_value(wasm_global_inst_t *global, const wasm_val_t *value,
                   char *err_buf, uint32_t err_buf_size)
{
    if (!global->is_mutable) {
        snprintf(err_buf, err_buf_size, "global is immutable");
        return false;
    }

    if (global->kind != value->kind) {
        snprintf(err_buf, err_buf_size, "global type mismatch");
        return false;
    }

    switch (global->kind) {
        case WASM_I32:
            *(int32_t *)global->global_data = value->of.i32;
            return true;
        case WASM_I64:
            *(int64_t *)global->global_data = value->of.i64;
            return true;
        case WASM_F32:
            *(float *)global->global_data = value->of.f32;
            return true;
        case WASM_F64:
            *(double *)global->global_data = value->of.f64;
            return true;
        default:
            snprintf(err_buf, err_buf_size, "unsupported global type");
            return false;
    }
}

bool
wamr_bridge_read_global(WamrInstance *inst, const char *name,
                        wasm_val_t *value,
                        char *err_buf, uint32_t err_buf_size)
{
    wasm_global_inst_t global;

    if (!inst || !inst->inst) {
        snprintf(err_buf, err_buf_size, "null instance");
        return false;
    }

    if (!wasm_runtime_get_export_global_inst(inst->inst, name, &global)) {
        snprintf(err_buf, err_buf_size, "global '%s' not found", name);
        return false;
    }

    return read_global_value(&global, value, err_buf, err_buf_size);
}

bool
wamr_bridge_write_global(WamrInstance *inst, const char *name,
                         const wasm_val_t *value,
                         char *err_buf, uint32_t err_buf_size)
{
    wasm_global_inst_t global;

    if (!inst || !inst->inst) {
        snprintf(err_buf, err_buf_size, "null instance");
        return false;
    }

    if (!wasm_runtime_get_export_global_inst(inst->inst, name, &global)) {
        snprintf(err_buf, err_buf_size, "global '%s' not found", name);
        return false;
    }

    return write_global_value(&global, value, err_buf, err_buf_size);
}
