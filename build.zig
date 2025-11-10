pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const link_x11 = b.option(bool, "x11", "Link the X11 system library")
        orelse switch (target.result.os.tag) {
            .linux, .freebsd, .netbsd, .openbsd, .illumos => true,
            else => false,
        };
    const no_link = b.option(bool, "nolink", "Prevent linking system libraries")
        orelse false;

    const manifest = @import("build.zig.zon");
    const manifest_version: ?SemVer = SemVer.parse(manifest.version)
        catch |err| version_failure: {
            switch (err) {
                error.InvalidVersion => log.err(
                    "invalid version string \'{s}\' from build.zig.zon",
                    .{ manifest.version },
                ),
                error.Overflow => log.err(
                    "overflow while parsing version string of build.zig.zon",
                    .{},
                ),
            }
            break :version_failure null;
        };

    const options = b.addOptions();

    if (manifest_version) |version| options.addOption(
        SemVer,
        "version",
        version,
    );

    options.addOption(bool, "x11_linked", link_x11 and !no_link);

    const mod = b.addModule("spark", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    mod.addOptions("build_options", options);

    if (link_x11 and !no_link) {
        mod.linkSystemLibrary("X11", .{ .needed = false });
        mod.linkSystemLibrary("Xrandr", .{ .needed = false });
        const translate = b.addTranslateC(.{
            .root_source_file = b.path("src/x11/import.h"),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("x11", translate.createModule());
    }

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}

const SemVer = std.SemanticVersion;
const log = std.log;
const std = @import("std");
