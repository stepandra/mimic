const std = @import("std");
pub const Ports = struct { values: [16]u16 = undefined, len: usize = 0 };
pub const Config = struct { check: bool = false, bind: Ports, connect: Ports, target: usize };
pub fn ports(s: []const u8) !Ports {
    var out: Ports = .{};
    if (std.mem.eql(u8, s, "-")) return out;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |item| {
        if (item.len == 0 or item[0] == '0' or out.len == out.values.len) return error.BadPorts;
        for (item) |c| if (c < '0' or c > '9') return error.BadPorts;
        const p = std.fmt.parseInt(u16, item, 10) catch return error.BadPorts;
        for (out.values[0..out.len]) |old| if (p == old) return error.BadPorts;
        out.values[out.len] = p;
        out.len += 1;
    }
    return out;
}
pub fn parse(args: []const [:0]const u8) !Config {
    if (args.len == 2 and std.mem.eql(u8, args[1], "--check")) return .{ .check = true, .bind = try ports("39003"), .connect = try ports("39001"), .target = 0 };
    if (args.len > 256) return error.BadArguments;
    var bytes: usize = 0;
    for (args) |arg| {
        bytes += arg.len;
        if (bytes > 131072) return error.BadArguments;
    }
    if (args.len < 13) return error.BadArguments;
    const fixed = [_]struct { usize, []const u8 }{ .{ 1, "--bind-ports" }, .{ 3, "--connect-ports" }, .{ 5, "--cpu-seconds" }, .{ 6, "40" }, .{ 7, "--file-bytes" }, .{ 8, "8388608" }, .{ 9, "--no-files" }, .{ 10, "256" }, .{ 11, "--" } };
    for (fixed) |f| if (!std.mem.eql(u8, args[f[0]], f[1])) return error.BadArguments;
    if (args[12].len == 0 or args[12].len > 4095 or args[12][0] != '/') return error.BadTarget;
    return .{ .bind = try ports(args[2]), .connect = try ports(args[4]), .target = 12 };
}
pub const Insn = extern struct { code: u16, jt: u8 = 0, jf: u8 = 0, k: u32 };
pub const Filter = struct {
    insns: [512]Insn = undefined,
    len: usize = 0,
    pub fn add(f: *Filter, code: u16, jt: u8, jf: u8, k: u32) void {
        f.insns[f.len] = .{ .code = code, .jt = jt, .jf = jf, .k = k };
        f.len += 1;
    }
    pub fn deny(f: *Filter, nr: u32) void {
        f.add(0x15, 0, 1, nr);
        f.add(0x06, 0, 0, 0x50001);
    }
};
pub const Arch = enum { x86_64, aarch64 };
pub fn filter(comptime arch: Arch) Filter {
    const L = std.os.linux;
    const S = if (arch == .x86_64) L.syscalls.X64 else L.syscalls.Arm64;
    var f: Filter = .{};
    f.add(0x20, 0, 0, 4);
    f.add(0x15, 1, 0, if (arch == .x86_64) 0xc000003e else 0xc00000b7);
    f.add(0x06, 0, 0, 0x80000000);
    f.add(0x20, 0, 0, 0);
    f.add(0x35, 0, 1, 0x40000000); // x32 / invalid syscall namespace
    f.add(0x06, 0, 0, 0x80000000);
    inline for (.{ "socketpair", "io_uring_setup", "io_uring_enter", "io_uring_register", "unshare", "setns", "mount", "umount2", "pivot_root", "chroot", "open_by_handle_at", "name_to_handle_at", "ptrace", "process_vm_readv", "process_vm_writev", "pidfd_getfd", "pidfd_open", "bpf", "perf_event_open", "userfaultfd", "keyctl", "add_key", "request_key", "reboot", "kexec_load", "init_module", "finit_module", "delete_module", "swapon", "swapoff", "acct", "quotactl", "fanotify_init", "setuid", "setgid", "setreuid", "setregid", "setresuid", "setresgid", "setfsuid", "setfsgid", "setgroups", "capset", "prctl", "seccomp", "ioctl", "sendmsg", "recvmsg", "sendmmsg", "recvmmsg", "fsopen", "fsconfig", "fsmount", "fspick", "move_mount", "open_tree", "mount_setattr" }) |name| {
        if (@hasField(S, name)) f.deny(@intFromEnum(@field(S, name)));
    }
    f.add(0x15, 0, 1, @intFromEnum(S.clone3));
    f.add(0x06, 0, 0, 0x50026); // ENOSYS: libc can fall back to filtered clone
    f.add(0x15, 0, 4, @intFromEnum(S.clone));
    f.add(0x20, 0, 0, 16);
    f.add(0x45, 0, 1, 0x7e028080); // namespace flags and CLONE_PARENT
    f.add(0x06, 0, 0, 0x50001);
    f.add(0x06, 0, 0, 0x7fff0000);
    // Only SO_REUSEADDR, used by the existing Python HTTPServer fixture.
    f.add(0x15, 0, 13, @intFromEnum(S.setsockopt));
    inline for (.{ .{ 28, 0 }, .{ 36, 0 }, .{ 24, 1 }, .{ 32, 2 } }) |pair| {
        f.add(0x20, 0, 0, pair[0]);
        f.add(0x15, 1, 0, pair[1]);
        f.add(0x06, 0, 0, 0x50001);
    }
    f.add(0x06, 0, 0, 0x7fff0000);
    f.add(0x15, 1, 0, @intFromEnum(S.socket));
    f.add(0x06, 0, 0, 0x7fff0000);
    inline for (.{ 20, 28, 36 }) |offset| {
        f.add(0x20, 0, 0, offset);
        f.add(0x15, 1, 0, 0);
        f.add(0x06, 0, 0, 0x50001);
    }
    f.add(0x20, 0, 0, 16);
    f.add(0x15, 2, 0, 2);
    f.add(0x15, 1, 0, 10);
    f.add(0x06, 0, 0, 0x50001);
    f.add(0x20, 0, 0, 24);
    f.add(0x54, 0, 0, ~@as(u32, 0x80800)); // CLOEXEC/NONBLOCK only
    f.add(0x15, 1, 0, 1);
    f.add(0x06, 0, 0, 0x50001);
    f.add(0x20, 0, 0, 32);
    f.add(0x15, 2, 0, 0);
    f.add(0x15, 1, 0, 6);
    f.add(0x06, 0, 0, 0x50001);
    f.add(0x06, 0, 0, 0x7fff0000);
    return f;
}
test "strict owner CLI and finite port sets" {
    _ = try parse(&.{ "launch", "--check" });
    _ = try parse(&.{ "launch", "--bind-ports", "-", "--connect-ports", "1,65535", "--cpu-seconds", "40", "--file-bytes", "8388608", "--no-files", "256", "--", "/usr/bin/true" });
    for ([_][]const u8{ "", "0", "01", "1,", ",1", "1,1", "65536", "+1", " 1" }) |s| try std.testing.expectError(error.BadPorts, ports(s));
    try std.testing.expectError(error.BadArguments, parse(&.{ "launch", "--check", "extra" }));
}
fn evaluate(f: Filter, arch: u32, nr: u32, args: [6]u64) u32 {
    var data: [16]u32 = @splat(0);
    data[0] = nr;
    data[1] = arch;
    for (args, 0..) |arg, i| {
        data[4 + i * 2] = @truncate(arg);
        data[5 + i * 2] = @truncate(arg >> 32);
    }
    var a: u32 = 0;
    var pc: usize = 0;
    while (pc < f.len) : (pc += 1) {
        const ins = f.insns[pc];
        switch (ins.code) {
            0x20 => a = data[ins.k / 4],
            0x15 => pc += if (a == ins.k) ins.jt else ins.jf,
            0x35 => pc += if (a >= ins.k) ins.jt else ins.jf,
            0x45 => pc += if (a & ins.k != 0) ins.jt else ins.jf,
            0x54 => a &= ins.k,
            0x06 => return ins.k,
            else => unreachable,
        }
    }
    unreachable;
}
test "both BPF architectures reject bypasses and permit TCP/fork" {
    inline for (.{ Arch.x86_64, Arch.aarch64 }) |arch| {
        const S = if (arch == .x86_64) std.os.linux.syscalls.X64 else std.os.linux.syscalls.Arm64;
        const audit: u32 = if (arch == .x86_64) 0xc000003e else 0xc00000b7;
        const f = filter(arch);
        try std.testing.expectEqual(@as(u32, 0x80000000), evaluate(f, 0, 0, @splat(0)));
        try std.testing.expectEqual(@as(u32, 0x80000000), evaluate(f, audit, 0x40000029, @splat(0)));
        for ([_][3]u64{ .{ 2, 1, 0 }, .{ 10, 0x80801, 6 } }) |v| try std.testing.expectEqual(@as(u32, 0x7fff0000), evaluate(f, audit, @intFromEnum(S.socket), .{ v[0], v[1], v[2], 0, 0, 0 }));
        for ([_][3]u64{ .{ 1, 1, 0 }, .{ 2, 2, 0 }, .{ 2, 3, 6 }, .{ 2, 1, 17 }, .{ 2, 0x10001, 0 }, .{ 0x100000002, 1, 0 } }) |v| try std.testing.expectEqual(@as(u32, 0x50001), evaluate(f, audit, @intFromEnum(S.socket), .{ v[0], v[1], v[2], 0, 0, 0 }));
        try std.testing.expectEqual(@as(u32, 0x50001), evaluate(f, audit, @intFromEnum(S.clone), .{ 0x10000000, 0, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u32, 0x7fff0000), evaluate(f, audit, @intFromEnum(S.clone), .{ 17, 0, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u32, 0x50026), evaluate(f, audit, @intFromEnum(S.clone3), @splat(0)));
        try std.testing.expectEqual(@as(u32, 0x50001), evaluate(f, audit, @intFromEnum(S.clone), .{ 0x8000, 0, 0, 0, 0, 0 }));
        try std.testing.expectEqual(@as(u32, 0x7fff0000), evaluate(f, audit, @intFromEnum(S.setsockopt), .{ 3, 1, 2, 0, 4, 0 }));
        try std.testing.expectEqual(@as(u32, 0x50001), evaluate(f, audit, @intFromEnum(S.setsockopt), .{ 3, 1, 25, 0, 4, 0 }));
        try std.testing.expectEqual(@as(u32, 0x50001), evaluate(f, audit, @intFromEnum(S.io_uring_setup), @splat(0)));
    }
}
