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

const Value = @import("Value.zig");

const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const Allocator = mem.Allocator;

/// Generates a D-Bus introspection XML string for a Zig type T.
pub fn generateIntrospectionXml(allocator: Allocator, comptime T: type, interface_name: []const u8) ![:0]const u8 {
    var out: ArrayList(u8) = try .initCapacity(allocator, 1024);
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"");
    try out.appendSlice(allocator, " \"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n");
    try out.appendSlice(allocator, "<node>\n");

    try out.print(allocator, "  <interface name=\"{s}\">\n", .{interface_name});

    // Methods
    inline for (@typeInfo(T).@"struct".decl_names) |decl| {
        const field_val = @field(T, decl);
        const field_type = @TypeOf(field_val);

        if (@typeInfo(field_type) == .@"fn") {
            if (!mem.eql(u8, decl, "init")) {
                const fn_info = @typeInfo(field_type).@"fn";
                // Check if it looks like a method (first arg is *T)
                if (fn_info.param_attrs.len > 0 and fn_info.param_types[0] == *T) {
                    try out.print(allocator, "    <method name=\"{s}\">\n", .{decl});

                    // Args (skip first which is self)
                    inline for (fn_info.param_types[1..], 0..) |param, i| {
                        if (param.type) |PT| {
                            const sig = try getSignature(allocator, PT);
                            defer allocator.free(sig);
                            try out.print(allocator, "      <arg name=\"arg{d}\" type=\"{s}\" direction=\"in\"/>\n", .{ i, sig });
                        }
                    }

                    // Return type
                    const RetT = fn_info.return_type.?;
                    const CleanRetT = switch (@typeInfo(RetT)) {
                        .error_union => |eu| eu.payload,
                        else => RetT,
                    };

                    if (CleanRetT != void) {
                        const sig = try getSignature(allocator, CleanRetT);
                        defer allocator.free(sig);
                        try out.print(allocator, "      <arg name=\"ret\" type=\"{s}\" direction=\"out\"/>\n", .{sig});
                    }

                    try out.appendSlice(allocator, "    </method>\n");
                }
            }
        }
    }

    // Signals
    inline for (@typeInfo(T).@"struct".field_types, @typeInfo(T).@"struct".field_names) |field_type, field_name| {
        if (@typeInfo(field_type) == .@"struct" and @hasDecl(field_type, "__is_plume_signal")) {
            const PayloadT = field_type.PayloadType;
            try out.print(allocator, "    <signal name=\"{s}\">\n", .{field_name});
            const sig = try getSignature(allocator, PayloadT);
            defer allocator.free(sig);
            try out.print(allocator, "      <arg type=\"{s}\" />\n", .{sig});
            try out.appendSlice(allocator, "    </signal>\n");
        }
    }

    // Properties
    inline for (@typeInfo(T).@"struct".field_types, @typeInfo(T).@"struct".field_names) |field_type, field_name| {
        const type_info = @typeInfo(field_type);

        // Skip signals and connection
        if (type_info == .@"struct" and @hasDecl(field_type, "__is_plume_signal")) continue;
        if (comptime mem.eql(u8, field_name, "conn")) continue;
        if (type_info == .pointer and type_info.pointer.size != .slice) continue; // Skip unsupported pointers

        const is_wrapped = type_info == .@"struct" and @hasDecl(field_type, "__is_plume_property");
        const access: []const u8 = if (is_wrapped) switch (field_type.AccessMode) {
            .Read => "read",
            .Write => "write",
            .ReadWrite => "readwrite",
        } else "read";
        const DataType = if (is_wrapped) field_type.DataType else field_type;

        const sig = try getSignature(allocator, DataType);
        defer allocator.free(sig);
        try out.print(allocator, "    <property name=\"{s}\" type=\"{s}\" access=\"{s}\"/>\n", .{ field_name, sig, access });
    }

    try out.appendSlice(allocator, "  </interface>\n");
    try out.appendSlice(allocator, "  <interface name=\"org.freedesktop.DBus.Introspectable\">\n");
    try out.appendSlice(allocator, "    <method name=\"Introspect\">\n");
    try out.appendSlice(allocator, "      <arg name=\"xml_data\" type=\"s\" direction=\"out\"/>\n");
    try out.appendSlice(allocator, "    </method>\n");
    try out.appendSlice(allocator, "  </interface>\n");

    try out.appendSlice(allocator, "  <interface name=\"org.freedesktop.DBus.Properties\">\n");
    try out.appendSlice(allocator, "    <method name=\"Get\">\n");
    try out.appendSlice(allocator, "      <arg name=\"interface_name\" type=\"s\" direction=\"in\"/>\n");
    try out.appendSlice(allocator, "      <arg name=\"property_name\" type=\"s\" direction=\"in\"/>\n");
    try out.appendSlice(allocator, "      <arg name=\"value\" type=\"v\" direction=\"out\"/>\n");
    try out.appendSlice(allocator, "    </method>\n");
    try out.appendSlice(allocator, "    <method name=\"Set\">\n");
    try out.appendSlice(allocator, "      <arg name=\"interface_name\" type=\"s\" direction=\"in\"/>\n");
    try out.appendSlice(allocator, "      <arg name=\"property_name\" type=\"s\" direction=\"in\"/>\n");
    try out.appendSlice(allocator, "      <arg name=\"value\" type=\"v\" direction=\"in\"/>\n");
    try out.appendSlice(allocator, "    </method>\n");
    try out.appendSlice(allocator, "    <method name=\"GetAll\">\n");
    try out.appendSlice(allocator, "      <arg name=\"interface_name\" type=\"s\" direction=\"in\"/>\n");
    try out.appendSlice(allocator, "      <arg name=\"props\" type=\"a{sv}\" direction=\"out\"/>\n");
    try out.appendSlice(allocator, "    </method>\n");
    try out.appendSlice(allocator, "    <signal name=\"PropertiesChanged\">\n");
    try out.appendSlice(allocator, "      <arg name=\"interface_name\" type=\"s\"/>\n");
    try out.appendSlice(allocator, "      <arg name=\"changed_properties\" type=\"a{sv}\"/>\n");
    try out.appendSlice(allocator, "      <arg name=\"invalidated_properties\" type=\"as\"/>\n");
    try out.appendSlice(allocator, "    </signal>\n");
    try out.appendSlice(allocator, "  </interface>\n");
    try out.appendSlice(allocator, "</node>\n");

    return try out.toOwnedSliceSentinel(allocator, 0);
}

fn getSignature(allocator: Allocator, comptime T: type) ![:0]const u8 {
    const len = Value.reprLength(T);
    var sig_buf: [256]u8 = undefined;
    if (len > 256) return error.SignatureTooLong;
    Value.getRepr(T, len, 0, sig_buf[0..len]);
    return try allocator.dupeSentinel(u8, sig_buf[0..len], 0);
}
