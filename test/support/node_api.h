#ifndef NODE_API_H
#define NODE_API_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct NapiEnv* napi_env;
typedef struct napi_value__* napi_value;
typedef struct napi_ref__* napi_ref;
typedef struct napi_handle_scope__* napi_handle_scope;
typedef struct napi_callback_info__* napi_callback_info;
typedef struct napi_deferred__* napi_deferred;

typedef unsigned int napi_status;
typedef unsigned int napi_valuetype;

enum {
    napi_undefined = 0,
    napi_null = 1,
    napi_boolean = 2,
    napi_number = 3,
    napi_string = 4,
    napi_symbol = 5,
    napi_object = 6,
    napi_function = 7,
    napi_external = 8,
    napi_bigint = 9,
};

#define napi_ok 0
typedef napi_value (*napi_callback)(napi_env env, napi_callback_info info);
#define NAPI_AUTO_LENGTH ((size_t)-1)

napi_status napi_create_string_utf8(napi_env, const char*, size_t, napi_value*);
napi_status napi_create_function(napi_env, const char*, size_t, napi_callback, void*, napi_value*);
napi_status napi_set_named_property(napi_env, napi_value, const char*, napi_value);
napi_status napi_get_cb_info(napi_env, napi_callback_info, size_t*, napi_value*, napi_value*, void**);
napi_status napi_get_value_double(napi_env, napi_value, double*);
napi_status napi_create_double(napi_env, double, napi_value*);
napi_status napi_create_int32(napi_env, int32_t, napi_value*);
napi_status napi_create_object(napi_env, napi_value*);
napi_status napi_create_array(napi_env, napi_value*);
napi_status napi_set_element(napi_env, napi_value, uint32_t, napi_value);
napi_status napi_typeof(napi_env, napi_value, napi_valuetype*);
napi_status napi_get_value_string_utf8(napi_env, napi_value, char*, size_t, size_t*);

#ifdef __cplusplus
#define NAPI_MODULE_EXPORT extern "C" __attribute__((visibility("default")))
#else
#define NAPI_MODULE_EXPORT __attribute__((visibility("default")))
#endif

#define NAPI_MODULE_INIT()                                           \
    NAPI_MODULE_EXPORT napi_value                                    \
    napi_register_module_v1(napi_env env, napi_value exports)

#endif
