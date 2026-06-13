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

const plume = @import("plume");
const Proxy = plume.Proxy;
const MethodResult = plume.MethodResult;
const GStr = plume.core.value.GStr;

pub const PropertiesProxy = struct {
    inner: Proxy,

    pub fn init(conn: *plume.Connection) @This() {
        return .{ .inner = Proxy.init(conn, "org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.DBus.Properties") };
    }

    pub fn Get(this: @This(), interface_name: GStr, property_name: GStr) !MethodResult {
        const res = try this.inner.call("Get", .{ interface_name, property_name });
        return res;
    }
    pub fn GetAll(this: @This(), interface_name: GStr) !MethodResult {
        const res = try this.inner.call("GetAll", .{interface_name});
        return res;
    }
    pub fn Set(this: @This(), interface_name: GStr, property_name: GStr, value: anytype) !void {
        var res = try this.inner.call("Set", .{ interface_name, property_name, value });
        res.deinit();
    }
};

pub const IntrospectableProxy = struct {
    inner: Proxy,

    pub fn init(conn: *plume.Connection) @This() {
        return .{ .inner = Proxy.init(conn, "org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.DBus.Introspectable") };
    }

    pub fn Introspect(this: @This()) !GStr {
        var res = try this.inner.call("Introspect", .{});
        return res.expect(GStr);
    }
};

pub const PeerProxy = struct {
    inner: Proxy,

    pub fn init(conn: *plume.Connection) @This() {
        return .{ .inner = Proxy.init(conn, "org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.DBus.Peer") };
    }

    pub fn Ping(this: @This()) !void {
        var res = try this.inner.call("Ping", .{});
        res.deinit();
    }
    pub fn GetMachineId(this: @This()) !GStr {
        var res = try this.inner.call("GetMachineId", .{});
        return res.expect(GStr);
    }
};

pub const UPowerProxy = struct {
    inner: Proxy,

    pub fn init(conn: *plume.Connection) @This() {
        return .{ .inner = Proxy.init(conn, "org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.UPower") };
    }

    pub fn EnumerateDevices(this: @This()) !MethodResult {
        const res = try this.inner.call("EnumerateDevices", .{});
        return res;
    }
    pub fn EnumerateKbdBacklights(this: @This()) !MethodResult {
        const res = try this.inner.call("EnumerateKbdBacklights", .{});
        return res;
    }
    pub fn GetDisplayDevice(this: @This()) !MethodResult {
        const res = try this.inner.call("GetDisplayDevice", .{});
        return res;
    }
    pub fn GetCriticalAction(this: @This()) !GStr {
        var res = try this.inner.call("GetCriticalAction", .{});
        return res.expect(GStr);
    }
};
