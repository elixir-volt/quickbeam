#include <node_api.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

static int finalized_wraps = 0;
static int finalized_external_buffers = 0;
static napi_value wrapped_keepalive = NULL;
static napi_value external_buffer_keepalive = NULL;

static void int_finalizer(napi_env env, void* data, void* hint) {
    (void)env;
    (void)hint;
    if (data != NULL) {
        free(data);
    }
    finalized_wraps += 1;
}

static void external_buffer_finalizer(napi_env env, void* data, void* hint) {
    (void)env;
    (void)hint;
    if (data != NULL) {
        free(data);
    }
    finalized_external_buffers += 1;
}

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

static napi_value buffer_kind(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_get_cb_info(env, info, &argc, NULL, NULL, NULL);

    void* data;
    napi_value buf;
    napi_create_buffer(env, 4, (char**)&data, &buf);
    ((unsigned char*)data)[0] = 1;
    ((unsigned char*)data)[1] = 2;
    ((unsigned char*)data)[2] = 3;
    ((unsigned char*)data)[3] = 4;

    napi_value ctor;
    napi_get_named_property(env, buf, "constructor", &ctor);
    napi_value name;
    napi_get_named_property(env, ctor, "name", &name);
    return name;
}

static napi_value buffer_info(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_get_cb_info(env, info, &argc, NULL, NULL, NULL);

    void* data;
    napi_value buf;
    napi_create_buffer(env, 4, (char**)&data, &buf);
    ((unsigned char*)data)[0] = 10;
    ((unsigned char*)data)[1] = 20;
    ((unsigned char*)data)[2] = 30;
    ((unsigned char*)data)[3] = 40;

    void* out;
    size_t len;
    napi_get_buffer_info(env, buf, &out, &len);

    napi_value arr;
    napi_create_array(env, &arr);
    for (uint32_t i = 0; i < len; i++) {
        napi_value n;
        napi_create_int32(env, ((unsigned char*)out)[i], &n);
        napi_set_element(env, arr, i, n);
    }
    return arr;
}

static napi_value typedarray_checks(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_get_cb_info(env, info, &argc, NULL, NULL, NULL);

    void* data;
    napi_value buf;
    napi_create_buffer(env, 1, (char**)&data, &buf);

    bool is_buffer = false;
    bool is_typedarray = false;
    napi_is_buffer(env, buf, &is_buffer);
    napi_is_typedarray(env, buf, &is_typedarray);

    napi_value obj;
    napi_create_object(env, &obj);
    napi_value b;
    napi_get_boolean(env, is_buffer, &b);
    napi_set_named_property(env, obj, "isBuffer", b);
    napi_get_boolean(env, is_typedarray, &b);
    napi_set_named_property(env, obj, "isTypedArray", b);
    return obj;
}

static napi_value coerce_object_type(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);

    napi_value obj;
    napi_coerce_to_object(env, argv[0], &obj);
    napi_value ctor;
    napi_get_named_property(env, obj, "constructor", &ctor);
    napi_value name;
    napi_get_named_property(env, ctor, "name", &name);
    return name;
}

static napi_value wrap_and_unwrap(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_get_cb_info(env, info, &argc, NULL, NULL, NULL);

    int* ptr = malloc(sizeof(int));
    *ptr = 1234;

    napi_value obj;
    napi_create_object(env, &obj);
    napi_wrap(env, obj, ptr, int_finalizer, NULL, NULL);
    wrapped_keepalive = obj;

    void* unwrapped = NULL;
    napi_unwrap(env, obj, &unwrapped);

    napi_value result;
    napi_create_int32(env, *((int*)unwrapped), &result);
    return result;
}

static napi_value remove_wrap_value(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_get_cb_info(env, info, &argc, NULL, NULL, NULL);

    int* ptr = malloc(sizeof(int));
    *ptr = 5678;

    napi_value obj;
    napi_create_object(env, &obj);
    napi_wrap(env, obj, ptr, int_finalizer, NULL, NULL);

    void* removed = NULL;
    napi_remove_wrap(env, obj, &removed);
    int value = *((int*)removed);
    free(removed);

    napi_value result;
    napi_create_int32(env, value, &result);
    return result;
}

static napi_value add_external_buffer_finalizer(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_get_cb_info(env, info, &argc, NULL, NULL, NULL);

    unsigned char* ptr = malloc(4);
    ptr[0] = 7;
    ptr[1] = 8;
    ptr[2] = 9;
    ptr[3] = 10;

    napi_value buf;
    napi_create_external_buffer(env, 4, ptr, external_buffer_finalizer, NULL, &buf);
    external_buffer_keepalive = buf;
    return buf;
}

static napi_value finalized_counts(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_get_cb_info(env, info, &argc, NULL, NULL, NULL);

    napi_value obj;
    napi_create_object(env, &obj);

    napi_value n;
    napi_create_int32(env, finalized_wraps, &n);
    napi_set_named_property(env, obj, "wraps", n);

    napi_create_int32(env, finalized_external_buffers, &n);
    napi_set_named_property(env, obj, "externalBuffers", n);

    return obj;
}

static napi_value clear_wrap_keepalive(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_get_cb_info(env, info, &argc, NULL, NULL, NULL);
    wrapped_keepalive = NULL;
    napi_value result;
    napi_create_int32(env, 1, &result);
    return result;
}

static napi_value clear_external_buffer_keepalive(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_get_cb_info(env, info, &argc, NULL, NULL, NULL);
    external_buffer_keepalive = NULL;
    napi_value result;
    napi_create_int32(env, 1, &result);
    return result;
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

    napi_create_function(env, "bufferKind", NAPI_AUTO_LENGTH, buffer_kind, NULL, &fn);
    napi_set_named_property(env, exports, "bufferKind", fn);

    napi_create_function(env, "bufferInfo", NAPI_AUTO_LENGTH, buffer_info, NULL, &fn);
    napi_set_named_property(env, exports, "bufferInfo", fn);

    napi_create_function(env, "typedarrayChecks", NAPI_AUTO_LENGTH, typedarray_checks, NULL, &fn);
    napi_set_named_property(env, exports, "typedarrayChecks", fn);

    napi_create_function(env, "coerceObjectType", NAPI_AUTO_LENGTH, coerce_object_type, NULL, &fn);
    napi_set_named_property(env, exports, "coerceObjectType", fn);

    napi_create_function(env, "wrapAndUnwrap", NAPI_AUTO_LENGTH, wrap_and_unwrap, NULL, &fn);
    napi_set_named_property(env, exports, "wrapAndUnwrap", fn);

    napi_create_function(env, "removeWrapValue", NAPI_AUTO_LENGTH, remove_wrap_value, NULL, &fn);
    napi_set_named_property(env, exports, "removeWrapValue", fn);

    napi_create_function(env, "addExternalBufferFinalizer", NAPI_AUTO_LENGTH, add_external_buffer_finalizer, NULL, &fn);
    napi_set_named_property(env, exports, "addExternalBufferFinalizer", fn);

    napi_create_function(env, "finalizedCounts", NAPI_AUTO_LENGTH, finalized_counts, NULL, &fn);
    napi_set_named_property(env, exports, "finalizedCounts", fn);

    napi_create_function(env, "clearWrapKeepalive", NAPI_AUTO_LENGTH, clear_wrap_keepalive, NULL, &fn);
    napi_set_named_property(env, exports, "clearWrapKeepalive", fn);

    napi_create_function(env, "clearExternalBufferKeepalive", NAPI_AUTO_LENGTH, clear_external_buffer_keepalive, NULL, &fn);
    napi_set_named_property(env, exports, "clearExternalBufferKeepalive", fn);

    napi_value version;
    napi_create_int32(env, 42, &version);
    napi_set_named_property(env, exports, "version", version);

    return exports;
}

NAPI_MODULE_INIT() {
    return init(env, exports);
}
