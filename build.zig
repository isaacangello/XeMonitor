const std = @import("std");

/// Fonte unica da versao: le o arquivo `VERSION` na raiz do repo (uma linha).
/// Todos os binarios (bridge/exe/gui) e o CI obtem a versao daqui. Para
/// bumpar a versao, edite SOMENTE o arquivo VERSION (+ assets/xemonitor.rc p/
/// metadados do PE no Windows).
fn resolveVersion(b: *std.Build) []const u8 {
    const content = std.Io.Dir.cwd().readFileAlloc(b.graph.io, "VERSION", b.allocator, .limited(32)) catch {
        std.log.warn("VERSION file not found; using 0.0.0", .{});
        return "0.0.0";
    };
    return b.allocator.dupe(u8, std.mem.trim(u8, content, " \t\r\n")) catch "0.0.0";
}

/// Resolve o `bridge_build` (contador de compilacao, 3+ digitos) com a
/// seguinte ordem de fallback:
///   1) arquivo `zig-out/.bridge_build` (persiste entre builds locais)
///   2) env `XM_BRIDGE_BUILD` (override manual/CI)
///   3) `001` (bootstrap, gravado no arquivo)
/// Incrementa o contador a cada `zig build bridge` (auto-bump).
/// Nao tenta `git rev-list` (requer Child API instavel em Zig 0.16;
/// CI pode sobrescrever via env XM_BRIDGE_BUILD).
fn resolveBridgeBuild(b: *std.Build) []u8 {
    const build_path = "zig-out/.bridge_build";
    var buf: [16]u8 = undefined;
    var n: u8 = 0;

    // 1) arquivo zig-out/.bridge_build
    if (std.Io.Dir.cwd().readFileAlloc(b.graph.io, build_path, b.allocator, .unlimited)) |content| {
        defer b.allocator.free(content);
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (trimmed.len > 0 and trimmed.len < buf.len) {
            @memcpy(buf[0..trimmed.len], trimmed);
            n = @intCast(trimmed.len);
        }
    } else |_| {}

    // 2) env XM_BRIDGE_BUILD (override; CI define isso para ter valor deterministico)
    if (n == 0) {
        if (b.graph.environ_map.get("XM_BRIDGE_BUILD")) |env_val| {
            if (env_val.len > 0 and env_val.len < buf.len) {
                @memcpy(buf[0..env_val.len], env_val);
                n = @intCast(env_val.len);
            }
        }
    }

    // 3) bootstrap "001"
    if (n == 0) {
        @memcpy(buf[0..3], "001");
        n = 3;
    }

    // Sanitiza: garantir que sao so digitos
    {
        var i: usize = 0;
        var ok = true;
        while (i < n) : (i += 1) {
            if (buf[i] < '0' or buf[i] > '9') {
                ok = false;
                break;
            }
        }
        if (!ok) {
            @memcpy(buf[0..3], "001");
            n = 3;
        }
    }

    // Incrementa o contador (auto-bump a cada build)
    var carry: u16 = 1;
    var j: usize = n;
    while (j > 0) {
        j -= 1;
        const d: u16 = (buf[j] - '0') + carry;
        buf[j] = @intCast('0' + (d % 10));
        carry = d / 10;
        if (carry == 0) break;
    }

    // Grava o novo valor no arquivo (best-effort)
    const updated = buf[0..n];
    std.Io.Dir.cwd().writeFile(b.graph.io, .{
        .sub_path = build_path,
        .data = updated,
    }) catch {};

    return b.allocator.dupe(u8, updated) catch b.allocator.dupe(u8, "001") catch @panic("OOM");
}

fn pathExists(b: *std.Build, path: []const u8) bool {
    return !std.meta.isError(std.Io.Dir.cwd().access(b.graph.io, path, .{}));
}

fn configureWindowsLibserialport(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const candidate_roots = [_][]const u8{
        "C:\\msys64\\ucrt64",
        "C:\\msys64\\mingw64",
        "C:\\msys64\\clang64",
    };

    var configured = false;
    for (candidate_roots) |root| {
        const include_file = std.fmt.allocPrint(b.allocator, "{s}\\include\\libserialport.h", .{root}) catch continue;
        defer b.allocator.free(include_file);
        if (!pathExists(b, include_file)) continue;

        const lib_dir = std.fmt.allocPrint(b.allocator, "{s}\\lib", .{root}) catch continue;
        defer b.allocator.free(lib_dir);
        const import_lib = std.fmt.allocPrint(b.allocator, "{s}\\lib\\serialport.lib", .{root}) catch continue;
        defer b.allocator.free(import_lib);
        const dll_a = std.fmt.allocPrint(b.allocator, "{s}\\lib\\libserialport.dll.a", .{root}) catch continue;
        defer b.allocator.free(dll_a);

        if (!pathExists(b, import_lib) and !pathExists(b, dll_a)) continue;

        const include_dir = std.fmt.allocPrint(b.allocator, "{s}\\include", .{root}) catch continue;
        defer b.allocator.free(include_dir);
        exe.root_module.addIncludePath(.{ .cwd_relative = include_dir });
        exe.root_module.addLibraryPath(.{ .cwd_relative = lib_dir });
        std.log.info("libserialport configured from '{s}'", .{root});
        configured = true;
        break;
    }

    if (!configured) {
        std.log.warn("libserialport not found in default MSYS2 paths. Install it or set include/lib paths manually.", .{});
    }

    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("serialport", .{});
}

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    const serial_dep = b.dependency("serial", .{
        .target = target,
        .optimize = optimize,
    });

    // Fonte unica de versao (arquivo VERSION na raiz).
    const app_version = resolveVersion(b);
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("xemonitor", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe_options = b.addOptions();
    exe_options.addOption([]const u8, "version", app_version);
    const exe = b.addExecutable(.{
        .name = "xemonitor",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "xemonitor" is the name you will use in your source code to
                // import this module (e.g. `@import("xemonitor")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "xemonitor", .module = mod },
                .{ .name = "serial", .module = serial_dep.module("serial") },
                .{ .name = "build_options", .module = exe_options.createModule() },
            },
        }),
    });
    if (target.result.os.tag == .windows) {
        configureWindowsLibserialport(b, exe);
        exe.root_module.addWin32ResourceFile(.{
            .file = b.path("assets/xemonitor.rc"),
            .include_paths = &.{b.path("assets")},
        });
    } else {
        exe.root_module.link_libc = true;
    }

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // ---- Bridge executable (Linux/WSL2) ----
    const bridge_build = resolveBridgeBuild(b);
    const bridge_options = b.addOptions();
    bridge_options.addOption([]const u8, "version", app_version);
    bridge_options.addOption([]const u8, "build", bridge_build);
    bridge_options.addOption([]const u8, "arch", "x86_64-linux-musl");
    const bridge = b.addExecutable(.{
        .name = "bridge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bridge.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux }),
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "build_options", .module = bridge_options.createModule() },
            },
        }),
    });
    const bridge_install = b.addInstallArtifact(bridge, .{});
    const bridge_step = b.step("bridge", "Build the Linux/WSL2 bridge");
    bridge_step.dependOn(&bridge_install.step);

    // ---- Bridge miniroot (gera alpine-bridge-<version>.<build>-x86_64.tar.gz) ----
    // So executa em WSL/Linux. No Windows, emite aviso e sai OK.
    // O CI (release.yml job build-linux) gera o miniroot autoritativo.
    const build_bridge_miniroot = b.step(
        "build-bridge-miniroot",
        "Build the Alpine miniroot pre-baked with this bridge version (WSL/Linux only)",
    );
    build_bridge_miniroot.dependOn(&bridge_install.step);
    if (target.result.os.tag == .linux) {
        const run_bridge_miniroot = b.addSystemCommand(&.{
            "bash",
            "scripts/build_miniroot.sh",
            "--bridge-version",
            app_version,
            "--bridge-build",
            bridge_build,
        });
        build_bridge_miniroot.dependOn(&run_bridge_miniroot.step);
    } else {
        // Em Windows: warning + skip. Dev pode rodar o script manualmente
        // dentro do WSL: `wsl -d Alpine -- bash /mnt/c/XeMonitor/XeMonitor/scripts/build_miniroot.sh ...`
        const warn_skip = b.addSystemCommand(&.{
            "cmd",
            "/c",
            "echo AVISO: build-bridge-miniroot so roda em WSL/Linux. Use o CI ou rode manualmente via WSL.",
        });
        build_bridge_miniroot.dependOn(&warn_skip.step);
    }

    // Bridge tests (only compiles/runs on Linux due to C headers)
    const bridge_tests = b.addTest(.{
        .root_module = bridge.root_module,
        .filters = if (b.args) |a| a else &.{},
    });
    const run_bridge_tests = b.addRunArtifact(bridge_tests);
    const test_bridge_step = b.step("test-bridge", "Run bridge tests (Linux only)");
    test_bridge_step.dependOn(&run_bridge_tests.step);

    // PNG decoder tests (platform-independent, runs on any host)
    const png_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/png.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = if (b.args) |a| a else &.{},
    });
    png_tests.root_module.addAnonymousImport("barcode_png", .{ .root_source_file = b.path("src/Barcode Scanner.png") });
    const run_png_tests = b.addRunArtifact(png_tests);
    const test_png_step = b.step("test-png", "Run PNG decoder tests");
    test_png_step.dependOn(&run_png_tests.step);

    // ---- GUI executable (DVUI + SDL3, cross-platform) ----
    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
        // keep the first build light: no freetype/tree-sitter
        .freetype = false,
        .@"tree-sitter" = false,
        // native file dialogs (comdlg32 on Windows, zenity/etc. on Linux)
        .@"tiny-file-dialogs" = true,
    });
    const gui_options = b.addOptions();
    gui_options.addOption([]const u8, "version", app_version);
    const gui = b.addExecutable(.{
        .name = "xemonitor-gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gui.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "build_options", .module = gui_options.createModule() },
            },
        }),
    });
    gui.root_module.addAnonymousImport("barcode_png", .{ .root_source_file = b.path("src/Barcode Scanner.png") });
    gui.root_module.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    gui.root_module.addImport("sdl3-backend", dvui_dep.module("sdl3"));
    if (target.result.os.tag == .windows) {
        gui.root_module.addWin32ResourceFile(.{
            .file = b.path("assets/xemonitor.rc"),
            .include_paths = &.{b.path("assets")},
        });
        // xemonitor-gui é o app principal no Windows: janela + bandeja, sem
        // terminal de console (subsystem GUI). O xemonitor.exe cliente continua
        // console (CLI). A GUI spawna o cliente com create_no_window=true.
        gui.subsystem = .windows;
    } else if (target.result.os.tag == .linux) {
        // StatusNotifierItem tray via libdbus (session bus); pkg-config supplies include paths.
        gui.root_module.linkSystemLibrary("dbus-1", .{});
        // Debian/Ubuntu multiarch: libdbus-1.so fica fora do path padrão do
        // linker; adiciona o dir apenas quando existir (no Arch /usr/lib resolve).
        if (pathExists(b, "/usr/lib/x86_64-linux-gnu")) {
            gui.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
        }
    }
    const gui_install = b.addInstallArtifact(gui, .{});
    const gui_step = b.step("gui", "Build the cross-platform GUI (DVUI + SDL3)");
    gui_step.dependOn(&gui_install.step);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_png_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
