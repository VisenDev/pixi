const std = @import("std");
const pixi = @import("root");
const History = @This();

pub const Action = enum { undo, redo };
pub const ChangeType = enum { pixels, origins, animation };

pub const Change = union(ChangeType) {
    pub const Pixels = struct {
        layer: usize,
        indices: []usize,
        values: [][4]u8,
        bookmark: bool = false,
    };

    pub const Origins = struct {
        indices: []usize,
        values: [][2]f32,
        bookmark: bool = false,
    };

    pub const Animation = struct {
        index: usize,
        name: [:0]const u8,
        fps: usize,
        start: usize,
        length: usize,
        bookmark: bool = false,
    };

    pixels: Pixels,
    origins: Origins,
    animation: Animation,

    pub fn create(allocator: std.mem.Allocator, field: ChangeType, len: usize) !Change {
        return switch (field) {
            .pixels => .{
                .pixels = .{
                    .layer = 0,
                    .indices = try allocator.alloc(usize, len),
                    .values = try allocator.alloc([4]u8, len),
                },
            },
            .origins => .{
                .origins = .{
                    .indices = try allocator.alloc(usize, len),
                    .values = try allocator.alloc([2]f32, len),
                },
            },
            .animation => .{
                .animation = .{
                    .index = 0,
                    .name = undefined,
                    .fps = 1,
                    .start = 0,
                    .length = 1,
                },
            },
        };
    }

    pub fn bookmarked(self: Change) bool {
        return switch (self) {
            .pixels => |pixels| pixels.bookmark,
            .origins => |origins| origins.bookmark,
            .animation => |animation| animation.bookmark,
        };
    }

    pub fn bookmark(self: *Change) void {
        switch (self.*) {
            .pixels => self.pixels.bookmark = true,
            .origins => self.origins.bookmark = true,
            .animation => self.animation.bookmark = true,
        }
    }

    pub fn clearBookmark(self: *Change) void {
        switch (self.*) {
            .pixels => self.pixels.bookmark = false,
            .origins => self.origins.bookmark = false,
            .animation => self.animation.bookmark = false,
        }
    }

    pub fn deinit(self: Change) void {
        switch (self) {
            .pixels => |*pixels| {
                pixi.state.allocator.free(pixels.indices);
                pixi.state.allocator.free(pixels.values);
            },
            .origins => |*origins| {
                pixi.state.allocator.free(origins.indices);
                pixi.state.allocator.free(origins.values);
            },
            .animation => |*animation| {
                pixi.state.allocator.free(animation.name);
            },
        }
    }
};

undo_stack: std.ArrayList(Change),
redo_stack: std.ArrayList(Change),

pub fn init(allocator: std.mem.Allocator) History {
    return .{
        .undo_stack = std.ArrayList(Change).init(allocator),
        .redo_stack = std.ArrayList(Change).init(allocator),
    };
}

pub fn append(self: *History, change: Change) !void {
    if (self.redo_stack.items.len > 0) {
        for (self.redo_stack.items) |*c| {
            c.deinit();
        }
        self.redo_stack.clearRetainingCapacity();
    }

    // Equality check, don't append if equal
    var equal: bool = self.undo_stack.items.len > 0;
    if (self.undo_stack.getLastOrNull()) |last| {
        const last_active_tag = std.meta.activeTag(last);
        const change_active_tag = std.meta.activeTag(change);

        if (last_active_tag == change_active_tag) {
            switch (last) {
                .origins => |origins| {
                    if (std.mem.eql(usize, origins.indices, change.origins.indices)) {
                        for (origins.values, 0..) |value, i| {
                            if (!std.mem.eql(f32, &value, &change.origins.values[i])) {
                                equal = false;
                                break;
                            }
                        }
                    } else {
                        equal = false;
                    }
                },
                .pixels => |pixels| {
                    equal = std.mem.eql(usize, pixels.indices, change.pixels.indices);
                    if (equal) {
                        for (pixels.values, 0..) |value, i| {
                            equal = std.mem.eql(u8, &value, &change.pixels.values[i]);
                            if (!equal) break;
                        }
                    }
                },
                .animation => |animation| {
                    equal = std.mem.eql(u8, animation.name, change.animation.name);
                    if (equal) {
                        equal = animation.index == change.animation.index;
                        if (equal) {
                            equal = animation.fps == change.animation.fps;
                            if (equal) {
                                equal = animation.start == change.animation.start;
                                if (equal) {
                                    equal = animation.length == change.animation.length;
                                }
                            }
                        }
                    }
                },
            }
        } else equal = false;
    }

    if (equal) {
        change.deinit();
    } else try self.undo_stack.append(change);

    if (self.undo_stack.items.len == 1 and self.redo_stack.items.len == 0) {
        self.bookmark();
    }
}

pub fn bookmark(self: *History) void {
    if (self.undo_stack.items.len == 0) return;
    self.clearBookmark();
    self.undo_stack.items[self.undo_stack.items.len - 1].bookmark();
}

pub fn bookmarked(self: History) bool {
    var b: bool = false;
    if (self.undo_stack.getLastOrNull()) |last| {
        b = last.bookmarked();
    }
    return b;
}

pub fn clearBookmark(self: *History) void {
    for (self.undo_stack.items) |*undo|
        undo.clearBookmark();

    for (self.redo_stack.items) |*redo|
        redo.clearBookmark();
}

pub fn undoRedo(self: *History, file: *pixi.storage.Internal.Pixi, action: Action) !void {
    var active_stack = switch (action) {
        .undo => &self.undo_stack,
        .redo => &self.redo_stack,
    };

    var other_stack = switch (action) {
        .undo => &self.redo_stack,
        .redo => &self.undo_stack,
    };

    if (active_stack.items.len == 0)
        return;

    file.dirty = !self.bookmarked();

    if (active_stack.popOrNull()) |change| {
        switch (change) {
            .pixels => |*pixels| {
                for (pixels.indices, 0..) |pixel_index, i| {
                    const color: [4]u8 = pixels.values[i];
                    var current_pixels = @ptrCast([*][4]u8, file.layers.items[pixels.layer].texture.image.data.ptr)[0 .. file.layers.items[pixels.layer].texture.image.data.len / 4];
                    pixels.values[i] = current_pixels[pixel_index];
                    current_pixels[pixel_index] = color;
                }
                file.layers.items[pixels.layer].texture.update(pixi.state.gctx);
                if (pixi.state.sidebar == .sprites)
                    pixi.state.sidebar = .tools;
            },
            .origins => |*origins| {
                file.selected_sprites.clearAndFree();
                for (origins.indices, 0..) |sprite_index, i| {
                    var origin_x = origins.values[i][0];
                    var origin_y = origins.values[i][1];
                    origins.values[i] = .{ file.sprites.items[sprite_index].origin_x, file.sprites.items[sprite_index].origin_y };
                    file.sprites.items[sprite_index].origin_x = origin_x;
                    file.sprites.items[sprite_index].origin_y = origin_y;
                    try file.selected_sprites.append(sprite_index);
                }
                pixi.state.sidebar = .sprites;
            },
            else => {},
        }
        try other_stack.append(change);
    }
}

pub fn clearAndFree(self: *History) void {
    for (self.undo_stack.items) |*u| {
        u.deinit();
    }
    for (self.redo_stack.items) |*r| {
        r.deinit();
    }
    self.undo_stack.clearAndFree();
    self.redo_stack.clearAndFree();
}

pub fn clearRetainingCapacity(self: *History) void {
    for (self.undo_stack.items) |*u| {
        u.deinit();
    }
    for (self.redo_stack.items) |*r| {
        r.deinit();
    }
    self.undo_stack.clearRetainingCapacity();
    self.redo_stack.clearRetainingCapacity();
}

pub fn deinit(self: *History) void {
    self.clearAndFree();
    self.undo_stack.deinit();
    self.redo_stack.deinit();
}
