// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of plume.
//
// Copyright (c) 2026 erenvly
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://gnu.org/licenses>.

/// Helper to decode values from a D-Bus message body according to its signature.
const Decoder = @This();

const Message = @import("message/root.zig");
const Value = @import("value/root.zig");

const std = @import("std");
const lang = std.lang;
const Endian = lang.Endian;
const meta = std.meta;
const mem = std.mem;
const ArrayList = std.ArrayList;
const Allocator = mem.Allocator;

const dbusAlignOf = Value.dbusAlignOf;

allocator: Allocator,
body: []const u8,
signature: []const u8,
pos: usize,
sig_pos: usize,
endian: Endian,

/// Initializes a decoder with raw body and signature.
pub fn init(allocator: Allocator, body: []const u8, signature: []const u8, endian: Endian) Decoder {
    return .{ .allocator = allocator, .body = body, .signature = signature, .pos = 0, .sig_pos = 0, .endian = endian };
}

/// Initializes a decoder from a Message, extracting the signature from header fields.
pub fn from(allocator: Allocator, message: Message) Decoder {
    var signature: []const u8 = "";
    for (message.header.header_fields) |field| {
        if (field.code == .Signature) {
            signature = field.value.Signature;
            break;
        }
    }

    return .init(allocator, message.body, signature, message.header.endianess);
}

/// Aligns the decoder position to the specified boundary (internal helper).
fn alignTo(this: *Decoder, alignment: usize) void {
    const rem = this.pos % alignment;
    if (rem != 0) {
        this.pos += (alignment - rem);
    }
}

/// Validates the signature against the expected type and aligns the decoder position (internal helper).
fn validateAndAlign(this: *Decoder, comptime T: type) !void {
    const sig_len = Value.reprLength(T);
    var expected_sig: [256]u8 = undefined;
    Value.getRepr(T, sig_len, 0, expected_sig[0..sig_len]);

    if (this.sig_pos + sig_len > this.signature.len) return error.SignatureEnd;

    const actual_sig = this.signature[this.sig_pos .. this.sig_pos + sig_len];

    // Check for exact match, with a fallback allowing Object Paths ('o') to match Strings ('s')
    if (!mem.eql(u8, actual_sig, expected_sig[0..sig_len])) {
        const is_string_type = (T == Value.GStr or T == Value.GPath);
        const wire_is_path_or_str = (actual_sig[0] == 'o' or actual_sig[0] == 's');

        if (!(is_string_type and wire_is_path_or_str and sig_len == 1)) {
            return error.SignatureMismatch;
        }
    }

    this.sig_pos += sig_len;
    this.alignTo(dbusAlignOf(T));
}

/// Decodes the next value of type T from the body.
/// Returns error.SignatureMismatch if the body signature doesn't match T's D-Bus representation.
pub fn decode(this: *Decoder, comptime T: type) anyerror!T {
    try this.validateAndAlign(T);
    return this.readValue(T, false);
}

/// Decodes the next value of type T and allocates memory for it (recursive deep-copy).
/// This allows the returned value to outlive the decoder and the message body.
pub fn decodeAlloc(this: *Decoder, comptime T: type) anyerror!T {
    try this.validateAndAlign(T);
    return this.readValue(T, true);
}

fn readString(this: *Decoder, comptime T: type, comptime deep_copy: bool) anyerror!T {
    this.alignTo(dbusAlignOf(u32));
    if (this.pos + 4 > this.body.len) return error.EndOfBody;
    const len = mem.readInt(u32, this.body[this.pos..][0..4], this.endian);
    this.pos += 4;

    if (this.pos + len + 1 > this.body.len) return error.EndOfBody;
    if (this.body[this.pos + len] != 0) return error.MissingNullTerminator;

    const s = this.body[this.pos .. this.pos + len :0];
    this.pos += len + 1;

    if (T == Value.GStr or T == Value.GPath) {
        if (deep_copy) {
            const new_s = try this.allocator.allocSentinel(u8, s.len, 0);
            @memcpy(new_s, s);
            return T.new(new_s);
        } else {
            return T.new(s);
        }
    } else if (T == [:0]const u8) {
        if (deep_copy) {
            const new_s = try this.allocator.allocSentinel(u8, s.len, 0);
            @memcpy(new_s, s);
            return new_s;
        } else {
            return s;
        }
    } else if (T == []const u8 or T == []u8) {
        if (deep_copy) {
            const new_s = try this.allocator.alloc(u8, s.len);
            @memcpy(new_s, s);
            return new_s;
        } else {
            return s;
        }
    } else {
        return error.UnsupportedType;
    }
}

/// Reads a value of type T from the body at the current position (internal helper).
fn readValue(this: *Decoder, comptime T: type, comptime deep_copy: bool) anyerror!T {
    if (comptime Value.isDict(T)) {
        this.alignTo(dbusAlignOf(u32));
        const byte_len = try this.readValue(u32, false);
        this.alignTo(8);

        const start_pos = this.pos;
        if (this.pos + byte_len > this.body.len) return error.EndOfBody;

        const kv = Value.dictKV(T);
        const K = kv.key;
        const V = kv.val;

        var map = T.init(this.allocator);
        errdefer map.deinit();

        while (this.pos - start_pos < byte_len) {
            this.alignTo(8);
            const k = if (K == []const u8 or K == [:0]const u8 or K == Value.GStr or K == Value.GPath)
                try this.readString(K, deep_copy)
            else
                try this.readValue(K, deep_copy);

            errdefer if (deep_copy) {
                if (K == []const u8 or K == [:0]const u8) this.allocator.free(k) else freeValue(this.allocator, K, k);
            };

            this.alignTo(dbusAlignOf(V));
            const v = try this.readValue(V, deep_copy);
            try map.put(k, v);
        }

        return map;
    }

    switch (@typeInfo(T)) {
        .int => |info| {
            const size = info.bits / 8;
            if (this.pos + size > this.body.len) return error.EndOfBody;
            const val = mem.readInt(T, this.body[this.pos..][0..size], this.endian);
            this.pos += size;
            return val;
        },
        .bool => {
            // Boolean is 4 bytes (u32)
            if (this.pos + 4 > this.body.len) return error.EndOfBody;
            const val = mem.readInt(u32, this.body[this.pos..][0..4], this.endian);
            this.pos += 4;
            return val != 0;
        },
        .float => {
            if (this.pos + 8 > this.body.len) return error.EndOfBody;
            const val_bits = mem.readInt(u64, this.body[this.pos..][0..8], this.endian);
            this.pos += 8;
            return @bitCast(val_bits);
        },
        .@"struct" => |info| {
            if (T == Value.GStr or T == Value.GPath) {
                return this.readString(T, deep_copy);
            }
            if (T == Value.GSig) {
                // Signature reading: u8 len, bytes, null
                if (this.pos + 1 > this.body.len) return error.EndOfBody;
                const len = this.body[this.pos];
                this.pos += 1;

                if (this.pos + len + 1 > this.body.len) return error.EndOfBody;
                if (this.body[this.pos + len] != 0) return error.MissingNullTerminator;

                const s = this.body[this.pos .. this.pos + len :0];
                this.pos += len + 1;

                if (deep_copy) {
                    const new_s = try this.allocator.allocSentinel(u8, s.len, 0);
                    @memcpy(new_s, s);
                    return T.new(new_s);
                } else {
                    return T.new(s);
                }
            }

            // Generic struct/tuple/dict-entry support
            // DBus aligns structs and dict-entries to 8.
            var result: T = undefined;
            inline for (info.field_types, info.field_names) |field, name| {
                this.alignTo(dbusAlignOf(field));
                @field(result, name) = try this.readValue(field, deep_copy);
            }

            return result;
        },
        .pointer => |info| {
            if (info.size != .slice) return error.UnsupportedType;
            const Elem = info.child;

            this.alignTo(dbusAlignOf(u32));
            const byte_len = try this.readValue(u32, false);

            this.alignTo(dbusAlignOf(Elem));

            const start_pos = this.pos;
            if (this.pos + byte_len > this.body.len) return error.EndOfBody;

            var list: ArrayList(Elem) = try .initCapacity(this.allocator, 0);
            errdefer {
                if (deep_copy) {
                    for (list.items) |item| {
                        freeValue(this.allocator, Elem, item);
                    }
                }
                list.deinit(this.allocator);
            }

            while (this.pos - start_pos < byte_len) {
                this.alignTo(dbusAlignOf(Elem));
                try list.append(this.allocator, try this.readValue(Elem, deep_copy));
            }

            return try list.toOwnedSlice(this.allocator);
        },
        .@"union" => |info| {
            // Variants on wire: signature ('g'), then aligned value.
            const GSig = Value.GSig;
            const inner_sig_struct = try this.readValue(GSig, false);
            const inner_sig = inner_sig_struct.s;

            if (T == Value.GVariant) {
                return this.readDynamicVariant(inner_sig, deep_copy);
            }

            inline for (info.field_types, info.field_names) |fld, name| {
                const fld_sig_len = Value.reprLength(fld);
                var fld_sig_buf: [256]u8 = undefined;
                Value.getRepr(fld, fld_sig_len, 0, fld_sig_buf[0..fld_sig_len]);

                const matches_exactly = mem.eql(u8, inner_sig, fld_sig_buf[0..fld_sig_len]);
                const matches_path_fallback = (fld == Value.GStr or fld == Value.GPath) and mem.eql(u8, inner_sig, "o") and mem.eql(u8, fld_sig_buf[0..fld_sig_len], "s");

                if (matches_exactly or matches_path_fallback) {
                    this.alignTo(dbusAlignOf(fld));
                    return @unionInit(T, name, try this.readValue(fld, deep_copy));
                }
            }

            return error.NoMatchingUnionField;
        },
        else => return error.UnsupportedType,
    }
}

pub fn readDynamicVariant(this: *Decoder, sig: []const u8, comptime deep_copy: bool) anyerror!Value.GVariant {
    var sig_pos: usize = 0;
    return this.readDynamicVariantInner(sig, &sig_pos, deep_copy);
}

pub fn readDynamicVariantInner(this: *Decoder, sig: []const u8, sig_pos: *usize, comptime deep_copy: bool) anyerror!Value.GVariant {
    if (sig_pos.* >= sig.len) return error.SignatureEnd;
    const c = sig[sig_pos.*];
    sig_pos.* += 1;
    switch (c) {
        'y' => {
            this.alignTo(dbusAlignOf(u8));
            return Value.GVariant{ .byte = try this.readValue(u8, deep_copy) };
        },
        'b' => {
            this.alignTo(dbusAlignOf(bool));
            return Value.GVariant{ .boolean = try this.readValue(bool, deep_copy) };
        },
        'n' => {
            this.alignTo(dbusAlignOf(i16));
            return Value.GVariant{ .int16 = try this.readValue(i16, deep_copy) };
        },
        'q' => {
            this.alignTo(dbusAlignOf(u16));
            return Value.GVariant{ .uint16 = try this.readValue(u16, deep_copy) };
        },
        'i' => {
            this.alignTo(dbusAlignOf(i32));
            return Value.GVariant{ .int32 = try this.readValue(i32, deep_copy) };
        },
        'u' => {
            this.alignTo(dbusAlignOf(u32));
            return Value.GVariant{ .uint32 = try this.readValue(u32, deep_copy) };
        },
        'x' => {
            this.alignTo(dbusAlignOf(i64));
            return Value.GVariant{ .int64 = try this.readValue(i64, deep_copy) };
        },
        't' => {
            this.alignTo(dbusAlignOf(u64));
            return Value.GVariant{ .uint64 = try this.readValue(u64, deep_copy) };
        },
        'd' => {
            this.alignTo(dbusAlignOf(f64));
            return Value.GVariant{ .double = try this.readValue(f64, deep_copy) };
        },
        'h' => {
            this.alignTo(dbusAlignOf(Value.GUFd));
            return Value.GVariant{ .ufd = try this.readValue(Value.GUFd, deep_copy) };
        },
        's' => {
            this.alignTo(dbusAlignOf(Value.GStr));
            return Value.GVariant{ .string = try this.readValue(Value.GStr, deep_copy) };
        },
        'o' => {
            this.alignTo(dbusAlignOf(Value.GPath));
            return Value.GVariant{ .object_path = try this.readValue(Value.GPath, deep_copy) };
        },
        'g' => {
            this.alignTo(dbusAlignOf(Value.GSig));
            return Value.GVariant{ .signature = try this.readValue(Value.GSig, deep_copy) };
        },
        'v' => {
            const inner_sig_struct = try this.readValue(Value.GSig, false);
            const inner_sig = inner_sig_struct.s;
            const inner_v = try this.readDynamicVariant(inner_sig, deep_copy);
            if (deep_copy) {
                const ptr = try this.allocator.create(Value.GVariant);
                ptr.* = inner_v;
                return Value.GVariant{ .variant = ptr };
            } else {
                return error.VariantCannotBeBorrowed;
            }
        },
        'a' => {
            if (sig_pos.* >= sig.len) return error.SignatureEnd;
            const is_dict = sig[sig_pos.*] == '{';

            this.alignTo(dbusAlignOf(u32));
            const byte_len = try this.readValue(u32, false);

            if (is_dict) {
                this.alignTo(8);

                const start_pos = this.pos;
                if (this.pos + byte_len > this.body.len) return error.EndOfBody;

                if (!deep_copy) return error.DictCannotBeBorrowed;

                var dict = std.StringHashMap(Value.GVariant).init(this.allocator);
                errdefer dict.deinit();

                sig_pos.* += 1;
                const key_type = sig[sig_pos.*];
                if (key_type != 's' and key_type != 'o' and key_type != 'g') {
                    return error.UnsupportedDictKeyType;
                }

                const dict_entry_sig_start = sig_pos.*;

                while (this.pos - start_pos < byte_len) {
                    this.alignTo(8);
                    sig_pos.* = dict_entry_sig_start;

                    const key_str = switch (sig[sig_pos.*]) {
                        's', 'o', 'g' => blk: {
                            sig_pos.* += 1;
                            break :blk try this.readString([]const u8, deep_copy);
                        },
                        else => return error.UnsupportedDictKeyType,
                    };

                    const val_variant = try this.readDynamicVariantInner(sig, sig_pos, deep_copy);

                    try dict.put(key_str, val_variant);

                    if (sig[sig_pos.*] != '}') return error.ExpectedDictEnd;
                }

                if (byte_len == 0) {
                    _ = try this.skipDynamicVariantInner(sig, sig_pos);
                    _ = try this.skipDynamicVariantInner(sig, sig_pos);
                    if (sig_pos.* >= sig.len or sig[sig_pos.*] != '}') return error.ExpectedDictEnd;
                    sig_pos.* += 1;
                } else {
                    sig_pos.* += 1;
                }

                return Value.GVariant{ .dict = dict };
            } else {
                const elem_align = try this.alignOfDynamicType(sig, sig_pos.*);
                this.alignTo(elem_align);

                const start_pos = this.pos;
                if (this.pos + byte_len > this.body.len) return error.EndOfBody;

                if (!deep_copy) return error.ArrayCannotBeBorrowed;

                var list = try std.ArrayList(Value.GVariant).initCapacity(this.allocator, 0);
                errdefer list.deinit(this.allocator);

                const elem_sig_start = sig_pos.*;

                while (this.pos - start_pos < byte_len) {
                    this.alignTo(elem_align);
                    sig_pos.* = elem_sig_start;
                    const elem_v = try this.readDynamicVariantInner(sig, sig_pos, deep_copy);
                    try list.append(this.allocator, elem_v);
                }

                if (byte_len == 0) {
                    _ = try this.skipDynamicVariantInner(sig, sig_pos);
                }

                return Value.GVariant{ .array = try list.toOwnedSlice(this.allocator) };
            }
        },
        '(' => {
            this.alignTo(8);
            if (!deep_copy) return error.TupleCannotBeBorrowed;
            var list = try std.ArrayList(Value.GVariant).initCapacity(this.allocator, 0);
            errdefer list.deinit(this.allocator);

            while (sig_pos.* < sig.len and sig[sig_pos.*] != ')') {
                const elem_v = try this.readDynamicVariantInner(sig, sig_pos, deep_copy);
                try list.append(this.allocator, elem_v);
            }
            if (sig_pos.* >= sig.len or sig[sig_pos.*] != ')') return error.ExpectedTupleEnd;
            sig_pos.* += 1;

            return Value.GVariant{ .tuple = try list.toOwnedSlice(this.allocator) };
        },
        else => return error.UnsupportedDynamicType,
    }
}

fn skipDynamicVariantInner(this: *Decoder, sig: []const u8, sig_pos: *usize) anyerror!void {
    if (sig_pos.* >= sig.len) return error.SignatureEnd;
    const c = sig[sig_pos.*];
    sig_pos.* += 1;
    switch (c) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 'h', 's', 'o', 'g', 'v' => return,
        'a' => {
            return this.skipDynamicVariantInner(sig, sig_pos);
        },
        '(' => {
            while (sig_pos.* < sig.len and sig[sig_pos.*] != ')') {
                try this.skipDynamicVariantInner(sig, sig_pos);
            }
            if (sig_pos.* >= sig.len) return error.SignatureEnd;
            sig_pos.* += 1;
        },
        '{' => {
            try this.skipDynamicVariantInner(sig, sig_pos); // key
            try this.skipDynamicVariantInner(sig, sig_pos); // val
            if (sig_pos.* >= sig.len or sig[sig_pos.*] != '}') return error.SignatureEnd;
            sig_pos.* += 1;
        },
        else => return error.UnsupportedDynamicType,
    }
}

fn alignOfDynamicType(this: *Decoder, sig: []const u8, sig_pos: usize) anyerror!usize {
    _ = this;
    if (sig_pos >= sig.len) return error.SignatureEnd;
    switch (sig[sig_pos]) {
        'y', 'g', 'v' => return 1,
        'n', 'q' => return 2,
        'i', 'u', 'b', 'h', 'a', 's', 'o' => return 4,
        'x', 't', 'd', '(', '{' => return 8,
        else => return error.UnsupportedDynamicType,
    }
}

fn freeValue(allocator: Allocator, comptime T: type, value: T) void {
    if (T == Value.GStr or T == Value.GPath or T == Value.GSig) {
        allocator.free(value.s);
    } else switch (@typeInfo(T)) {
        .pointer => |info| {
            if (info.size == .slice) {
                for (value) |item| freeValue(allocator, info.child, item);
                allocator.free(value);
            }
        },
        .@"struct" => |info| {
            inline for (info.field_types, info.field_names) |field, name| {
                freeValue(allocator, field, @field(value, name));
            }
        },
        else => {},
    }
}
