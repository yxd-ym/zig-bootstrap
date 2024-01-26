const std = @import("../../std.zig");
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

pub fn syscall0(number: SYS) usize {
    return asm volatile ("syscall 0\n\t"
        : [ret] "={$a0}" (-> usize),
        : [number] "{$a7}" (@intFromEnum(number)),
        : "$t0", "$t1", "$t2", "$t3", "$t4", "$t5", "$t6", "$t7", "$t8", "memory"
    );
}

pub fn syscall1(number: SYS, arg1: usize) usize {
    return asm volatile ("syscall 0\n\t"
        : [ret] "={$a0}" (-> usize),
        : [number] "{$a7}" (@intFromEnum(number)),
          [arg1] "${$a0}" (arg1),
        : "$t0", "$t1", "$t2", "$t3", "$t4", "$t5", "$t6", "$t7", "$t8", "memory"
    );
}

pub fn syscall2(number: SYS, arg1: usize, arg2: usize) usize {
    return asm volatile ("syscall 0\n\t"
        : [ret] "={$a0}" (-> usize),
        : [number] "{$a7}" (@intFromEnum(number)),
          [arg1] "{$a0}" (arg1),
          [arg2] "{$a1}" (arg2),
        : "$t0", "$t1", "$t2", "$t3", "$t4", "$t5", "$t6", "$t7", "$t8", "memory"
    );
}

pub fn syscall3(number: SYS, arg1: usize, arg2: usize, arg3: usize) usize {
    return asm volatile ("syscall 0\n\t"
        : [ret] "={$a0}" (-> usize),
        : [number] "{$a7}" (@intFromEnum(number)),
          [arg1] "{$a0}" (arg1),
          [arg2] "{$a1}" (arg2),
          [arg3] "{$a2}" (arg3),
        : "$t0", "$t1", "$t2", "$t3", "$t4", "$t5", "$t6", "$t7", "$t8", "memory"
    );
}

pub fn syscall4(number: SYS, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
    return asm volatile ("syscall 0\n\t"
        : [ret] "={$a0}" (-> usize),
        : [number] "{$a7}" (@intFromEnum(number)),
          [arg1] "{$a0}" (arg1),
          [arg2] "{$a1}" (arg2),
          [arg3] "{$a2}" (arg3),
          [arg4] "{$a3}" (arg4),
        : "$t0", "$t1", "$t2", "$t3", "$t4", "$t5", "$t6", "$t7", "$t8", "memory"
    );
}

pub fn syscall5(number: SYS, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
    return asm volatile ("syscall 0\n\t"
        : [ret] "={$a0}" (-> usize),
        : [number] "{$a7}" (@intFromEnum(number)),
          [arg1] "{$a0}" (arg1),
          [arg2] "{$a1}" (arg2),
          [arg3] "{$a2}" (arg3),
          [arg4] "{$a3}" (arg4),
          [arg5] "{$a4}" (arg5),
        : "$t0", "$t1", "$t2", "$t3", "$t4", "$t5", "$t6", "$t7", "$t8", "memory"
    );
}

pub fn syscall6(
    number: SYS,
    arg1: usize,
    arg2: usize,
    arg3: usize,
    arg4: usize,
    arg5: usize,
    arg6: usize,
) usize {
    return asm volatile ("syscall 0\n\t"
        : [ret] "={$a0}" (-> usize),
        : [number] "{$a7}" (@intFromEnum(number)),
          [arg1] "{$a0}" (arg1),
          [arg2] "{$a1}" (arg2),
          [arg3] "{$a2}" (arg3),
          [arg4] "{$a3}" (arg4),
          [arg5] "{$a4}" (arg5),
          [arg6] "{$a5}" (arg6),
        : "$t0", "$t1", "$t2", "$t3", "$t4", "$t5", "$t6", "$t7", "$t8", "memory"
    );
}

pub fn syscall7(
    number: SYS,
    arg1: usize,
    arg2: usize,
    arg3: usize,
    arg4: usize,
    arg5: usize,
    arg6: usize,
    arg7: usize,
) usize {
    return asm volatile ("syscall 0\n\t"
        : [ret] "={$a0}" (-> usize),
        : [number] "{$a7}" (@intFromEnum(number)),
          [arg1] "{$a0}" (arg1),
          [arg2] "{$a1}" (arg2),
          [arg3] "{$a2}" (arg3),
          [arg4] "{$a3}" (arg4),
          [arg5] "{$a4}" (arg5),
          [arg6] "{$a5}" (arg6),
          [arg7] "{$a6}" (arg7),
        : "$t0", "$t1", "$t2", "$t3", "$t4", "$t5", "$t6", "$t7", "$t8", "memory"
    );
}

pub const LOCK = struct {
    pub const SH = 1;
    pub const EX = 2;
    pub const UN = 8;
    pub const NB = 4;
};

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

pub const O = struct {
    pub const CREAT = 0o100;
    pub const EXCL = 0o200;
    pub const NOCTTY = 0o400;
    pub const TRUNC = 0o1000;
    pub const APPEND = 0o2000;
    pub const NONBLOCK = 0o4000;
    pub const DSYNC = 0o10000;
    pub const SYNC = 0o4010000;
    pub const RSYNC = 0o4010000;
    pub const DIRECTORY = 0o200000;
    pub const NOFOLLOW = 0o400000;
    pub const CLOEXEC = 0o2000000;

    pub const ASYNC = 0o20000;
    pub const DIRECT = 0o40000;
    pub const LARGEFILE = 0o100000;
    pub const NOATIME = 0o1000000;
    pub const PATH = 0o10000000;
    pub const TMPFILE = 0o20200000;
    pub const NDELAY = NONBLOCK;
};

pub const F = struct {
    pub const DUPFD = 0;
    pub const GETFD = 1;
    pub const SETFD = 2;
    pub const GETFL = 3;
    pub const SETFL = 4;
    pub const GETLK = 5;
    pub const SETLK = 6;
    pub const SETLKW = 7;
    pub const SETOWN = 8;
    pub const GETOWN = 9;
    pub const SETSIG = 10;
    pub const GETSIG = 11;

    pub const RDLCK = 0;
    pub const WRLCK = 1;
    pub const UNLCK = 2;

    pub const SETOWN_EX = 15;
    pub const GETOWN_EX = 16;

    pub const GETOWNER_UIDS = 17;
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

pub const Stat = extern struct {
    dev: dev_t,
    ino: ino_t,
    mode: mode_t,
    nlink: nlink_t,
    uid: uid_t,
    gid: gid_t,
    rdev: dev_t,
    __pad: usize,
    size: off_t,
    blksize: blksize_t,
    __pad2: i32,
    blocks: blkcnt_t,
    atim: timespec,
    mtim: timespec,
    ctim: timespec,
    __unused: [2]u32,

    pub fn atime(self: @This()) timespec {
        return self.atim;
    }

    pub fn mtime(self: @This()) timespec {
        return self.mtim;
    }

    pub fn ctime(self: @This()) timespec {
        return self.ctim;
    }
};

pub const mcontext_t = extern struct {
    pc: usize,
    regs: [32]usize,
    flags: u32,
};

pub const ucontext_t = extern struct {
    flags: usize,
    link: ?*ucontext_t,
    stack: stack_t,
    sigmask: sigset_t,
    mcontext: mcontext_t,
};
