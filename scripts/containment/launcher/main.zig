const std = @import("std");
const builtin = @import("builtin");
const L = std.os.linux;
const P = @import("policy.zig");
comptime {
    if (builtin.os.tag != .linux or (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64)) @compileError("only Linux x86_64 and aarch64 supported");
}
const Fail = error{ Kernel, Setup };
fn checked(rc: usize) Fail!usize {
    if (L.errno(rc) != .SUCCESS) return error.Kernel;
    return rc;
}
fn call0(n: L.SYS) Fail!usize {
    return checked(L.syscall0(n));
}
fn call1(n: L.SYS, a: usize) Fail!usize {
    return checked(L.syscall1(n, a));
}
fn call2(n: L.SYS, a: usize, b: usize) Fail!usize {
    return checked(L.syscall2(n, a, b));
}
fn call3(n: L.SYS, a: usize, b: usize, c: usize) Fail!usize {
    return checked(L.syscall3(n, a, b, c));
}
fn fdopen(path: [*:0]const u8, directory: bool, nofollow: bool) Fail!i32 {
    const rc = try checked(L.openat(-100, path, .{ .PATH = true, .CLOEXEC = true, .DIRECTORY = directory, .NOFOLLOW = nofollow }, 0));
    return @intCast(rc);
}
fn close(fd: i32) Fail!void {
    _ = try checked(L.close(fd));
}
fn statfd(fd: i32) Fail!L.Statx {
    var s: L.Statx = undefined;
    _ = try checked(L.statx(fd, "", 0x1000, .{ .TYPE = true, .MODE = true, .UID = true, .GID = true }, &s));
    return s;
}
fn stdio() Fail!void {
    // Reject socket/regular-file stdio: open descriptors bypass Landlock checks.
    for ([_]i32{ 1, 2 }) |fd| {
        const st = try statfd(fd);
        if (st.mode & 0xf000 != 0x1000) return error.Setup;
        const flags = try checked(L.fcntl(fd, 3, 0));
        if (flags & 3 != 1) return error.Setup;
        _ = try checked(L.fcntl(fd, 2, 0));
    }
    const nullfd: i32 = @intCast(try checked(L.openat(-100, "/dev/null", .{ .CLOEXEC = true, .NOFOLLOW = true }, 0)));
    const st = try statfd(nullfd);
    if (st.mode & 0xf000 != 0x2000 or st.rdev_major != 1 or st.rdev_minor != 3) return error.Setup;
    if (nullfd != 0) {
        _ = try call3(.dup3, @intCast(nullfd), 0, 0);
        try close(nullfd);
    }
    _ = try checked(L.fcntl(0, 2, 0));
    _ = try call3(.close_range, 3, std.math.maxInt(u32), 0);
}
const exec_read: u64 = 1 | 4 | 8;
const write_tree: u64 = 2 | 4 | 8 | 16 | 32 | 128 | 256 | 1024 | 4096 | 8192 | 16384;
// All ABI4 FS rights; omit device/socket creation and execution from writable roots.
const fs_rights: u64 = (1 << 15) - 1;
const Ruleset = extern struct { fs: u64, net: u64 };
const PathRule = extern struct { access: u64, fd: i32, padding: u32 = 0 };
const NetRule = extern struct { access: u64, port: u64 };
fn pathRule(rules: i32, path: [*:0]const u8, rights: u64, directory: bool, optional: bool, nofollow: bool) Fail!void {
    const raw = L.openat(-100, path, .{ .PATH = true, .CLOEXEC = true, .DIRECTORY = directory, .NOFOLLOW = nofollow }, 0);
    if (optional and L.errno(raw) == .NOENT) return;
    const fd: i32 = @intCast(try checked(raw));
    defer close(fd) catch {};
    // Validate the opened inode's resolved path, not a pre-open symlink check.
    // Runtime aliases may point inside /usr, never /work, /boundary or /containment.
    if (optional) {
        var fdpath: [64]u8 = undefined;
        const link = std.fmt.bufPrintZ(&fdpath, "/proc/self/fd/{d}", .{fd}) catch return error.Setup;
        var resolved: [4096]u8 = undefined;
        const n = try checked(L.readlinkat(-100, link, &resolved, resolved.len));
        const actual = resolved[0..n];
        if (directory) {
            const alias = std.mem.span(path);
            var expected_buf: [64]u8 = undefined;
            const expected = std.fmt.bufPrint(&expected_buf, "/usr{s}", .{alias}) catch return error.Setup;
            if (!std.mem.eql(u8, actual, alias) and !std.mem.eql(u8, actual, expected)) return error.Setup;
        } else {
            if (!std.mem.eql(u8, actual, std.mem.span(path)) and !std.mem.startsWith(u8, actual, "/usr/")) return error.Setup;
        }
    }
    const st = try statfd(fd);
    if (!directory and st.mode & 0xf000 != 0x8000 and !(std.mem.eql(u8, std.mem.span(path), "/dev/null") and st.mode & 0xf000 == 0x2000)) return error.Setup;
    const rule: PathRule = .{ .access = rights, .fd = fd };
    // Kernel path_beneath struct is packed 12 bytes (kernel does not receive size).
    _ = try checked(L.syscall4(.landlock_add_rule, @intCast(rules), 1, @intFromPtr(&rule), 0));
}
fn landlock(config: P.Config) Fail!void {
    const abi = try call3(.landlock_create_ruleset, 0, 0, 1);
    if (abi < 4) return error.Setup;
    // Handle ABI5 ioctl too when available; seccomp also rejects every ioctl.
    const attr: Ruleset = .{ .fs = fs_rights | (if (abi >= 5) @as(u64, 1 << 15) else 0), .net = 3 };
    const rules: i32 = @intCast(try call3(.landlock_create_ruleset, @intFromPtr(&attr), @sizeOf(Ruleset), 0));
    defer close(rules) catch {};
    try pathRule(rules, "/usr", exec_read, true, false, true);
    try pathRule(rules, "/qa", exec_read, true, false, true);
    inline for (.{ "/bin", "/lib", "/lib64", "/sbin" }) |p| try pathRule(rules, p, exec_read, true, true, false);
    try pathRule(rules, "/work", write_tree, true, false, true);
    try pathRule(rules, "/tmp", write_tree, true, false, true);
    inline for (.{ "/proc/self/status", "/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/pids.max" }) |p| try pathRule(rules, p, 4, false, false, false);
    try pathRule(rules, "/.dockerenv", 4, false, false, true);
    // Directory listing, not all sysfs contents. Fixture only lists interface names.
    try pathRule(rules, "/sys/class/net", 8, true, false, false);
    try pathRule(rules, "/dev/null", 2 | 4, false, false, true);
    inline for (.{ "/etc/ld.so.cache", "/etc/localtime", "/etc/nsswitch.conf", "/etc/hosts", "/etc/resolv.conf", "/etc/passwd", "/etc/group" }) |p| try pathRule(rules, p, 4, false, true, false);
    for (config.bind.values[0..config.bind.len]) |port| {
        const rule: NetRule = .{ .access = 1, .port = port };
        _ = try checked(L.syscall4(.landlock_add_rule, @intCast(rules), 2, @intFromPtr(&rule), 0));
    }
    for (config.connect.values[0..config.connect.len]) |port| {
        const rule: NetRule = .{ .access = 2, .port = port };
        _ = try checked(L.syscall4(.landlock_add_rule, @intCast(rules), 2, @intFromPtr(&rule), 0));
    }
    _ = try call2(.landlock_restrict_self, @intCast(rules), 0);
}
const CapHeader = extern struct { version: u32 = 0x20080522, pid: i32 = 0 };
const CapData = extern struct { effective: u32 = 0, permitted: u32 = 0, inheritable: u32 = 0 };
fn identity() Fail!void {
    if (L.getuid() != 0 or L.geteuid() != 0) return error.Setup;
    _ = try checked(L.prctl(38, 1, 0, 0, 0)); // NO_NEW_PRIVS
    _ = try checked(L.prctl(47, 4, 0, 0, 0)); // AMBIENT_CLEAR_ALL
    _ = try checked(L.prctl(8, 0, 0, 0, 0)); // KEEPCAPS=0
    _ = try call2(.setgroups, 0, 0);
    _ = try checked(L.setresgid(10001, 10001, 10001));
    _ = try checked(L.setresuid(10001, 10001, 10001));
    var header: CapHeader = .{};
    var caps: [2]CapData = .{ .{}, .{} };
    _ = try call2(.capset, @intFromPtr(&header), @intFromPtr(&caps));
    _ = try call2(.capget, @intFromPtr(&header), @intFromPtr(&caps));
    for (caps) |cap| if (cap.effective != 0 or cap.permitted != 0 or cap.inheritable != 0) return error.Setup;
    if (L.getuid() != 10001 or L.geteuid() != 10001 or L.getgid() != 10001 or L.getegid() != 10001) return error.Setup;
    if (try call2(.getgroups, 0, 0) != 0) return error.Setup;
    if (try checked(L.prctl(39, 0, 0, 0, 0)) != 1) return error.Setup;
    _ = try checked(L.prctl(4, 0, 0, 0, 0)); // DUMPABLE=0 (exec also bounded by UID separation)
}
fn limits() Fail!void {
    inline for (.{ .{ L.rlimit_resource.CORE, 0 }, .{ L.rlimit_resource.CPU, 40 }, .{ L.rlimit_resource.FSIZE, 8388608 }, .{ L.rlimit_resource.NOFILE, 256 } }) |pair| {
        const limit: L.rlimit = .{ .cur = pair[1], .max = pair[1] };
        _ = try checked(L.setrlimit(pair[0], &limit));
    }
}
fn workspace() Fail!void {
    _ = try call1(.umask, 0o077);
    const work = try fdopen("/work", true, true);
    defer close(work) catch {};
    const st = try statfd(work);
    if (st.uid != 10001 or st.gid != 10001 or st.mode & 0o777 != 0o700) return error.Setup;
    const rc = L.mkdirat(work, "home", 0o700);
    if (L.errno(rc) != .EXIST) _ = try checked(rc);
    const home: i32 = @intCast(try checked(L.openat(work, "home", .{ .PATH = true, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0)));
    defer close(home) catch {};
    const hs = try statfd(home);
    if (hs.uid != 10001 or hs.gid != 10001 or hs.mode & 0o777 != 0o700) return error.Setup;
    _ = try checked(L.fchdir(work));
}
fn seccomp() Fail!void {
    var f = P.filter(if (builtin.cpu.arch == .x86_64) .x86_64 else .aarch64);
    const Program = extern struct { len: u16, ptr: [*]const P.Insn };
    const program: Program = .{ .len = @intCast(f.len), .ptr = &f.insns };
    _ = try call3(.seccomp, 1, 0, @intFromPtr(&program));
}
fn write(fd: i32, s: []const u8) Fail!void {
    var offset: usize = 0;
    while (offset < s.len) {
        const rc = L.write(fd, s.ptr + offset, s.len - offset);
        if (L.errno(rc) == .INTR) continue;
        const count = try checked(rc);
        if (count == 0) return error.Setup;
        offset += count;
    }
}
fn run(init: std.process.Init.Minimal) !void {
    // No IO runtime or background threads; allocate argv before restrictions.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const args = try init.args.toSlice(arena.allocator());
    const config = try P.parse(args);
    const argv = try arena.allocator().allocSentinel(?[*:0]const u8, if (config.check) 0 else args.len - config.target, null);
    if (!config.check) for (args[config.target..], 0..) |arg, i| {
        argv[i] = arg.ptr;
    };
    try stdio();
    try identity();
    try limits();
    try workspace();
    try landlock(config);
    // No inherited Landlock/path descriptors remain, even if cleanup regresses.
    _ = try call3(.close_range, 3, std.math.maxInt(u32), 0);
    try seccomp();
    if (config.check) {
        try write(1, "mimic.containment-launch/v1\n");
        return;
    }
    const env = [_:null]?[*:0]const u8{ "PATH=/usr/local/bin:/usr/bin:/bin", "HOME=/work/home", "TMPDIR=/tmp", "LANG=C.UTF-8", "TZ=UTC", "LD_LIBRARY_PATH=/usr/local/lib" };
    _ = try checked(L.execve(args[config.target].ptr, argv.ptr, &env));
    return error.Setup;
}
pub fn main(init: std.process.Init.Minimal) void {
    run(init) catch |err| {
        write(2, "containment-launch: blocked: ") catch {};
        write(2, @errorName(err)) catch {};
        write(2, "\n") catch {};
        std.process.exit(126);
    };
}
