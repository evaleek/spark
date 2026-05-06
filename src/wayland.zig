pub const wire = @import("wayland/wire.zig");
pub const protocol = wire.protocol;


pub const AnyEvent = any_event: {
    const names = std.meta.fieldNames(protocol.Interface);
    var types: [names.len]type = undefined;
    var attrs: [names.len]std.builtin.Type.UnionField.Attributes = undefined;
    for (std.meta.tags(protocol.Interface), &types, &attrs) |interface, *@"type", *attr| {
        const Object = interface.GetObject();
        // TODO make interfaces with no events/requests an enum with no fields instead of absent
        @"type".* = if (@hasDecl(Object, "Event")) Object.Event.Message else void;
        attr.* = .{
            .@"align" = @alignOf(@"type".*),
        };
    }
    break :any_event @Union(.auto, protocol.Interface, names, &types, &attrs);
};

/// For a set of unique objects defined by an enum `Object`,
/// map their bound ids by simple linear search.
pub fn IdArray(comptime Object: type) type {
    if (@typeInfo(Object) != .@"enum") @compileError("expected enum type, found " ++ @typeName(Object));
    return struct {
        const Array = @This();

        pub const Indexer = std.enums.EnumIndexer(Object);
        pub const Key = Indexer.Key;
        pub const len = Indexer.count;

        ids: [len]u32,

        pub const empty: Array = .{ .ids = @splat(null_id) };
        pub const null_id: u32 = wire.object_id.@"null";

        /// Asserts that `object` is not yet bound to an id,
        /// that the `id` is not already bound to another object,
        /// and that the `id` is within the valid object id range.
        pub fn bind(array: *Array, object: Object, id: u32) void {
            const min_id, const max_id = wire.object_id.client_range;
            comptime { if (min_id != 2) unreachable; }
            comptime { if (wire.object_id.display != 1) unreachable; }
            if (id == null_id) unreachable;
            if (id > max_id) unreachable;
            const idx = Indexer.indexOf(object);
            if (array.ids[idx] != null_id) unreachable;
            for (array.ids) |bound_id| { if (id == bound_id) unreachable; }
            array.ids[idx] = id;
        }

        /// Returns the object to which this `id` was bound.
        ///
        /// Asserts `id` is not the `null_id`.
        pub fn unbindId(array: *Array, id: u32) ?Object {
            if (id == null_id) unreachable;
            return for (&array.ids, 0..) |*bound_id, i| {
                if (id == bound_id.*) {
                    bound_id.* = null_id;
                    break Indexer.keyForIndex(i);
                }
            } else null;
        }

        /// Returns the id to which this `object` was bound.
        pub fn unbindObject(array: *Array, object: Object) ?u32 {
            const idx = Indexer.indexOf(object);
            const id = array.ids[idx];
            if (id != null_id) {
                array.ids[idx] = null_id;
                return id;
            } else {
                return null;
            }
        }

        /// Asserts `id` is not the `null_id`.
        pub fn getObject(array: Array, id: u32) ?Object {
            if (id == null_id) unreachable;
            return for (array.ids, 0..) |bound_id, i| {
                if (id == bound_id) break Indexer.keyForIndex(i);
            } else null;
        }

        pub fn getId(array: Array, object: Object) ?u32 {
            const id = array.ids[Indexer.indexOf(object)];
            return if (id != null_id) id else null;
        }
    };
}

/// For a set of globals defined by an enum `Global`,
/// for which each tag name is the name of a global interface as identified by `wl_registry::global.interface`
/// (`.wl_compositor`, `.wl_shm`, ...),
/// handle `wl_registry::global` and `wl_registry::global_remove` events
/// and keep a map of global name ids.
pub fn RegistryProxy(comptime Global: type) type {
    return struct {
        const Proxy = @This();
        pub const EnumArray = std.enums.EnumArray(Global, u32);
        pub const Key = Global;

        names: EnumArray,
        versions: EnumArray,

        pub const Error = error{
            /// The interface name string mapped to no known object
            UnsupportedInterface,
            /// The interface is already mapped
            InterfaceCollision,
            /// The interface name integer was already mapped to another global
            NameCollision,
            NullName,
        };

        pub const empty: Proxy = .{
            .names = .initFill(0),
            .versions = .initFill(undefined),
        };

        pub fn put(proxy: *Proxy, message: wire.protocol.wayland.Registry.Global) Error!void {
            const global = std.meta.stringToEnum(Global, message.interface.toSlice())
                orelse return error.UnsupportedInterface;
            const name: u32 = message.name;
            const version: u32 = message.version;

            // 0 is currently used to indicate an unmapped global
            // (the compositor *should* never name a global 0)
            if (name == 0) return error.NullName;
            if (proxy.names.get(global) != 0) return error.InterfaceCollision;
            for (proxy.names.values) |bound_name| { if (name == bound_name) return error.NameCollision; }

            proxy.names.set(global, name);
            proxy.versions.set(global, version);
        }

        pub fn putRemove(proxy: *Proxy, message: wire.protocol.wayland.Registry.GlobalRemove) (error{NullName})!?Global {
            const name: u32 = message.name;
            if (name == 0) return error.NullName;
            for (&proxy.names.values, &proxy.versions.values, 0..) |*bound_name, *bound_version, i| {
                if (bound_name.* == name) {
                    bound_name.* = 0;
                    bound_version.* = undefined;
                    return EnumArray.Indexer.keyForIndex(i);
                }
            }
            return null;
        }

        pub const Entry = struct {
            name: u32,
            version: u32,
        };

        pub fn get(proxy: Proxy, global: Global) ?Entry {
            const idx = EnumArray.Indexer.indexOf(global);
            return if (proxy.names.values[idx] != 0) .{
                .name = proxy.names.values[idx],
                .version = proxy.versions.values[idx],
            } else null;
        }

        pub fn has(proxy: Proxy, global: Global) bool {
            const idx = EnumArray.Indexer.indexOf(global);
            return proxy.names.values[idx] != 0;
        }

        pub fn hasAll(proxy: Proxy) bool {
            return for (proxy.names.values) |name| {
                if (name == 0) break false;
            } else true;
        }
    };
}

/// Asserts the `next_counter` begins at `>0` (`0` is the null object id).
///
/// A free list to reuse deleted object ids is only necessary if it is considered possible
/// that the program may churn through billions of object ids in its lifetime.
pub fn allocObjectIdMonotonic(next_counter: *u32) (error{OutOfObjectIds})!u32 {
    const min_id, const max_id = wire.object_id.client_range;
    comptime { if (min_id != 2) unreachable; }
    comptime { if (wire.object_id.display != 1) unreachable; }
    const id = next_counter.*;
    if (id == 0) {
        unreachable;
    } else if (id > max_id + 1) {
        unreachable;
    } else if (id == max_id + 1) {
        @branchHint(.cold);
        return error.OutOfObjectIds;
    } else {
        next_counter.* += 1;
        return id;
    }
}

/// The environment may initialize our process
/// with an already-established connection to the Wayland display.
/// In such a case, returns what should be that socket's open file descriptor.
pub fn getPreconnectedSocket(env: process.Environ) (error{InvalidInteger})!?system.fd_t {
    return if (env.getPosix("WAYLAND_SOCKET")) |socket|
        std.fmt.parseInt(system.fd_t, socket, 10) catch return error.InvalidInteger
        else null;
}

// TODO how should it be handled if these keys are present but length 0
pub fn printDisplayPath(writer: *Io.Writer, env: process.Environ) (error{MissingXDGRuntimeDir} || Io.Writer.Error)!void {
    const display = env.getPosix("WAYLAND_DISPLAY") orelse "wayland-0";
    if (display.len > 0 and fs.path.isSep(display[0])) {
        try writer.writeAll(display);
    } else {
        const runtime_dir = env.getPosix("XDG_RUNTIME_DIR") orelse return error.MissingXDGRuntimeDir;
        try writer.writeAll(runtime_dir);
        try writer.writeByte(std.fs.path.sep);
        try writer.writeAll(display);
    }
}

const Io = std.Io;
const Allocator = mem.Allocator;

const ipc = root.ipc;
const mem = std.mem;
const fmt = std.fmt;
const fs = std.fs;
const posix = std.posix;
const process = std.process;
const system = std.posix.system;
const debug = std.debug;

const std = @import("std");
const root = @import("root.zig");
