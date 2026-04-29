//! ContentBlock and its variants.
//!
//! Wire shape: a tagged union keyed on `type`. Five known variants —
//! `text`, `image`, `audio`, `resource`, `resource_link` — plus a
//! forward-compatible `unknown` bucket so older builds don't crash on
//! variants added upstream.
//!
//! Field names on the wire are camelCase to match the canonical schema.

const std = @import("std");
const RawValue = @import("serde_util.zig").RawValue;

pub const Annotations = struct {
    audience: ?[]const Role = null,
    priority: ?f64 = null,
};

pub const Role = enum {
    user,
    assistant,

    pub fn jsonStringify(self: Role, jw: anytype) !void {
        try jw.write(@tagName(self));
    }
};

pub const TextContent = struct {
    text: []const u8,
    annotations: ?Annotations = null,
};

pub const ImageContent = struct {
    /// Base64-encoded image data.
    data: []const u8,
    mimeType: []const u8,
    /// Optional URI the image was sourced from.
    uri: ?[]const u8 = null,
    annotations: ?Annotations = null,
};

pub const AudioContent = struct {
    /// Base64-encoded audio data.
    data: []const u8,
    mimeType: []const u8,
    annotations: ?Annotations = null,
};

pub const EmbeddedResource = struct {
    resource: ResourceContents,
    annotations: ?Annotations = null,
};

pub const ResourceLink = struct {
    uri: []const u8,
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    size: ?u64 = null,
    annotations: ?Annotations = null,
};

pub const ResourceContents = union(enum) {
    text: TextResource,
    blob: BlobResource,

    pub const TextResource = struct {
        uri: []const u8,
        mimeType: ?[]const u8 = null,
        text: []const u8,
    };

    pub const BlobResource = struct {
        uri: []const u8,
        mimeType: ?[]const u8 = null,
        /// Base64-encoded.
        blob: []const u8,
    };

    pub fn jsonStringify(self: ResourceContents, jw: anytype) !void {
        switch (self) {
            inline else => |payload| try jw.write(payload),
        }
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !ResourceContents {
        const v = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, v, options);
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !ResourceContents {
        if (source != .object) return error.UnexpectedToken;
        if (source.object.get("text") != null) {
            return .{ .text = try std.json.parseFromValueLeaky(TextResource, allocator, source, options) };
        }
        if (source.object.get("blob") != null) {
            return .{ .blob = try std.json.parseFromValueLeaky(BlobResource, allocator, source, options) };
        }
        return error.UnexpectedToken;
    }
};

pub const ContentBlock = union(enum) {
    text: TextContent,
    image: ImageContent,
    audio: AudioContent,
    resource: EmbeddedResource,
    resource_link: ResourceLink,
    /// Forward-compat: unknown variants from peers running newer revisions.
    unknown: RawValue,

    pub fn jsonStringify(self: ContentBlock, jw: anytype) !void {
        switch (self) {
            .text => |t| try writeTagged(jw, "text", t),
            .image => |t| try writeTagged(jw, "image", t),
            .audio => |t| try writeTagged(jw, "audio", t),
            .resource => |t| try writeTagged(jw, "resource", t),
            .resource_link => |t| try writeTagged(jw, "resource_link", t),
            .unknown => |raw| try jw.write(raw),
        }
    }

    fn writeTagged(jw: anytype, comptime tag: []const u8, payload: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(tag);
        const T = @TypeOf(payload);
        inline for (@typeInfo(T).@"struct".fields) |f| {
            const v = @field(payload, f.name);
            const skip = @typeInfo(f.type) == .optional and v == null;
            if (!skip) {
                try jw.objectField(f.name);
                try jw.write(v);
            }
        }
        try jw.endObject();
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !ContentBlock {
        const v = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, v, options);
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !ContentBlock {
        if (source != .object) return error.UnexpectedToken;
        const tag_v = source.object.get("type") orelse return error.MissingField;
        if (tag_v != .string) return error.UnexpectedToken;
        const tag = tag_v.string;

        const inner = try stripType(allocator, source);

        if (std.mem.eql(u8, tag, "text"))
            return .{ .text = try std.json.parseFromValueLeaky(TextContent, allocator, inner, options) };
        if (std.mem.eql(u8, tag, "image"))
            return .{ .image = try std.json.parseFromValueLeaky(ImageContent, allocator, inner, options) };
        if (std.mem.eql(u8, tag, "audio"))
            return .{ .audio = try std.json.parseFromValueLeaky(AudioContent, allocator, inner, options) };
        if (std.mem.eql(u8, tag, "resource"))
            return .{ .resource = try std.json.parseFromValueLeaky(EmbeddedResource, allocator, inner, options) };
        if (std.mem.eql(u8, tag, "resource_link"))
            return .{ .resource_link = try std.json.parseFromValueLeaky(ResourceLink, allocator, inner, options) };

        return .{ .unknown = .{ .value = source } };
    }
};

fn stripType(allocator: std.mem.Allocator, source: std.json.Value) !std.json.Value {
    var copy: std.json.ObjectMap = .empty;
    try copy.ensureTotalCapacity(allocator, source.object.count());
    var it = source.object.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "type")) continue;
        copy.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
    }
    return .{ .object = copy };
}

test "ContentBlock text round-trip" {
    const src =
        \\{"type":"text","text":"hello"}
    ;
    const parsed = try std.json.parseFromSlice(ContentBlock, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .text);
    try std.testing.expectEqualStrings("hello", parsed.value.text.text);
}

test "ContentBlock image parses with mimeType" {
    const src =
        \\{"type":"image","data":"AAA=","mimeType":"image/png"}
    ;
    const parsed = try std.json.parseFromSlice(ContentBlock, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .image);
    try std.testing.expectEqualStrings("image/png", parsed.value.image.mimeType);
}

test "ContentBlock resource_link parses" {
    const src =
        \\{"type":"resource_link","uri":"file:///x.txt","name":"x.txt"}
    ;
    const parsed = try std.json.parseFromSlice(ContentBlock, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .resource_link);
}

test "ContentBlock unknown variant survives" {
    const src =
        \\{"type":"video","data":"x","mimeType":"video/mp4"}
    ;
    const parsed = try std.json.parseFromSlice(ContentBlock, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .unknown);
}

test "ContentBlock embedded text resource round-trip" {
    const src =
        \\{"type":"resource","resource":{"uri":"file:///a","text":"hi"}}
    ;
    const parsed = try std.json.parseFromSlice(ContentBlock, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .resource);
    try std.testing.expect(parsed.value.resource.resource == .text);
}

test "ContentBlock stringifies text with type tag" {
    const cb: ContentBlock = .{ .text = .{ .text = "hi" } };
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, cb, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"type\":\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"text\":\"hi\"") != null);
}
