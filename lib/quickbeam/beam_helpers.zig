const types = @import("types.zig");
const beam = @import("beam");

const std = types.std;
const e = types.e;

pub const ListCell = struct {
    head: e.ErlNifTerm,
    tail: e.ErlNifTerm,
};

pub const MapPair = struct {
    key: e.ErlNifTerm,
    value: e.ErlNifTerm,
};

pub const NewBinary = struct {
    term: e.ErlNifTerm,
    data: [*c]u8,
};

pub fn caller_pid(env: *e.ErlNifEnv) beam.pid {
    var pid = std.mem.zeroes(beam.pid);
    _ = e.enif_self(env, &pid);
    return pid;
}

pub fn existing_atom(env: *e.ErlNifEnv, name: []const u8) ?e.ErlNifTerm {
    var atom = std.mem.zeroes(e.ErlNifTerm);
    if (e.enif_make_existing_atom_len(env, name.ptr, name.len, &atom, e.ERL_NIF_LATIN1) == 0) return null;
    return atom;
}

pub fn map_value(env: *e.ErlNifEnv, map: e.ErlNifTerm, key: e.ErlNifTerm) ?e.ErlNifTerm {
    var value = std.mem.zeroes(e.ErlNifTerm);
    if (e.enif_get_map_value(env, map, key, &value) == 0) return null;
    return value;
}

pub fn map_uint(env: *e.ErlNifEnv, map: e.ErlNifTerm, key: []const u8) ?u64 {
    const key_term = existing_atom(env, key) orelse return null;
    const value = map_value(env, map, key_term) orelse return null;
    return get_uint64(env, value);
}

pub fn get_uint64(env: *e.ErlNifEnv, term: e.ErlNifTerm) ?u64 {
    var value: u64 = 0;
    if (e.enif_get_uint64(env, term, &value) == 0) return null;
    return value;
}

pub fn inspect_binary(env: ?*e.ErlNifEnv, term: e.ErlNifTerm) ?e.ErlNifBinary {
    var bin = std.mem.zeroes(e.ErlNifBinary);
    if (e.enif_inspect_binary(env, term, &bin) == 0) return null;
    return bin;
}

pub fn alloc_binary(size: usize) ?e.ErlNifBinary {
    var bin = std.mem.zeroes(e.ErlNifBinary);
    if (e.enif_alloc_binary(size, &bin) == 0) return null;
    return bin;
}

pub fn make_new_binary(env: ?*e.ErlNifEnv, size: usize) ?NewBinary {
    var term = std.mem.zeroes(e.ErlNifTerm);
    const data = e.enif_make_new_binary(env, size, &term) orelse return null;
    return .{ .term = term, .data = data };
}

pub fn term_to_binary(env: ?*e.ErlNifEnv, term: e.ErlNifTerm) ?e.ErlNifBinary {
    var bin = std.mem.zeroes(e.ErlNifBinary);
    if (e.enif_term_to_binary(env, term, &bin) == 0) return null;
    return bin;
}

pub fn binary_to_term(env: ?*e.ErlNifEnv, data: [*c]u8, size: usize) ?e.ErlNifTerm {
    var term = std.mem.zeroes(e.ErlNifTerm);
    if (e.enif_binary_to_term(env, data, size, &term, 0) == 0) return null;
    return term;
}

pub fn get_list_cell(env: ?*e.ErlNifEnv, list: e.ErlNifTerm) ?ListCell {
    var head = std.mem.zeroes(e.ErlNifTerm);
    var tail = std.mem.zeroes(e.ErlNifTerm);
    if (e.enif_get_list_cell(env, list, &head, &tail) == 0) return null;
    return .{ .head = head, .tail = tail };
}

pub fn map_iterator_create(env: ?*e.ErlNifEnv, map: e.ErlNifTerm, entry: e.ErlNifMapIteratorEntry) ?e.ErlNifMapIterator {
    var iter = std.mem.zeroes(e.ErlNifMapIterator);
    if (e.enif_map_iterator_create(env, map, &iter, entry) == 0) return null;
    return iter;
}

pub fn map_iterator_get_pair(env: ?*e.ErlNifEnv, iter: *e.ErlNifMapIterator) ?MapPair {
    var key = std.mem.zeroes(e.ErlNifTerm);
    var value = std.mem.zeroes(e.ErlNifTerm);
    if (e.enif_map_iterator_get_pair(env, iter, &key, &value) == 0) return null;
    return .{ .key = key, .value = value };
}

pub fn get_local_pid(env: ?*e.ErlNifEnv, term: e.ErlNifTerm) ?beam.pid {
    var pid = std.mem.zeroes(beam.pid);
    if (e.enif_get_local_pid(env, term, &pid) == 0) return null;
    return pid;
}

pub fn make_map_from_arrays(env: ?*e.ErlNifEnv, keys: ?[*]e.ErlNifTerm, values: ?[*]e.ErlNifTerm, count: usize) ?e.ErlNifTerm {
    var term = std.mem.zeroes(e.ErlNifTerm);
    if (e.enif_make_map_from_arrays(env, keys, values, count, &term) == 0) return null;
    return term;
}
