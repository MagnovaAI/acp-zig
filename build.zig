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

    const acp = b.addModule("acp", .{
        .root_source_file = b.path("src/acp/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    acp.addImport("acp-schema", schema);

    const acp_test = b.addModule("acp-test", .{
        .root_source_file = b.path("src/acp-test/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    acp_test.addImport("acp", acp);
    acp_test.addImport("acp-schema", schema);

    const acp_async = b.addModule("acp-async", .{
        .root_source_file = b.path("src/acp-async/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    acp_async.addImport("acp", acp);

    const acp_conductor = b.addModule("acp-conductor", .{
        .root_source_file = b.path("src/acp-conductor/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    acp_conductor.addImport("acp", acp);

    const vaxis_dep = b.lazyDependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");

    const schema_tests = b.addTest(.{
        .name = "acp-schema-tests",
        .root_module = schema,
    });
    test_step.dependOn(&b.addRunArtifact(schema_tests).step);

    const acp_tests = b.addTest(.{
        .name = "acp-tests",
        .root_module = acp,
    });
    test_step.dependOn(&b.addRunArtifact(acp_tests).step);

    const acp_test_tests = b.addTest(.{
        .name = "acp-test-tests",
        .root_module = acp_test,
    });
    test_step.dependOn(&b.addRunArtifact(acp_test_tests).step);

    const acp_async_tests = b.addTest(.{
        .name = "acp-async-tests",
        .root_module = acp_async,
    });
    test_step.dependOn(&b.addRunArtifact(acp_async_tests).step);

    const acp_conductor_tests = b.addTest(.{
        .name = "acp-conductor-tests",
        .root_module = acp_conductor,
    });
    test_step.dependOn(&b.addRunArtifact(acp_conductor_tests).step);

    const cookbook_step = b.step("cookbook", "Build cookbook examples");

    const minimal_client_module = b.createModule(.{
        .root_source_file = b.path("src/acp-cookbook/minimal_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    minimal_client_module.addImport("acp", acp);
    minimal_client_module.addImport("acp-test", acp_test);
    minimal_client_module.addImport("acp-schema", schema);
    const minimal_client_exe = b.addExecutable(.{
        .name = "minimal-client",
        .root_module = minimal_client_module,
    });
    b.installArtifact(minimal_client_exe);
    cookbook_step.dependOn(&minimal_client_exe.step);

    const minimal_agent_module = b.createModule(.{
        .root_source_file = b.path("src/acp-cookbook/minimal_agent.zig"),
        .target = target,
        .optimize = optimize,
    });
    minimal_agent_module.addImport("acp", acp);
    minimal_agent_module.addImport("acp-test", acp_test);
    minimal_agent_module.addImport("acp-schema", schema);
    const minimal_agent_exe = b.addExecutable(.{
        .name = "minimal-agent",
        .root_module = minimal_agent_module,
    });
    b.installArtifact(minimal_agent_exe);
    cookbook_step.dependOn(&minimal_agent_exe.step);

    const gen_schema_module = b.createModule(.{
        .root_source_file = b.path("tools/gen_schema/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    gen_schema_module.addImport("acp-schema", schema);

    const gen_schema_exe = b.addExecutable(.{
        .name = "gen-schema",
        .root_module = gen_schema_module,
    });
    b.installArtifact(gen_schema_exe);

    const gen_schema_run = b.addRunArtifact(gen_schema_exe);
    if (b.args) |args| gen_schema_run.addArgs(args);
    const gen_schema_step = b.step("gen-schema", "Emit canonical schema catalog JSON (path arg or stdout)");
    gen_schema_step.dependOn(&gen_schema_run.step);

    const yopo_module = b.createModule(.{
        .root_source_file = b.path("src/yopo/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    yopo_module.addImport("acp", acp);
    yopo_module.addImport("acp-test", acp_test);
    yopo_module.addImport("acp-schema", schema);

    const yopo_exe = b.addExecutable(.{
        .name = "yopo",
        .root_module = yopo_module,
    });
    b.installArtifact(yopo_exe);

    const yopo_run = b.addRunArtifact(yopo_exe);
    const yopo_step = b.step("yopo", "Run the reference agent contract suite");
    yopo_step.dependOn(&yopo_run.step);

    if (vaxis_dep) |dep| {
        const vaxis_module = dep.module("vaxis");

        const trace_viewer_module = b.createModule(.{
            .root_source_file = b.path("src/acp-trace-viewer/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        trace_viewer_module.addImport("vaxis", vaxis_module);

        const trace_viewer_exe = b.addExecutable(.{
            .name = "acp-trace-viewer",
            .root_module = trace_viewer_module,
        });
        b.installArtifact(trace_viewer_exe);

        const viewer_step = b.step("trace-viewer", "Build the interactive trace viewer");
        viewer_step.dependOn(&trace_viewer_exe.step);
    }
}

const UnstableFlags = struct {
    unstable_elicitation: bool,
    unstable_nes: bool,
    unstable_cancel_request: bool,
    unstable_auth_methods: bool,
    unstable_logout: bool,
    unstable_session_fork: bool,
    unstable_session_resume: bool,
    unstable_session_close: bool,
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
