const std = @import("std");
const plume = @import("plume");
const Proxy = plume.Proxy;
const GStr = plume.Value.GStr;
const GPath = plume.Value.GPath;
const GSig = plume.Value.GSig;
const GUFd = plume.Value.GUFd;
const GVariant = plume.Value.GVariant;

pub const PropertiesProxy = struct {
    inner: Proxy,

    pub fn init(conn: *plume.Connection) PropertiesProxy {
        return .{ .inner = .init(conn, "org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.DBus.Properties") };
    }

    pub fn Get(self: PropertiesProxy, interface_name: GStr, property_name: GStr) !GVariant {
        var res = try self.inner.call("Get", .{ interface_name, property_name });
        defer res.deinit();
        return res.expectAlloc(GVariant);
    }
    pub fn GetAll(self: PropertiesProxy, interface_name: GStr) !std.StringHashMap(GVariant) {
        var res = try self.inner.call("GetAll", .{interface_name});
        defer res.deinit();
        return res.expectAlloc(std.StringHashMap(GVariant));
    }
    pub fn Set(self: PropertiesProxy, interface_name: GStr, property_name: GStr, value: GVariant) !void {
        var res = try self.inner.call("Set", .{ interface_name, property_name, value });
        res.deinit();
    }
    pub fn connectPropertiesChanged(
        self: PropertiesProxy,
        ctx: anytype,
        comptime callback: fn (@TypeOf(ctx), @Tuple(&[_]type{ GStr, std.StringHashMap(GVariant), []const GStr })) void,
    ) !void {
        try self.inner.connectSignal(@Tuple(&[_]type{ GStr, std.StringHashMap(GVariant), []const GStr }), "PropertiesChanged", ctx, callback);
    }
};

pub const IntrospectableProxy = struct {
    inner: Proxy,

    pub fn init(conn: *plume.Connection) IntrospectableProxy {
        return .{ .inner = .init(conn, "org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.DBus.Introspectable") };
    }

    pub fn Introspect(self: IntrospectableProxy) !GStr {
        var res = try self.inner.call("Introspect", .{});
        defer res.deinit();
        return res.expectAlloc(GStr);
    }
};

pub const PeerProxy = struct {
    inner: Proxy,

    pub fn init(conn: *plume.Connection) PeerProxy {
        return .{ .inner = .init(conn, "org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.DBus.Peer") };
    }

    pub fn Ping(self: PeerProxy) !void {
        var res = try self.inner.call("Ping", .{});
        res.deinit();
    }
    pub fn GetMachineId(self: PeerProxy) !GStr {
        var res = try self.inner.call("GetMachineId", .{});
        defer res.deinit();
        return res.expectAlloc(GStr);
    }
};

pub const UPowerProxy = struct {
    inner: Proxy,

    pub fn init(conn: *plume.Connection) UPowerProxy {
        return .{ .inner = .init(conn, "org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.UPower") };
    }

    pub fn EnumerateDevices(self: UPowerProxy) ![]const GPath {
        var res = try self.inner.call("EnumerateDevices", .{});
        defer res.deinit();
        return res.expectAlloc([]const GPath);
    }
    pub fn EnumerateKbdBacklights(self: UPowerProxy) ![]const GPath {
        var res = try self.inner.call("EnumerateKbdBacklights", .{});
        defer res.deinit();
        return res.expectAlloc([]const GPath);
    }
    pub fn GetDisplayDevice(self: UPowerProxy) !GPath {
        var res = try self.inner.call("GetDisplayDevice", .{});
        defer res.deinit();
        return res.expectAlloc(GPath);
    }
    pub fn GetCriticalAction(self: UPowerProxy) !GStr {
        var res = try self.inner.call("GetCriticalAction", .{});
        defer res.deinit();
        return res.expectAlloc(GStr);
    }
    pub fn connectDeviceAdded(
        self: UPowerProxy,
        ctx: anytype,
        comptime callback: fn (@TypeOf(ctx), @Tuple(&[_]type{GPath})) void,
    ) !void {
        try self.inner.connectSignal(@Tuple(&[_]type{GPath}), "DeviceAdded", ctx, callback);
    }
    pub fn connectDeviceRemoved(
        self: UPowerProxy,
        ctx: anytype,
        comptime callback: fn (@TypeOf(ctx), @Tuple(&[_]type{GPath})) void,
    ) !void {
        try self.inner.connectSignal(@Tuple(&[_]type{GPath}), "DeviceRemoved", ctx, callback);
    }
};
