const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const flags = collectUnstableFlags(b);
    const build_options = b.addOptions();
    inline for (@typeInfo(UnstableFlags).@"struct".fields) |field| {
        build_options.addOption(bool, field.name, @field(flags, field.name));
    }

    const schema = b.addModule("acp-schema", .{
        .root_source_file = b.path("src/acp-schema/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    schema.addOptions("build_options", build_options);

    const test_step = b.step("test", "Run unit tests");

    const schema_tests = b.addTest(.{
        .name = "acp-schema-tests",
        .root_module = schema,
    });
    test_step.dependOn(&b.addRunArtifact(schema_tests).step);
}

const UnstableFlags = struct {
    unstable_elicitation: bool,
    unstable_nes: bool,
    unstable_cancel_request: bool,
    unstable_auth_methods: bool,
    unstable_logout: bool,
    unstable_session_fork: bool,
    unstable_session_model: bool,
    unstable_session_usage: bool,
    unstable_session_additional_directories: bool,
    unstable_llm_providers: bool,
    unstable_message_id: bool,
    unstable_boolean_config: bool,
};

fn collectUnstableFlags(b: *std.Build) UnstableFlags {
    var flags: UnstableFlags = undefined;
    inline for (@typeInfo(UnstableFlags).@"struct".fields) |field| {
        @field(flags, field.name) = b.option(
            bool,
            field.name,
            "Expose unstable protocol surface: " ++ field.name,
        ) orelse false;
    }
    return flags;
}
