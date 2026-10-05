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

const Message = @import("Message.zig");
const Value = @import("value/Value.zig");
const dbusAlignOf = Value.dbusAlignOf;

const std = @import("std");
const StringHashMap = std.StringHashMap;
const ArrayList = std.ArrayList;
const Endian = std.lang.Endian;
const mem = std.mem;
const Allocator = mem.Allocator;

allocator: Allocator,
body: []const u8,
signature: []const u8,
pos: usize = 0,
sig_pos: usize = 0,
endian: Endian,
fds: []const std.posix.fd_t = &.{},

/// Initializes a decoder with raw body and signature.
pub fn init(allocator: Allocator, body: []const u8, signature: []const u8, endian: Endian) Decoder {
    return .{ .allocator = allocator, .body = body, .signature = signature, .endian = endian, .fds = &.{} };
}

/// Initializes a decoder with raw body, signature, and out-of-band file descriptors.
pub fn initWithFds(allocator: Allocator, body: []const u8, signature: []const u8, endian: Endian, fds: []const std.posix.fd_t) Decoder {
    return .{
        .allocator = allocator,
        .body = body,
        .signature = signature,
        .endian = endian,
        .fds = fds,
    };
}

/// Initializes a decoder from a Message, extracting the signature from header fields.
pub fn fromMessage(allocator: Allocator, message: Message) Decoder {
    var sig: []const u8 = "";
    for (message.header.header_fields) |field| {
        if (field.code == .Signature) {
            sig = field.value.Signature;
            break;
        }
    }

    return .{
        .allocator = allocator,
        .body = message.body,
        .signature = sig,
        .endian = message.header.endianess,
        .fds = message.fds,
    };
}

fn alignTo(this: *Decoder, alignment: usize) void {
    const rem = this.pos % alignment;
    if (rem != 0) this.pos += (alignment - rem);
}

/// Decodes the next value of type T from the body.
/// Returns error.SignatureMismatch if the body signature doesn't match T's D-Bus representation.
pub fn decode(this: *Decoder, comptime T: type) anyerror!T {
    const sig_len = Value.reprLength(T);
    var expected_sig: [256]u8 = undefined;
    Value.getRepr(T, sig_len, 0, expected_sig[0..sig_len]);

    if (this.sig_pos + sig_len > this.signature.len) return error.SignatureEnd;
    if (!mem.eql(u8, this.signature[this.sig_pos .. this.sig_pos + sig_len], expected_sig[0..sig_len])) return error.SignatureMismatch;

    this.sig_pos += sig_len;

    this.alignTo(dbusAlignOf(T));

    return this.readVal(T, false);
}

/// Decodes the next value of type T and allocates memory for it (recursive deep-copy).
/// This allows the returned value to outlive the decoder and the message body.
pub fn decodeAlloc(this: *Decoder, comptime T: type) anyerror!T {
    const sig_len = Value.reprLength(T);
    var expected_sig: [256]u8 = undefined;
    Value.getRepr(T, sig_len, 0, expected_sig[0..sig_len]);

    if (this.sig_pos + sig_len > this.signature.len) return error.SignatureEnd;
    if (!mem.eql(u8, this.signature[this.sig_pos .. this.sig_pos + sig_len], expected_sig[0..sig_len])) return error.SignatureMismatch;

    this.sig_pos += sig_len;

    this.alignTo(dbusAlignOf(T));

    return this.readVal(T, true);
}

fn readVal(this: *Decoder, comptime T: type, comptime deep_copy: bool) anyerror!T {
    if (comptime Value.isDict(T)) {
        const byte_len = try this.readVal(u32, false);
        this.alignTo(8);

        const start_pos = this.pos;
        if (this.pos + byte_len > this.body.len) return error.EndOfBody;

        var map: T = .init(this.allocator);
        errdefer map.deinit();

        while (this.pos - start_pos < byte_len) {
            this.alignTo(8);
            const kv = Value.dictKV(T);
            const K = kv.key;
            const V = kv.val;
            const key = if (K == []const u8 or K == [:0]const u8 or K == []u8 or K == [:0]u8) blk: {
                if (this.pos + 4 > this.body.len) return error.EndOfBody;
                const len = mem.readInt(u32, this.body[this.pos..][0..4], this.endian);
                this.pos += 4;
                if (this.pos + len + 1 > this.body.len) return error.EndOfBody;
                if (this.body[this.pos + len] != 0) return error.MissingNullTerminator;
                const s = this.body[this.pos .. this.pos + len :0];
                this.pos += len + 1;
                if (deep_copy) {
                    const new_s = try this.allocator.allocSentinel(u8, s.len, 0);
                    @memcpy(new_s, s);
                    break :blk new_s;
                } else {
                    break :blk s;
                }
            } else try this.readVal(K, deep_copy);

            this.alignTo(dbusAlignOf(V));
            const val = try this.readVal(V, deep_copy);
            try map.put(key, val);
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
                // String reading: u32 len, bytes, null
                if (this.pos + 4 > this.body.len) return error.EndOfBody;
                const len = mem.readInt(u32, this.body[this.pos..][0..4], this.endian);
                this.pos += 4;

                if (this.pos + len + 1 > this.body.len) return error.EndOfBody;
                // Verify null terminator
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
            } else if (T == Value.GSig) {
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
            } else if (T == Value.GUFd) {
                this.alignTo(4);
                if (this.pos + 4 > this.body.len) return error.EndOfBody;
                const val = mem.readInt(u32, this.body[this.pos..][0..4], this.endian);
                this.pos += 4;
                return Value.GUFd.new(val);
            } else if (T == Value.ResolvedFd) {
                this.alignTo(4);
                if (this.pos + 4 > this.body.len) return error.EndOfBody;
                const idx = mem.readInt(u32, this.body[this.pos..][0..4], this.endian);
                this.pos += 4;
                if (idx >= this.fds.len) return error.MissingUnixFds;
                const os_fd = this.fds[idx];
                if (os_fd < 0) return error.AlreadyTaken;
                return Value.ResolvedFd.init(os_fd, idx);
            }

            // Generic struct/tuple/dict-entry support
            // DBus aligns structs and dict-entries to 8.
            const is_dict_entry = info.field_names.len == 2 and (mem.eql(u8, info.field_names[0], "key") and mem.eql(u8, info.field_names[1], "value"));
            var result: T = undefined;
            inline for (info.field_names, info.field_types) |FieldName, FieldType| {
                this.alignTo(dbusAlignOf(FieldType));
                if (is_dict_entry and (FieldType == []const u8 or FieldType == [:0]const u8 or FieldType == []u8 or FieldType == [:0]u8) and mem.eql(u8, FieldName, "key")) {
                    if (this.pos + 4 > this.body.len) return error.EndOfBody;
                    const len = mem.readInt(u32, this.body[this.pos..][0..4], this.endian);
                    this.pos += 4;
                    if (this.pos + len + 1 > this.body.len) return error.EndOfBody;
                    if (this.body[this.pos + len] != 0) return error.MissingNullTerminator;
                    const s = this.body[this.pos .. this.pos + len :0];
                    this.pos += len + 1;
                    if (deep_copy) {
                        const new_s = try this.allocator.allocSentinel(u8, s.len, 0);
                        @memcpy(new_s, s);
                        @field(result, FieldName) = new_s;
                    } else {
                        @field(result, FieldName) = s;
                    }
                } else {
                    @field(result, FieldName) = try this.readVal(FieldType, deep_copy);
                }
            }
            return result;
        },
        .pointer => |info| {
            if (info.size != .slice) return error.UnsupportedType;
            const Elem = info.child;

            // Read byte length (u32)
            const byte_len = try this.readVal(u32, false); // No need to deep copy length

            // Align to element boundary
            this.alignTo(dbusAlignOf(Elem));

            const start_pos = this.pos;
            if (this.pos + byte_len > this.body.len) return error.EndOfBody;

            var list: ArrayList(Elem) = try .initCapacity(this.allocator, 0);
            errdefer list.deinit(this.allocator);

            while (this.pos - start_pos < byte_len) {
                this.alignTo(dbusAlignOf(Elem));
                try list.append(this.allocator, try this.readVal(Elem, deep_copy));
            }

            return try list.toOwnedSlice(this.allocator);
        },
        .@"union" => |info| {
            // Variants on wire: signature ('g'), then aligned value.
            const GSig = Value.GSig;
            const inner_sig_struct = try this.readVal(GSig, false); // Signature borrowed is fine here for comparison
            const inner_sig = inner_sig_struct.s;

            if (T == Value.GVariant) return try this.readDynamicVariant(inner_sig, deep_copy);

            inline for (info.field_names, info.field_types) |FieldName, FieldType| {
                const fld_sig_len = Value.reprLength(FieldType);
                var fld_sig_buf: [256]u8 = undefined;
                Value.getRepr(FieldType, fld_sig_len, 0, fld_sig_buf[0..fld_sig_len]);

                if (mem.eql(u8, inner_sig, fld_sig_buf[0..fld_sig_len])) {
                    this.alignTo(dbusAlignOf(FieldType));
                    return @unionInit(T, FieldName, try this.readVal(FieldType, deep_copy));
                }
            }

            return error.NoMatchingUnionField;
        },
        else => return error.UnsupportedType,
    }
}

fn readDynamicVariant(this: *Decoder, sig: []const u8, comptime deep_copy: bool) anyerror!Value.GVariant {
    var pos: usize = 0;
    return this.readDynamicVariantInner(sig, &pos, deep_copy);
}

fn readDynamicVariantInner(this: *Decoder, sig: []const u8, sig_pos: *usize, comptime deep_copy: bool) anyerror!Value.GVariant {
    if (sig_pos.* >= sig.len) return error.SignatureEnd;
    const c = sig[sig_pos.*];
    sig_pos.* += 1;
    switch (c) {
        'y' => {
            this.alignTo(dbusAlignOf(u8));
            return .{ .byte = try this.readVal(u8, deep_copy) };
        },
        'b' => {
            this.alignTo(dbusAlignOf(bool));
            return .{ .boolean = try this.readVal(bool, deep_copy) };
        },
        'n' => {
            this.alignTo(dbusAlignOf(i16));
            return .{ .int16 = try this.readVal(i16, deep_copy) };
        },
        'q' => {
            this.alignTo(dbusAlignOf(u16));
            return .{ .uint16 = try this.readVal(u16, deep_copy) };
        },
        'i' => {
            this.alignTo(dbusAlignOf(i32));
            return .{ .int32 = try this.readVal(i32, deep_copy) };
        },
        'u' => {
            this.alignTo(dbusAlignOf(u32));
            return .{ .uint32 = try this.readVal(u32, deep_copy) };
        },
        'x' => {
            this.alignTo(dbusAlignOf(i64));
            return .{ .int64 = try this.readVal(i64, deep_copy) };
        },
        't' => {
            this.alignTo(dbusAlignOf(u64));
            return .{ .uint64 = try this.readVal(u64, deep_copy) };
        },
        'd' => {
            this.alignTo(dbusAlignOf(f64));
            return .{ .double = try this.readVal(f64, deep_copy) };
        },
        'h' => {
            this.alignTo(dbusAlignOf(Value.GUFd));
            return .{ .ufd = try this.readVal(Value.GUFd, deep_copy) };
        },
        's' => {
            this.alignTo(dbusAlignOf(Value.GStr));
            return .{ .string = try this.readVal(Value.GStr, deep_copy) };
        },
        'o' => {
            this.alignTo(dbusAlignOf(Value.GPath));
            return .{ .object_path = try this.readVal(Value.GPath, deep_copy) };
        },
        'g' => {
            this.alignTo(dbusAlignOf(Value.GSig));
            return .{ .signature = try this.readVal(Value.GSig, deep_copy) };
        },
        'v' => {
            const inner_sig_struct = try this.readVal(Value.GSig, false);
            const inner_sig = inner_sig_struct.s;
            const inner_v = try this.readDynamicVariant(inner_sig, deep_copy);
            if (deep_copy) {
                const ptr = try this.allocator.create(Value.GVariant);
                ptr.* = inner_v;
                return .{ .variant = ptr };
            } else {
                return error.VariantCannotBeBorrowed;
            }
        },
        'a' => {
            if (sig_pos.* >= sig.len) return error.SignatureEnd;
            const is_dict = sig[sig_pos.*] == '{';

            this.alignTo(dbusAlignOf(u32));
            const byte_len = try this.readVal(u32, false);

            if (is_dict) {
                this.alignTo(8);

                const start_pos = this.pos;
                if (this.pos + byte_len > this.body.len) return error.EndOfBody;

                if (!deep_copy) return error.DictCannotBeBorrowed;

                var dict: StringHashMap(Value.GVariant) = .init(this.allocator);
                errdefer dict.deinit();

                sig_pos.* += 1;
                const key_type = sig[sig_pos.*];
                if (key_type != 's' and key_type != 'o' and key_type != 'g') return error.UnsupportedDictKeyType;

                const dict_entry_sig_start = sig_pos.*;

                while (this.pos - start_pos < byte_len) {
                    this.alignTo(8);
                    sig_pos.* = dict_entry_sig_start;

                    const key_variant = try this.readDynamicVariantInner(sig, sig_pos, deep_copy);
                    const key_str = switch (key_variant) {
                        .string => |s| s.s,
                        .object_path => |o| o.s,
                        .signature => |s| s.s,
                        else => unreachable,
                    };

                    const val_variant = try this.readDynamicVariantInner(sig, sig_pos, deep_copy);

                    try dict.put(key_str, val_variant);

                    if (sig[sig_pos.*] != '}') return error.ExpectedDictEnd;
                }

                if (byte_len == 0) {
                    try this.skipDynamicVariantInner(sig, sig_pos); // skip key
                    try this.skipDynamicVariantInner(sig, sig_pos); // skip val
                    if (sig_pos.* >= sig.len or sig[sig_pos.*] != '}') return error.ExpectedDictEnd;
                    sig_pos.* += 1; // skip '}'
                } else {
                    sig_pos.* += 1;
                }

                return .{ .dict = dict };
            } else {
                const elem_align = try alignOfDynamicType(sig, sig_pos.*);
                this.alignTo(elem_align);

                const start_pos = this.pos;
                if (this.pos + byte_len > this.body.len) return error.EndOfBody;

                if (!deep_copy) return error.ArrayCannotBeBorrowed;

                var list: ArrayList(Value.GVariant) = try .initCapacity(this.allocator, 0);
                errdefer list.deinit(this.allocator);

                const elem_sig_start = sig_pos.*;

                while (this.pos - start_pos < byte_len) {
                    this.alignTo(elem_align);
                    sig_pos.* = elem_sig_start;
                    const elem_v = try this.readDynamicVariantInner(sig, sig_pos, deep_copy);
                    try list.append(this.allocator, elem_v);
                }

                if (byte_len == 0) _ = try this.skipDynamicVariantInner(sig, sig_pos);

                return .{ .array = try list.toOwnedSlice(this.allocator) };
            }
        },
        '(' => {
            this.alignTo(8);
            if (!deep_copy) return error.TupleCannotBeBorrowed;

            var list: ArrayList(Value.GVariant) = try .initCapacity(this.allocator, 0);
            errdefer list.deinit(this.allocator);

            while (sig_pos.* < sig.len and sig[sig_pos.*] != ')') {
                const elem_v = try this.readDynamicVariantInner(sig, sig_pos, deep_copy);
                try list.append(this.allocator, elem_v);
            }

            if (sig_pos.* >= sig.len or sig[sig_pos.*] != ')') return error.ExpectedTupleEnd;
            sig_pos.* += 1;

            return .{ .tuple = try list.toOwnedSlice(this.allocator) };
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
            while (sig_pos.* < sig.len and sig[sig_pos.*] != ')') try this.skipDynamicVariantInner(sig, sig_pos);

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

fn alignOfDynamicType(sig: []const u8, sig_pos: usize) anyerror!usize {
    if (sig_pos >= sig.len) return error.SignatureEnd;
    switch (sig[sig_pos]) {
        'y', 'g', 'v' => return 1,
        'n', 'q' => return 2,
        'i', 'u', 'b', 'h', 'a', 's', 'o' => return 4,
        'x', 't', 'd', '(', '{' => return 8,
        else => return error.UnsupportedDynamicType,
    }
}

test "Encoder and Decoder ResolvedFd and []ResolvedFd" {
    const testing = std.testing;
    const Encoder = @import("Encoder.zig");
    const allocator = testing.allocator;

    const mock_fds = [_]std.posix.fd_t{ 42, 84 };
    var enc1 = try Encoder.encode(allocator, Value.GUFd.new(1));
    defer enc1.deinit();

    try testing.expectEqualStrings("h", enc1.signature());

    var dec1 = Decoder.initWithFds(allocator, enc1.body(), enc1.signature(), .little, &mock_fds);
    const rfd = try dec1.decode(Value.ResolvedFd);
    try testing.expectEqual(@as(u32, 1), rfd.index);
    try testing.expectEqual(@as(std.posix.fd_t, 84), rfd.handle);

    const fd_indices = [_]Value.ResolvedFd{
        Value.ResolvedFd.init(-1, 0),
        Value.ResolvedFd.init(-1, 1),
    };
    var enc2 = try Encoder.encode(allocator, &fd_indices);
    defer enc2.deinit();

    try testing.expectEqualStrings("ah", enc2.signature());

    var dec2 = Decoder.initWithFds(allocator, enc2.body(), enc2.signature(), .little, &mock_fds);
    const resolved_slice = try dec2.decode([]Value.ResolvedFd);
    defer allocator.free(resolved_slice);

    try testing.expectEqual(@as(usize, 2), resolved_slice.len);
    try testing.expectEqual(@as(u32, 0), resolved_slice[0].index);
    try testing.expectEqual(@as(std.posix.fd_t, 42), resolved_slice[0].handle);
    try testing.expectEqual(@as(u32, 1), resolved_slice[1].index);
    try testing.expectEqual(@as(std.posix.fd_t, 84), resolved_slice[1].handle);

    var enc3 = try Encoder.encode(allocator, Value.GUFd.new(5));
    defer enc3.deinit();
    var dec3 = Decoder.initWithFds(allocator, enc3.body(), enc3.signature(), .little, &mock_fds);
    try testing.expectError(error.MissingUnixFds, dec3.decode(Value.ResolvedFd));
}
