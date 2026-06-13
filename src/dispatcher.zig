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

const Decoder = @import("Decoder.zig");
const Encoder = @import("Encoder.zig");
const Value = @import("Value.zig");
const GStr = Value.GStr;
const GPath = Value.GPath;
const GSig = Value.GSig;
const GUFd = Value.GUFd;
const Message = @import("Message.zig");
const MessageHeader = Message.MessageHeader;
const HeaderField = Message.HeaderField;
const Connection = @import("Connection.zig");

const std = @import("std");
const StringHashMap = std.StringHashMap;
const mem = std.mem;
const meta = std.meta;

const common = @import("common.zig");

pub fn getDispatchFn(comptime T: type) fn (*const common.InterfaceWrapper, *Connection, Message) anyerror!void {
    return struct {
        fn dispatch(w: *const common.InterfaceWrapper, connection: *Connection, message: Message) anyerror!void {
            const self_obj = @as(*T, @ptrCast(@alignCast(w.instance)));

            var member_name: ?[]const u8 = null;
            var iface_name: ?[]const u8 = null;
            for (message.header.header_fields) |f| {
                switch (f.value) {
                    .Member => |m| member_name = m,
                    .Interface => |i| iface_name = i,
                    else => {},
                }
            }
            const member = member_name orelse return;

            // PropUnion Generation
            const PropUnion = blk: {
                comptime var union_fields_name: []const [:0]const u8 = &.{};
                comptime var union_fields_type: []const type = &.{};

                comptime var enum_fields_value: []const u16 = &.{};
                comptime var enum_fields_name: []const [:0]const u8 = &.{};
                comptime var count: usize = 0;

                const struct_info = @typeInfo(T).@"struct";
                inline for (struct_info.field_names, struct_info.field_types) |field_name, field_type| {
                    const type_info = @typeInfo(field_type);
                    const DataType = if (type_info == .@"struct" and @hasDecl(field_type, "__is_plume_property")) field_type.DataType else field_type;
                    const is_prop = if (type_info == .@"struct" and @hasDecl(field_type, "__is_plume_property")) true else pblk: {
                        const is_signal = (type_info == .@"struct" and @hasDecl(field_type, "__is_plume_signal"));
                        const is_conn = mem.eql(u8, field_name, "conn");
                        const is_ptr = (type_info == .pointer and type_info.pointer.size != .slice);
                        break :pblk !is_signal and !is_conn and !is_ptr;
                    };

                    if (is_prop) {
                        union_fields_name = union_fields_name ++ &[_][:0]const u8{field_name};
                        union_fields_type = union_fields_type ++ &[_]type{DataType};
                        enum_fields_name = enum_fields_name ++ &[_][:0]const u8{field_name};
                        enum_fields_value = enum_fields_value ++ &[_]u16{count};
                        count += 1;
                    }
                }

                if (count == 0) break :blk union { _dummy: void };

                const c = count;

                const TagType = @Enum(u16, .exhaustive, enum_fields_name[0..c], enum_fields_value[0..c]);

                break :blk @Union(
                    .auto,
                    TagType,
                    union_fields_name[0..c],
                    union_fields_type[0..c],
                    &@splat(.{}),
                );
            };

            if (iface_name != null and mem.eql(u8, iface_name.?, "org.freedesktop.DBus.Properties")) {
                if (mem.eql(u8, member, "GetAll")) {
                    var decoder: Decoder = .from(connection.allocator, message);
                    const requested_iface = decoder.decode(GStr) catch {
                        try connection.sendError(message, "org.freedesktop.DBus.Error.InvalidArgs", "Invalid interface argument");
                        return;
                    };
                    if (mem.eql(u8, requested_iface.s, w.interface_name)) {
                        const VariantType = Value.Variant(PropUnion);
                        var dict: StringHashMap(VariantType) = .init(connection.allocator);
                        defer dict.deinit();

                        const struct_info = @typeInfo(T).@"struct";
                        inline for (struct_info.field_names, struct_info.field_types) |field_name, field_type| {
                            const field_type_info = @typeInfo(field_type);
                            const is_wrapped = field_type_info == .@"struct" and @hasDecl(field_type, "__is_plume_property");
                            const is_prop = is_wrapped or blk: {
                                const is_signal = (field_type_info == .@"struct" and @hasDecl(field_type, "__is_plume_signal"));
                                const is_conn = mem.eql(u8, field_name, "conn");
                                const is_ptr = (field_type_info == .pointer and field_type_info.pointer.size != .slice);
                                break :blk !is_signal and !is_conn and !is_ptr;
                            };
                            const readable = if (is_wrapped) field_type.AccessMode != .Write else true;

                            if (is_prop and readable) {
                                const val_field = @field(self_obj, field_name);
                                const val = if (is_wrapped) val_field.value else val_field;
                                try dict.put(field_name, VariantType.new(@unionInit(PropUnion, field_name, val)));
                            }
                        }

                        var encoder: Encoder = try .encode(connection.allocator, Value.Dict(GStr, VariantType, StringHashMap(VariantType)).new(dict));
                        defer encoder.deinit();

                        try connection.sendReply(message, encoder);
                    } else {
                        const VariantType = Value.Variant(PropUnion);
                        var dict: StringHashMap(VariantType) = .init(connection.allocator);
                        defer dict.deinit();

                        var encoder: Encoder = try .encode(connection.allocator, Value.Dict(GStr, VariantType, StringHashMap(VariantType)).new(dict));
                        defer encoder.deinit();

                        try connection.sendReply(message, encoder);
                    }
                    return;
                } else if (mem.eql(u8, member, "Get")) {
                    var decoder: Decoder = .from(connection.allocator, message);

                    const requested_iface = decoder.decode(GStr) catch {
                        try connection.sendError(message, "org.freedesktop.DBus.Error.InvalidArgs", "Invalid interface argument");
                        return;
                    };

                    const prop_name = decoder.decode(GStr) catch {
                        try connection.sendError(message, "org.freedesktop.DBus.Error.InvalidArgs", "Invalid property name argument");
                        return;
                    };

                    if (mem.eql(u8, requested_iface.s, w.interface_name)) {
                        const VariantType = Value.Variant(PropUnion);
                        var found = false;
                        var val_variant: VariantType = undefined;

                        const struct_info = @typeInfo(T).@"struct";
                        inline for (struct_info.field_types, struct_info.field_names) |f, f_name| {
                            if (!found and mem.eql(u8, f_name, prop_name.s)) {
                                const FType = f;
                                const type_info = @typeInfo(FType);
                                const is_wrapped = type_info == .@"struct" and @hasDecl(FType, "__is_plume_property");
                                const is_prop = is_wrapped or blk: {
                                    const is_signal = (type_info == .@"struct" and @hasDecl(FType, "__is_plume_signal"));
                                    const is_conn = mem.eql(u8, f_name, "conn");
                                    const is_ptr = (type_info == .pointer and type_info.pointer.size != .slice);
                                    break :blk !is_signal and !is_conn and !is_ptr;
                                };
                                const readable = if (is_wrapped) FType.AccessMode != .Write else true;

                                if (is_prop) {
                                    if (readable) {
                                        const val_field = @field(self_obj, f_name);
                                        const val = if (is_wrapped) val_field.value else val_field;
                                        val_variant = VariantType.new(@unionInit(PropUnion, f_name, val));
                                        found = true;
                                    }
                                }
                            }
                        }

                        if (found) {
                            var encoder: Encoder = try .encode(connection.allocator, val_variant);
                            defer encoder.deinit();
                            try connection.sendReply(message, encoder);
                        }
                    }

                    return;
                } else if (mem.eql(u8, member, "Set")) {
                    var decoder: Decoder = .from(connection.allocator, message);
                    const requested_iface = decoder.decode(GStr) catch {
                        try connection.sendError(message, "org.freedesktop.DBus.Error.InvalidArgs", "Invalid interface argument");
                        return;
                    };

                    const prop_name = decoder.decode(GStr) catch {
                        try connection.sendError(message, "org.freedesktop.DBus.Error.InvalidArgs", "Invalid property name argument");
                        return;
                    };

                    const val_union = decoder.decode(PropUnion) catch {
                        try connection.sendError(message, "org.freedesktop.DBus.Error.InvalidSignature", "Property value signature mismatch");
                        return;
                    };

                    if (mem.eql(u8, requested_iface.s, w.interface_name)) {
                        var found = false;
                        const struct_info = @typeInfo(T).@"struct";
                        inline for (struct_info.field_types, struct_info.field_names) |f, f_name| {
                            if (!found and mem.eql(u8, f_name, prop_name.s)) {
                                const FType = f;
                                const type_info = @typeInfo(FType);
                                const is_wrapped = type_info == .@"struct" and @hasDecl(FType, "__is_plume_property");
                                const is_prop = is_wrapped or blk: {
                                    const is_signal = (type_info == .@"struct" and @hasDecl(FType, "__is_plume_signal"));
                                    const is_conn = mem.eql(u8, f_name, "conn");
                                    const is_ptr = (type_info == .pointer and type_info.pointer.size != .slice);
                                    break :blk !is_signal and !is_conn and !is_ptr;
                                };

                                const writable = if (is_wrapped) FType.AccessMode != .Read else false;

                                if (is_prop) {
                                    if (writable) {
                                        if (meta.activeTag(val_union) == meta.stringToEnum(meta.Tag(PropUnion), f_name)) {
                                            const new_val = @field(val_union, f_name);

                                            if (is_wrapped) {
                                                @field(self_obj, f_name).value = new_val;
                                            } else {
                                                @field(self_obj, f_name) = new_val;
                                            }

                                            found = true;

                                            // Emit PropertiesChanged signal
                                            {
                                                const VariantType = Value.Variant(PropUnion);
                                                var dict: StringHashMap(VariantType) = .init(connection.allocator);
                                                defer dict.deinit();

                                                try dict.put(f_name, VariantType.new(@unionInit(PropUnion, f_name, new_val)));

                                                const empty_strs = [_]GStr{};
                                                const args = .{ GStr.new(w.interface_name), Value.Dict(GStr, VariantType, StringHashMap(VariantType)).new(dict), Value.Array(GStr).new(&empty_strs) };

                                                var sig_encoder: Encoder = try .encode(connection.allocator, args);
                                                defer sig_encoder.deinit();

                                                const serial = connection.serial_counter;
                                                connection.serial_counter += 1;

                                                const sig_header: MessageHeader = .{
                                                    .message_type = .Signal,
                                                    .flags = 0,
                                                    .proto_version = 1,
                                                    .body_length = @intCast(sig_encoder.body().len),
                                                    .serial = serial,
                                                    .header_fields = @constCast(&[_]HeaderField{
                                                        .{ .code = .Path, .value = .{ .Path = w.path } },
                                                        .{ .code = .Interface, .value = .{ .Interface = "org.freedesktop.DBus.Properties" } },
                                                        .{ .code = .Member, .value = .{ .Member = "PropertiesChanged" } },
                                                        .{ .code = .Signature, .value = .{ .Signature = sig_encoder.signature() } },
                                                    }),
                                                };

                                                const sig_message: Message = .new(sig_header, sig_encoder.body());
                                                try connection.sendMessage(sig_message);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if (found) {
                            var encoder: Encoder = try .encode(connection.allocator, .{}); // Void return;
                            defer encoder.deinit();
                            try connection.sendReply(message, encoder);
                        }
                    }
                    return;
                }
            }

            // Handle Introspect
            if (iface_name) |iface| {
                if (mem.eql(u8, iface, "org.freedesktop.DBus.Introspectable") and mem.eql(u8, member, "Introspect")) {
                    // Return XML
                    var encoder: Encoder = try .encode(connection.allocator, GStr.new(w.intro_xml));
                    defer encoder.deinit();

                    try connection.sendReply(message, encoder);

                    return;
                }
            }

            // Dispatch to method
            inline for (@typeInfo(T).@"struct".decl_names) |decl_name| {
                const field_val = @field(T, decl_name);
                const field_type = @TypeOf(field_val);

                if (@typeInfo(field_type) == .@"fn") {
                    if (!mem.eql(u8, decl_name, "init")) {
                        const fn_info = @typeInfo(field_type).@"fn";
                        if (fn_info.param_types.len > 0 and fn_info.param_types[0] == *T) {
                            if (mem.eql(u8, member, decl_name)) {
                                var decoder: Decoder = .from(connection.allocator, message);
                                const ArgsType = meta.ArgsTuple(field_type);

                                var args: ArgsType = undefined;
                                args[0] = self_obj;

                                inline for (fn_info.param_types[1..], 1..) |param, i| {
                                    args[i] = try decoder.decode(param.?);
                                }

                                const result = try @call(.auto, field_val, args);

                                var encoder: Encoder = try .encode(connection.allocator, result);
                                defer encoder.deinit();

                                try connection.sendReply(message, encoder);

                                return;
                            }
                        }
                    }
                }
            }
        }
    }.dispatch;
}
