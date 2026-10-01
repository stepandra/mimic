//! Synthetic kernel oracle, ONLY in an owned private Linux container.
//! No launcher implementation imports. All paths, ports and modes are fixed.
const std = @import("std");
const linux = std.os.linux;
extern "c" fn open([*:0]const u8, c_int, ...) c_int;
extern "c" fn close(c_int) c_int;
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;
extern "c" fn unlink([*:0]const u8) c_int;
extern "c" fn fcntl(c_int, c_int, ...) c_int;
extern "c" fn setuid(c_uint) c_int;
extern "c" fn setgid(c_uint) c_int;
extern "c" fn getuid() c_uint;
extern "c" fn geteuid() c_uint;
extern "c" fn getgid() c_uint;
extern "c" fn getegid() c_uint;
extern "c" fn getgroups(c_int, ?[*]c_uint) c_int;
extern "c" fn getcwd([*]u8, usize) ?[*:0]u8;
extern "c" fn umask(c_uint) c_uint;
extern "c" fn getrlimit(c_int, *Limit) c_int;
extern "c" fn alarm(c_uint) c_uint;
extern "c" fn socket(c_int, c_int, c_int) c_int;
extern "c" fn socketpair(c_int, c_int, c_int, *[2]c_int) c_int;
extern "c" fn connect(c_int, *const Address, c_uint) c_int;
extern "c" fn bind(c_int, *const Address, c_uint) c_int;
extern "c" fn listen(c_int, c_int) c_int;
extern "c" fn accept(c_int, ?*anyopaque, ?*c_uint) c_int;
extern "c" fn setsockopt(c_int, c_int, c_int, *const anyopaque, c_uint) c_int;
extern "c" fn poll([*]Poll, c_ulong, c_int) c_int;
extern "c" fn fork() c_int;
extern "c" fn execve([*:0]const u8, [*:null]const ?[*:0]const u8, [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(c_int, *c_int, c_int) c_int;
extern "c" fn kill(c_int, c_int) c_int;
extern "c" fn pipe(*[2]c_int) c_int;
extern "c" fn dup2(c_int, c_int) c_int;
extern "c" fn _exit(c_int) noreturn;
extern "c" fn __errno_location() *c_int;
extern "c" var environ: [*:null]?[*:0]const u8;
const Limit = extern struct { soft: c_ulong, hard: c_ulong };
const Address = extern struct { family: u16 = 2, port: u16, address: [4]u8 = .{ 127, 0, 0, 1 }, zero: [8]u8 = @splat(0) };
const Poll = extern struct { fd: c_int, events: c_short = 1, revents: c_short = 0 };
const Timeval = extern struct { seconds: c_long = 1, micros: c_long = 0 };
const executable = "/usr/local/bin/launcher-probe";
const launch = "/containment/launch";
fn emit(s: []const u8) void {
    _ = write(1, s.ptr, s.len);
}
fn denied() bool {
    const e = __errno_location().*;
    return e == 1 or e == 13;
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn contents(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const fd = open(path, 0);
    if (fd < 0) return null;
    defer _ = close(fd);
    const n = read(fd, buf.ptr, buf.len);
    if (n < 0) return null;
    return buf[0..@intCast(n)];
}
fn unreadable(path: [*:0]const u8) bool {
    const fd = open(path, 0);
    if (fd < 0) return denied();
    _ = close(fd);
    return false;
}
fn writable(path: [*:0]const u8) bool {
    const fd = open(path, 0xC2, @as(c_uint, 0o600));
    if (fd < 0) return false;
    defer _ = close(fd);
    defer _ = unlink(path);
    if (write(fd, "synthetic", 9) != 9) return false;
    var buf: [16]u8 = undefined;
    return eq(contents(path, &buf) orelse return false, "synthetic");
}
fn noWrite(path: [*:0]const u8) bool {
    const fd = open(path, 0xC1, @as(c_uint, 0o600));
    if (fd < 0) return denied() or __errno_location().* == 30;
    _ = close(fd);
    _ = unlink(path);
    return false;
}
fn limit(resource: c_int, expected: c_ulong) bool {
    var value: Limit = undefined;
    return getrlimit(resource, &value) == 0 and value.soft == expected and value.hard == expected;
}
fn bounded(path: [*:0]const u8, maximum: u64) bool {
    var buf: [64]u8 = undefined;
    const s = contents(path, &buf) orelse return false;
    const n = std.fmt.parseInt(u64, std.mem.trim(u8, s, "\n "), 10) catch return false;
    return n > 0 and n <= maximum;
}
fn environment() bool {
    const expected = [_][]const u8{ "PATH=/usr/local/bin:/usr/bin:/bin", "HOME=/work/home", "TMPDIR=/tmp", "LANG=C.UTF-8", "TZ=UTC", "LD_LIBRARY_PATH=/usr/local/lib" };
    var seen = [_]bool{false} ** expected.len;
    var count: usize = 0;
    while (environ[count]) |entry| : (count += 1) {
        if (count >= expected.len) return false;
        var found = false;
        for (expected, 0..) |value, i| {
            if (eq(std.mem.span(entry), value)) {
                if (seen[i]) return false;
                seen[i] = true;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return count == expected.len;
}
fn noExtraFds() bool {
    // Probe beyond the lowered rlimit too: lowering NOFILE does not close FDs.
    var fd: c_int = 3;
    while (fd < 4096) : (fd += 1) {
        if (fcntl(fd, 1) != -1 or __errno_location().* != 9) return false;
    }
    return true;
}
fn socketDenied(family: c_int, kind: c_int, protocol: c_int) bool {
    const fd = socket(family, kind, protocol);
    if (fd < 0) return denied();
    _ = close(fd);
    return false;
}
fn tcp(port: u16, binding: bool, want_denial: bool) bool {
    const fd = socket(2, 1, 0);
    if (fd < 0) return false;
    defer _ = close(fd);
    // The target already has an 8-second alarm. Do not require socket-option
    // privileges to test TCP bind/connect rules; those are separately denied.
    const addr = Address{ .port = std.mem.nativeToBig(u16, port) };
    const result = if (binding) bind(fd, &addr, @sizeOf(Address)) else connect(fd, &addr, @sizeOf(Address));
    if (want_denial) return result == -1 and denied();
    if (result != 0) return false;
    if (binding) return listen(fd, 1) == 0;
    const marker = "synthetic-local-fixture\n";
    var buf: [marker.len]u8 = undefined;
    var used: usize = 0;
    while (used < buf.len) {
        const n = read(fd, buf[used..].ptr, buf.len - used);
        if (n <= 0) return false;
        used += @intCast(n);
    }
    return eq(&buf, marker);
}
fn rawDenied(result: usize) bool {
    const e = linux.errno(result);
    return e == .PERM or e == .ACCES;
}
var all = true;
fn check(name: []const u8, value: bool) void {
    emit("\"");
    emit(name);
    emit(if (value) "\":true" else "\":false");
    all = all and value;
}
fn next(name: []const u8, value: bool) void {
    emit(",");
    check(name, value);
}
fn baseline(self_status: bool) c_int {
    var buf: [8192]u8 = undefined;
    emit("{");
    check("target_identity", getuid() == 10001 and geteuid() == 10001 and getgid() == 10001 and getegid() == 10001 and getgroups(0, null) == 0);
    if (self_status) {
        const status = contents("/proc/self/status", &buf) orelse "";
        next("self_status_readable", status.len > 0);
        var caps = true;
        for ([_][]const u8{ "CapInh", "CapPrm", "CapEff", "CapAmb" }) |key| {
            var text: [64]u8 = undefined;
            const needle = std.fmt.bufPrint(&text, "{s}:\t0000000000000000\n", .{key}) catch unreachable;
            caps = caps and std.mem.indexOf(u8, status, needle) != null;
        }
        next("capabilities_zero", caps);
        next("bounding_set_transition_only", std.mem.indexOf(u8, status, "CapBnd:\t00000000000000c0\n") != null or std.mem.indexOf(u8, status, "CapBnd:\t0000000000000000\n") != null);
        next("no_new_privileges", std.mem.indexOf(u8, status, "NoNewPrivs:\t1\n") != null);
        next("seccomp_filter", std.mem.indexOf(u8, status, "Seccomp:\t2\n") != null);
    }
    next("limits", limit(4, 0) and limit(0, 40) and limit(1, 8388608) and limit(7, 256));
    next("cgroup_memory", bounded("/sys/fs/cgroup/memory.max", 2048 * 1024 * 1024));
    next("cgroup_pids", bounded("/sys/fs/cgroup/pids.max", 256));
    next("environment_exact", environment());
    next("no_extra_fds", noExtraFds());
    var byte: [1]u8 = undefined;
    const flags = fcntl(0, 3);
    next("stdin_eof", flags >= 0 and fcntl(0, 4, flags | @as(c_int, 2048)) == 0 and read(0, &byte, 1) == 0);
    next("cwd_private", if (getcwd(&buf, buf.len)) |cwd| eq(std.mem.span(cwd), "/work") else false);
    const mask = umask(0o077);
    next("umask_private", mask == 0o077);
    next("work_writable", writable("/work/f02-probe"));
    next("tmp_writable", writable("/tmp/f02-probe"));
    next("root_write_denied", noWrite("/f02-probe"));
    next("etc_write_denied", noWrite("/etc/f02-probe"));
    next("runtime_write_denied", noWrite("/usr/local/bin/f02-probe"));
    next("containment_read_denied", unreadable("/containment/forbidden"));
    next("boundary_read_denied", unreadable("/boundary/forbidden"));
    next("owner_fd_denied", unreadable("/proc/1/fd/0"));
    next("tcp_allowed", tcp(39001, false, false));
    next("tcp_denied", tcp(39002, false, true));
    next("bind_allowed", tcp(39003, true, false));
    next("bind_denied", tcp(39004, true, true));
    next("udp_denied", socketDenied(2, 2, 0));
    next("udp6_denied", socketDenied(10, 2, 0));
    next("unix_denied", socketDenied(1, 1, 0));
    next("raw_denied", socketDenied(2, 3, 1));
    next("packet_denied", socketDenied(17, 3, 0));
    var pair: [2]c_int = undefined;
    const result = socketpair(1, 1, 0, &pair);
    const pair_denied = result < 0 and denied();
    if (result == 0) {
        _ = close(pair[0]);
        _ = close(pair[1]);
    }
    next("socketpair_denied", pair_denied);
    var params: [120]u8 align(8) = @splat(0);
    const ring = linux.syscall2(.io_uring_setup, 1, @intFromPtr(&params));
    next("io_uring_denied", rawDenied(ring));
    if (linux.errno(ring) == .SUCCESS) {
        _ = close(@intCast(ring));
    }
    // Invalid arguments must still get seccomp's permission denial, never EINVAL/EBADF.
    // This avoids creating a namespace even if the filter is accidentally absent.
    next("network_namespace_denied", rawDenied(linux.syscall1(.unshare, 0x40000001)));
    next("setns_denied", rawDenied(linux.syscall2(.setns, @as(usize, @bitCast(@as(isize, -1))), 0x40000000)));
    emit("}\n");
    return if (all) 0 else 1;
}
const readiness = "{\"fixture_ready\":true,\"listening_39001\":true,\"listening_39002\":true}\n";
fn fixture() c_int {
    if (getuid() != 0) return 2;
    var polls: [2]Poll = undefined;
    for ([_]u16{ 39001, 39002 }, 0..) |port, i| {
        const fd = socket(2, 1, 0);
        if (fd < 0) return 2;
        const addr = Address{ .port = std.mem.nativeToBig(u16, port) };
        if (bind(fd, &addr, @sizeOf(Address)) != 0 or listen(fd, 16) != 0) return 2;
        polls[i] = .{ .fd = fd };
    }
    emit(readiness);
    // alarm is absolute: traffic cannot extend fixture lifetime.
    while (poll(&polls, 2, 1000) >= 0) {
        for (&polls) |*p| {
            if (p.revents & 1 != 0) {
                const fd = accept(p.fd, null, null);
                if (fd >= 0) {
                    const marker = "synthetic-local-fixture\n";
                    _ = write(fd, marker, marker.len);
                    _ = close(fd);
                }
            }
        }
    }
    return 2;
}
fn descendant() c_int {
    const pid = fork();
    if (pid < 0) return 2;
    if (pid == 0) {
        _ = alarm(6);
        const args = [_:null]?[*:0]const u8{ executable, "inherited" };
        _ = execve(args[0].?, &args, environ);
        _exit(2);
    }
    var status: c_int = 0;
    const ok = waitpid(pid, &status, 0) == pid and status == 0;
    emit(if (ok) "{\"descendant_inherited\":true}\n" else "{\"descendant_inherited\":false}\n");
    return if (ok) 0 else 1;
}
pub export fn main(argc: c_int, argv: [*][*:0]u8) c_int {
    _ = alarm(8);
    if (argc != 2) return 2;
    const mode = std.mem.span(argv[1]);
    if (eq(mode, "fixture")) {
        _ = alarm(30);
        return fixture();
    }
    if (eq(mode, "marker")) {
        const fd = open("/work/forbidden-exec-marker", 0xC1, @as(c_uint, 0o600));
        if (fd >= 0) {
            _ = write(fd, "synthetic\n", 10);
            _ = close(fd);
        }
        emit("{\"forbidden_exec_reached\":true}\n");
        return 99;
    }
    if (eq(mode, "baseline")) return baseline(true);
    if (eq(mode, "inherited")) return baseline(false);
    if (eq(mode, "descendant")) return descendant();
    if (eq(mode, "suite")) return suite();
    return 2;
}

const normal = [_]?[*:0]const u8{ launch, "--bind-ports", "39003", "--connect-ports", "39001", "--cpu-seconds", "40", "--file-bytes", "8388608", "--no-files", "256", "--", executable };
const Run = struct { status: c_int, output: [16384]u8, len: usize, bounded: bool };
fn run(args: [*:null]const ?[*:0]const u8, unprivileged: bool) Run {
    var result = Run{ .status = -1, .output = undefined, .len = 0, .bounded = false };
    var fds: [2]c_int = undefined;
    if (pipe(&fds) != 0) return result;
    const pid = fork();
    if (pid < 0) {
        _ = close(fds[0]);
        _ = close(fds[1]);
        return result;
    }
    if (pid == 0) {
        _ = alarm(7);
        _ = close(fds[0]);
        if (dup2(fds[1], 1) < 0 or dup2(fds[1], 2) < 0) _exit(2);
        _ = close(fds[1]);
        // Deliberately inherit descriptors on both sides of the lowered NOFILE.
        const fd = open("/dev/null", 0);
        if (fd < 0 or dup2(fd, 42) < 0 or dup2(fd, 300) < 0) _exit(2);
        if (unprivileged and (setgid(10001) != 0 or setuid(10001) != 0)) _exit(2);
        _ = execve(launch, args, environ);
        _exit(2);
    }
    _ = close(fds[1]);
    while (result.len < result.output.len) {
        const n = read(fds[0], result.output[result.len..].ptr, result.output.len - result.len);
        if (n == 0) {
            result.bounded = true;
            break;
        }
        if (n < 0) break;
        result.len += @intCast(n);
    }
    _ = close(fds[0]);
    if (!result.bounded) _ = kill(pid, 9);
    _ = waitpid(pid, &result.status, 0);
    return result;
}
fn goodReport(result: *const Run) bool {
    // Exact JSON schema is independently checked by host QA as well.
    return result.bounded and result.status == 0 and result.len > 0 and
        std.mem.indexOf(u8, result.output[0..result.len], ":false") == null;
}
fn markerAbsent() bool {
    // Trusted QA has no DAC_OVERRIDE: inspect private /work as its owner.
    // A helper avoids changing the coordinator's identity or filesystem UID.
    const pid = fork();
    if (pid < 0) return false;
    if (pid == 0) {
        _ = alarm(2);
        if (setgid(10001) != 0 or setuid(10001) != 0) _exit(2);
        const fd = open("/work/forbidden-exec-marker", 0);
        if (fd >= 0) {
            _ = close(fd);
            _exit(1);
        }
        _exit(if (__errno_location().* == 2) 0 else 2);
    }
    var status: c_int = 0;
    return waitpid(pid, &status, 0) == pid and status == 0;
}
fn suite() c_int {
    _ = alarm(30);
    if (getuid() != 0 or !markerAbsent()) return 2;
    // Fail before running anything if mandatory synthetic denial fixtures are missing.
    var buf: [64]u8 = undefined;
    for ([_][*:0]const u8{ "/containment/forbidden", "/boundary/forbidden" }) |path| {
        if (!eq(contents(path, &buf) orelse return 2, "synthetic\n")) return 2;
    }
    var ready: [2]c_int = undefined;
    if (pipe(&ready) != 0) return 2;
    const fixture_pid = fork();
    if (fixture_pid < 0) return 2;
    if (fixture_pid == 0) {
        _ = alarm(30);
        _ = close(ready[0]);
        if (dup2(ready[1], 1) < 0) _exit(2);
        _ = close(ready[1]);
        _exit(fixture());
    }
    _ = close(ready[1]);
    defer {
        _ = kill(fixture_pid, 9);
        var status: c_int = 0;
        _ = waitpid(fixture_pid, &status, 0);
    }
    var ready_buf: [readiness.len]u8 = undefined;
    var used: usize = 0;
    while (used < ready_buf.len) {
        const n = read(ready[0], ready_buf[used..].ptr, ready_buf.len - used);
        if (n <= 0) {
            _ = close(ready[0]);
            return 2;
        }
        used += @intCast(n);
    }
    _ = close(ready[0]);
    if (!eq(&ready_buf, readiness)) return 2;
    emit(readiness);
    const check_args = [_:null]?[*:0]const u8{ launch, "--check" };
    const version = run(&check_args, false);
    const version_ok = version.bounded and version.status == 0 and eq(version.output[0..version.len], "mimic.containment-launch/v1\n");
    emit(if (version_ok) "{\"check_exact\":true}\n" else "{\"check_exact\":false}\n");
    if (!version_ok) return 1;
    for ([_][*:0]const u8{ "baseline", "descendant" }) |mode| {
        var args: [normal.len + 1:null]?[*:0]const u8 = undefined;
        @memcpy(args[0..normal.len], &normal);
        args[normal.len] = mode;
        args[normal.len + 1] = null;
        const result = run(&args, false);
        // Probe output contains booleans only; never relay arbitrary launcher errors.
        if (!goodReport(&result)) {
            emitBooleans(result.output[0..result.len]);
            emit("{\"target_report_valid\":false}\n");
            return 1;
        }
        emit(result.output[0..result.len]);
    }
    // Fixed malformed cases retain the marker target. Exit 99 or any output from
    // marker is failure; an exec failure is not accepted as launcher rejection.
    for (0..6) |case| {
        var args: [normal.len + 1:null]?[*:0]const u8 = undefined;
        @memcpy(args[0..normal.len], &normal);
        args[normal.len] = "marker";
        args[normal.len + 1] = null;
        switch (case) {
            0 => args[2] = "65536",
            1 => args[4] = "39001,,39002",
            2 => args[6] = "0",
            3 => args[10] = "-1",
            4 => args[1] = "--unknown-synthetic-option",
            5 => {},
            else => unreachable,
        }
        const result = run(&args, case == 5);
        const clean = std.mem.indexOf(u8, result.output[0..result.len], "forbidden_exec_reached") == null and
            std.mem.indexOf(u8, result.output[0..result.len], "unknown-synthetic-option") == null;
        // Normal exit, nonzero, not exec marker, not timeout/signal.
        const rejected = result.bounded and result.status & 127 == 0 and result.status >> 8 != 0 and result.status >> 8 != 99 and markerAbsent() and clean;
        if (!rejected) {
            emit("{\"malformed_cli_no_exec\":false}\n");
            return 1;
        }
    }
    emit("{\"malformed_cli_no_exec\":true,\"suite_passed\":true}\n");
    return 0;
}

// On failure expose only boolean fields, never raw launcher stderr or data.
fn emitBooleans(text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .bool) continue;
            var safe = entry.key_ptr.len > 0 and entry.key_ptr.len < 80;
            for (entry.key_ptr.*) |c| {
                safe = safe and ((c >= 'a' and c <= 'z') or c == '_');
            }
            if (!safe) continue;
            emit("{");
            check(entry.key_ptr.*, entry.value_ptr.bool);
            emit("}\n");
        }
    }
}
