#include <node_api.h>
#include <string.h>
#include <stdlib.h>

static napi_value hello(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_string_utf8(env, "hello from napi", NAPI_AUTO_LENGTH, &result);
    return result;
}

static napi_value add(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);

    double a, b;
    napi_get_value_double(env, argv[0], &a);
    napi_get_value_double(env, argv[1], &b);

    napi_value result;
    napi_create_double(env, a + b, &result);
    return result;
}

static napi_value concat(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);

    char buf_a[256], buf_b[256];
    size_t len_a, len_b;
    napi_get_value_string_utf8(env, argv[0], buf_a, sizeof(buf_a), &len_a);
    napi_get_value_string_utf8(env, argv[1], buf_b, sizeof(buf_b), &len_b);

    char combined[512];
    memcpy(combined, buf_a, len_a);
    memcpy(combined + len_a, buf_b, len_b);

    napi_value result;
    napi_create_string_utf8(env, combined, len_a + len_b, &result);
    return result;
}

static napi_value create_object(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);

    napi_value obj;
    napi_create_object(env, &obj);
    napi_set_named_property(env, obj, "key", argv[0]);
    napi_set_named_property(env, obj, "value", argv[1]);

    return obj;
}

static napi_value get_type(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);

    napi_valuetype type;
    napi_typeof(env, argv[0], &type);

    const char* type_str;
    switch (type) {
        case napi_undefined: type_str = "undefined"; break;
        case napi_null: type_str = "null"; break;
        case napi_boolean: type_str = "boolean"; break;
        case napi_number: type_str = "number"; break;
        case napi_string: type_str = "string"; break;
        case napi_symbol: type_str = "symbol"; break;
        case napi_object: type_str = "object"; break;
        case napi_function: type_str = "function"; break;
        case napi_external: type_str = "external"; break;
        case napi_bigint: type_str = "bigint"; break;
        default: type_str = "unknown"; break;
    }

    napi_value result;
    napi_create_string_utf8(env, type_str, NAPI_AUTO_LENGTH, &result);
    return result;
}

static napi_value make_array(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);

    napi_value arr;
    napi_create_array(env, &arr);
    for (size_t i = 0; i < argc; i++) {
        napi_set_element(env, arr, (uint32_t)i, argv[i]);
    }

    return arr;
}

static napi_value init(napi_env env, napi_value exports) {
    napi_value fn;

    napi_create_function(env, "hello", NAPI_AUTO_LENGTH, hello, NULL, &fn);
    napi_set_named_property(env, exports, "hello", fn);

    napi_create_function(env, "add", NAPI_AUTO_LENGTH, add, NULL, &fn);
    napi_set_named_property(env, exports, "add", fn);

    napi_create_function(env, "concat", NAPI_AUTO_LENGTH, concat, NULL, &fn);
    napi_set_named_property(env, exports, "concat", fn);

    napi_create_function(env, "createObject", NAPI_AUTO_LENGTH, create_object, NULL, &fn);
    napi_set_named_property(env, exports, "createObject", fn);

    napi_create_function(env, "getType", NAPI_AUTO_LENGTH, get_type, NULL, &fn);
    napi_set_named_property(env, exports, "getType", fn);

    napi_create_function(env, "makeArray", NAPI_AUTO_LENGTH, make_array, NULL, &fn);
    napi_set_named_property(env, exports, "makeArray", fn);

    // Also export a plain value
    napi_value version;
    napi_create_int32(env, 42, &version);
    napi_set_named_property(env, exports, "version", version);

    return exports;
}

NAPI_MODULE_INIT() {
    return init(env, exports);
}
