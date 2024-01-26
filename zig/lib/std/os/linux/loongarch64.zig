const std = @import("../../std.zig");
const maxInt = std.math.maxInt;
const linux = std.os.linux;
const SYS = linux.SYS;
const socklen_t = linux.socklen_t;
const sockaddr = linux.sockaddr;
const iovec = std.os.iovec;
const iovec_const = std.os.iovec_const;
const uid_t = linux.uid_t;
const gid_t = linux.gid_t;
const pid_t = linux.pid_t;
const stack_t = linux.stack_t;
const sigset_t = linux.sigset_t;
const timespec = std.os.linux.timespec;

// TODO

pub const blksize_t = i32;
pub const nlink_t = u32;
pub const time_t = isize;
pub const mode_t = u32;
pub const off_t = isize;
pub const ino_t = usize;
pub const dev_t = usize;
pub const blkcnt_t = isize;

pub const timeval = extern struct {
    tv_sec: time_t,
    tv_usec: i64,
};

pub const MAP = struct {
    /// stack-like segment
    pub const GROWSDOWN = 0x0100;
    /// ETXTBSY
    pub const DENYWRITE = 0x0800;
    /// mark it as an executable
    pub const EXECUTABLE = 0x1000;
    /// pages are locked
    pub const LOCKED = 0x2000;
    /// don't check for reservations
    pub const NORESERVE = 0x4000;
};

pub const VDSO = struct {
    pub const CGT_SYM = "__kernel_clock_gettime";
    pub const CGT_VER = "LINUX_5.10";
};
