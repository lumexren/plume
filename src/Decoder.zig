// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of plume.
//
// Copyright (c) 2026 erffy
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
const Value = @import("Value.zig");

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

fn alignTo(this: *Decoder, alignment: usize) void {
    const rem = this.pos % alignment;
    if (rem != 0) {
        this.pos += (alignment - rem);
    }
}

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

fn readValue(this: *Decoder, comptime T: type, comptime deep_copy: bool) anyerror!T {
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

            const byte_len = try this.readValue(u32, false);

            this.alignTo(dbusAlignOf(Elem));

            const start_pos = this.pos;
            if (this.pos + byte_len > this.body.len) return error.EndOfBody;

            var list: ArrayList(Elem) = try .initCapacity(this.allocator, 0);
            errdefer {
                if (deep_copy) {
                    for (list.items) |item| {
                        if (Elem == Value.GStr or Elem == Value.GPath or Elem == Value.GSig) {
                            this.allocator.free(item.s);
                        } else switch (@typeInfo(Elem)) {
                            .pointer => this.allocator.free(item),
                            else => {},
                        }
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