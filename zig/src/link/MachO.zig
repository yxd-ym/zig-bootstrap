const MachO = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const fs = std.fs;
const log = std.log.scoped(.link);
const macho = std.macho;
const codegen = @import("../codegen.zig");
const aarch64 = @import("../codegen/aarch64.zig");
const math = std.math;
const mem = std.mem;

const trace = @import("../tracy.zig").trace;
const Type = @import("../type.zig").Type;
const build_options = @import("build_options");
const Module = @import("../Module.zig");
const Compilation = @import("../Compilation.zig");
const link = @import("../link.zig");
const File = link.File;
const Cache = @import("../Cache.zig");
const target_util = @import("../target.zig");

const Trie = @import("MachO/Trie.zig");
const CodeSignature = @import("MachO/CodeSignature.zig");

usingnamespace @import("MachO/commands.zig");

pub const base_tag: File.Tag = File.Tag.macho;

base: File,

/// Page size is dependent on the target cpu architecture.
/// For x86_64 that's 4KB, whereas for aarch64, that's 16KB.
page_size: u16,

/// Mach-O header
header: ?macho.mach_header_64 = null,

/// Table of all load commands
load_commands: std.ArrayListUnmanaged(LoadCommand) = .{},
/// __PAGEZERO segment
pagezero_segment_cmd_index: ?u16 = null,
/// __TEXT segment
text_segment_cmd_index: ?u16 = null,
/// __DATA segment
data_segment_cmd_index: ?u16 = null,
/// __LINKEDIT segment
linkedit_segment_cmd_index: ?u16 = null,
/// Dyld info
dyld_info_cmd_index: ?u16 = null,
/// Symbol table
symtab_cmd_index: ?u16 = null,
/// Dynamic symbol table
dysymtab_cmd_index: ?u16 = null,
/// Path to dyld linker
dylinker_cmd_index: ?u16 = null,
/// Path to libSystem
libsystem_cmd_index: ?u16 = null,
/// Data-in-code section of __LINKEDIT segment
data_in_code_cmd_index: ?u16 = null,
/// Address to entry point function
function_starts_cmd_index: ?u16 = null,
/// Main/entry point
/// Specifies offset wrt __TEXT segment start address to the main entry point
/// of the binary.
main_cmd_index: ?u16 = null,
/// Minimum OS version
version_min_cmd_index: ?u16 = null,
/// Source version
source_version_cmd_index: ?u16 = null,
/// Code signature
code_signature_cmd_index: ?u16 = null,

/// Index into __TEXT,__text section.
text_section_index: ?u16 = null,
/// Index into __TEXT,__got section.
got_section_index: ?u16 = null,
/// The absolute address of the entry point.
entry_addr: ?u64 = null,

/// TODO move this into each Segment aggregator
linkedit_segment_next_offset: ?u32 = null,

/// Table of all local symbols
/// Internally references string table for names (which are optional).
local_symbols: std.ArrayListUnmanaged(macho.nlist_64) = .{},
/// Table of all defined global symbols
global_symbols: std.ArrayListUnmanaged(macho.nlist_64) = .{},
/// Table of all undefined symbols
undef_symbols: std.ArrayListUnmanaged(macho.nlist_64) = .{},

local_symbol_free_list: std.ArrayListUnmanaged(u32) = .{},
global_symbol_free_list: std.ArrayListUnmanaged(u32) = .{},
offset_table_free_list: std.ArrayListUnmanaged(u32) = .{},

dyld_stub_binder_index: ?u16 = null,

/// Table of symbol names aka the string table.
string_table: std.ArrayListUnmanaged(u8) = .{},

/// Table of symbol vaddr values. The values is the absolute vaddr value.
/// If the vaddr of the executable __TEXT segment vaddr changes, the entire offset
/// table needs to be rewritten.
offset_table: std.ArrayListUnmanaged(u64) = .{},

error_flags: File.ErrorFlags = File.ErrorFlags{},

cmd_table_dirty: bool = false,

/// A list of text blocks that have surplus capacity. This list can have false
/// positives, as functions grow and shrink over time, only sometimes being added
/// or removed from the freelist.
///
/// A text block has surplus capacity when its overcapacity value is greater than
/// minimum_text_block_size * alloc_num / alloc_den. That is, when it has so
/// much extra capacity, that we could fit a small new symbol in it, itself with
/// ideal_capacity or more.
///
/// Ideal capacity is defined by size * alloc_num / alloc_den.
///
/// Overcapacity is measured by actual_capacity - ideal_capacity. Note that
/// overcapacity can be negative. A simple way to have negative overcapacity is to
/// allocate a fresh text block, which will have ideal capacity, and then grow it
/// by 1 byte. It will then have -1 overcapacity.
text_block_free_list: std.ArrayListUnmanaged(*TextBlock) = .{},
/// Pointer to the last allocated text block
last_text_block: ?*TextBlock = null,
/// A list of all PIE fixups required for this run of the linker.
/// Warning, this is currently NOT thread-safe. See the TODO below.
/// TODO Move this list inside `updateDecl` where it should be allocated
/// prior to calling `generateSymbol`, and then immediately deallocated
/// rather than sitting in the global scope.
pie_fixups: std.ArrayListUnmanaged(PieFixup) = .{},

pub const PieFixup = struct {
    /// Target address we wanted to address in absolute terms.
    address: u64,
    /// Where in the byte stream we should perform the fixup.
    start: usize,
    /// The length of the byte stream. For x86_64, this will be
    /// variable. For aarch64, it will be fixed at 4 bytes.
    len: usize,
};

/// `alloc_num / alloc_den` is the factor of padding when allocating.
const alloc_num = 4;
const alloc_den = 3;

/// Default path to dyld
/// TODO instead of hardcoding it, we should probably look through some env vars and search paths
/// instead but this will do for now.
const DEFAULT_DYLD_PATH: [*:0]const u8 = "/usr/lib/dyld";

/// Default lib search path
/// TODO instead of hardcoding it, we should probably look through some env vars and search paths
/// instead but this will do for now.
const DEFAULT_LIB_SEARCH_PATH: []const u8 = "/usr/lib";

const LIB_SYSTEM_NAME: [*:0]const u8 = "System";
/// TODO we should search for libSystem and fail if it doesn't exist, instead of hardcoding it
const LIB_SYSTEM_PATH: [*:0]const u8 = DEFAULT_LIB_SEARCH_PATH ++ "/libSystem.B.dylib";

/// In order for a slice of bytes to be considered eligible to keep metadata pointing at
/// it as a possible place to put new symbols, it must have enough room for this many bytes
/// (plus extra for reserved capacity).
const minimum_text_block_size = 64;
const min_text_capacity = minimum_text_block_size * alloc_num / alloc_den;

pub const TextBlock = struct {
    /// Each decl always gets a local symbol with the fully qualified name.
    /// The vaddr and size are found here directly.
    /// The file offset is found by computing the vaddr offset from the section vaddr
    /// the symbol references, and adding that to the file offset of the section.
    /// If this field is 0, it means the codegen size = 0 and there is no symbol or
    /// offset table entry.
    local_sym_index: u32,
    /// Index into offset table
    /// This field is undefined for symbols with size = 0.
    offset_table_index: u32,
    /// Size of this text block
    /// Unlike in Elf, we need to store the size of this symbol as part of
    /// the TextBlock since macho.nlist_64 lacks this information.
    size: u64,
    /// Points to the previous and next neighbours
    prev: ?*TextBlock,
    next: ?*TextBlock,

    pub const empty = TextBlock{
        .local_sym_index = 0,
        .offset_table_index = undefined,
        .size = 0,
        .prev = null,
        .next = null,
    };

    /// Returns how much room there is to grow in virtual address space.
    /// File offset relocation happens transparently, so it is not included in
    /// this calculation.
    fn capacity(self: TextBlock, macho_file: MachO) u64 {
        const self_sym = macho_file.local_symbols.items[self.local_sym_index];
        if (self.next) |next| {
            const next_sym = macho_file.local_symbols.items[next.local_sym_index];
            return next_sym.n_value - self_sym.n_value;
        } else {
            // We are the last block.
            // The capacity is limited only by virtual address space.
            return std.math.maxInt(u64) - self_sym.n_value;
        }
    }

    fn freeListEligible(self: TextBlock, macho_file: MachO) bool {
        // No need to keep a free list node for the last block.
        const next = self.next orelse return false;
        const self_sym = macho_file.local_symbols.items[self.local_sym_index];
        const next_sym = macho_file.local_symbols.items[next.local_sym_index];
        const cap = next_sym.n_value - self_sym.n_value;
        const ideal_cap = self.size * alloc_num / alloc_den;
        if (cap <= ideal_cap) return false;
        const surplus = cap - ideal_cap;
        return surplus >= min_text_capacity;
    }
};

pub const Export = struct {
    sym_index: ?u32 = null,
};

pub const SrcFn = struct {
    pub const empty = SrcFn{};
};

pub fn openPath(allocator: *Allocator, sub_path: []const u8, options: link.Options) !*MachO {
    assert(options.object_format == .macho);

    if (options.use_llvm) return error.LLVM_BackendIsTODO_ForMachO; // TODO
    if (options.use_lld) return error.LLD_LinkingIsTODO_ForMachO; // TODO

    const file = try options.emit.?.directory.handle.createFile(sub_path, .{
        .truncate = false,
        .read = true,
        .mode = link.determineMode(options),
    });
    errdefer file.close();

    const self = try createEmpty(allocator, options);
    errdefer {
        self.base.file = null;
        self.base.destroy();
    }

    self.base.file = file;

    // Index 0 is always a null symbol.
    try self.local_symbols.append(allocator, .{
        .n_strx = 0,
        .n_type = 0,
        .n_sect = 0,
        .n_desc = 0,
        .n_value = 0,
    });

    switch (options.output_mode) {
        .Exe => {},
        .Obj => {},
        .Lib => return error.TODOImplementWritingLibFiles,
    }

    try self.populateMissingMetadata();

    return self;
}

pub fn createEmpty(gpa: *Allocator, options: link.Options) !*MachO {
    const self = try gpa.create(MachO);
    self.* = .{
        .base = .{
            .tag = .macho,
            .options = options,
            .allocator = gpa,
            .file = null,
        },
        .page_size = if (options.target.cpu.arch == .aarch64) 0x4000 else 0x1000,
    };
    return self;
}

pub fn flush(self: *MachO, comp: *Compilation) !void {
    if (build_options.have_llvm and self.base.options.use_lld) {
        return self.linkWithLLD(comp);
    } else {
        switch (self.base.options.effectiveOutputMode()) {
            .Exe, .Obj => {},
            .Lib => return error.TODOImplementWritingLibFiles,
        }
        return self.flushModule(comp);
    }
}

pub fn flushModule(self: *MachO, comp: *Compilation) !void {
    const tracy = trace(@src());
    defer tracy.end();

    switch (self.base.options.output_mode) {
        .Exe => {
            if (self.entry_addr) |addr| {
                // Update LC_MAIN with entry offset.
                const text_segment = self.load_commands.items[self.text_segment_cmd_index.?].Segment;
                const main_cmd = &self.load_commands.items[self.main_cmd_index.?].Main;
                main_cmd.entryoff = addr - text_segment.inner.vmaddr;
            }
            try self.writeExportTrie();
            try self.writeSymbolTable();
            try self.writeStringTable();
            // Preallocate space for the code signature.
            // We need to do this at this stage so that we have the load commands with proper values
            // written out to the file.
            // The most important here is to have the correct vm and filesize of the __LINKEDIT segment
            // where the code signature goes into.
            try self.writeCodeSignaturePadding();
        },
        .Obj => {},
        .Lib => return error.TODOImplementWritingLibFiles,
    }

    if (self.cmd_table_dirty) {
        try self.writeLoadCommands();
        try self.writeHeader();
        self.cmd_table_dirty = false;
    }

    if (self.entry_addr == null and self.base.options.output_mode == .Exe) {
        log.debug("flushing. no_entry_point_found = true\n", .{});
        self.error_flags.no_entry_point_found = true;
    } else {
        log.debug("flushing. no_entry_point_found = false\n", .{});
        self.error_flags.no_entry_point_found = false;
    }

    assert(!self.cmd_table_dirty);

    switch (self.base.options.output_mode) {
        .Exe, .Lib => try self.writeCodeSignature(), // code signing always comes last
        else => {},
    }
}

fn linkWithLLD(self: *MachO, comp: *Compilation) !void {
    const tracy = trace(@src());
    defer tracy.end();

    var arena_allocator = std.heap.ArenaAllocator.init(self.base.allocator);
    defer arena_allocator.deinit();
    const arena = &arena_allocator.allocator;

    const directory = self.base.options.emit.?.directory; // Just an alias to make it shorter to type.

    // If there is no Zig code to compile, then we should skip flushing the output file because it
    // will not be part of the linker line anyway.
    const module_obj_path: ?[]const u8 = if (self.base.options.module) |module| blk: {
        const use_stage1 = build_options.is_stage1 and self.base.options.use_llvm;
        if (use_stage1) {
            const obj_basename = try std.zig.binNameAlloc(arena, .{
                .root_name = self.base.options.root_name,
                .target = self.base.options.target,
                .output_mode = .Obj,
            });
            const o_directory = self.base.options.module.?.zig_cache_artifact_directory;
            const full_obj_path = try o_directory.join(arena, &[_][]const u8{obj_basename});
            break :blk full_obj_path;
        }

        try self.flushModule(comp);
        const obj_basename = self.base.intermediary_basename.?;
        const full_obj_path = try directory.join(arena, &[_][]const u8{obj_basename});
        break :blk full_obj_path;
    } else null;

    const is_lib = self.base.options.output_mode == .Lib;
    const is_dyn_lib = self.base.options.link_mode == .Dynamic and is_lib;
    const is_exe_or_dyn_lib = is_dyn_lib or self.base.options.output_mode == .Exe;
    const target = self.base.options.target;
    const stack_size = self.base.options.stack_size_override orelse 16777216;
    const allow_shlib_undefined = self.base.options.allow_shlib_undefined orelse !self.base.options.is_native_os;

    const id_symlink_basename = "lld.id";

    var man: Cache.Manifest = undefined;
    defer if (!self.base.options.disable_lld_caching) man.deinit();

    var digest: [Cache.hex_digest_len]u8 = undefined;

    if (!self.base.options.disable_lld_caching) {
        man = comp.cache_parent.obtain();

        // We are about to obtain this lock, so here we give other processes a chance first.
        self.base.releaseLock();

        try man.addOptionalFile(self.base.options.linker_script);
        try man.addOptionalFile(self.base.options.version_script);
        try man.addListOfFiles(self.base.options.objects);
        for (comp.c_object_table.items()) |entry| {
            _ = try man.addFile(entry.key.status.success.object_path, null);
        }
        try man.addOptionalFile(module_obj_path);
        // We can skip hashing libc and libc++ components that we are in charge of building from Zig
        // installation sources because they are always a product of the compiler version + target information.
        man.hash.add(stack_size);
        man.hash.add(self.base.options.rdynamic);
        man.hash.addListOfBytes(self.base.options.extra_lld_args);
        man.hash.addListOfBytes(self.base.options.lib_dirs);
        man.hash.addListOfBytes(self.base.options.framework_dirs);
        man.hash.addListOfBytes(self.base.options.frameworks);
        man.hash.addListOfBytes(self.base.options.rpath_list);
        man.hash.add(self.base.options.is_compiler_rt_or_libc);
        man.hash.add(self.base.options.z_nodelete);
        man.hash.add(self.base.options.z_defs);
        if (is_dyn_lib) {
            man.hash.addOptional(self.base.options.version);
        }
        man.hash.addStringSet(self.base.options.system_libs);
        man.hash.add(allow_shlib_undefined);
        man.hash.add(self.base.options.bind_global_refs_locally);
        man.hash.add(self.base.options.system_linker_hack);
        man.hash.addOptionalBytes(self.base.options.syslibroot);

        // We don't actually care whether it's a cache hit or miss; we just need the digest and the lock.
        _ = try man.hit();
        digest = man.final();

        var prev_digest_buf: [digest.len]u8 = undefined;
        const prev_digest: []u8 = Cache.readSmallFile(
            directory.handle,
            id_symlink_basename,
            &prev_digest_buf,
        ) catch |err| blk: {
            log.debug("MachO LLD new_digest={} error: {}", .{ digest, @errorName(err) });
            // Handle this as a cache miss.
            break :blk prev_digest_buf[0..0];
        };
        if (mem.eql(u8, prev_digest, &digest)) {
            log.debug("MachO LLD digest={} match - skipping invocation", .{digest});
            // Hot diggity dog! The output binary is already there.
            self.base.lock = man.toOwnedLock();
            return;
        }
        log.debug("MachO LLD prev_digest={} new_digest={}", .{ prev_digest, digest });

        // We are about to change the output file to be different, so we invalidate the build hash now.
        directory.handle.deleteFile(id_symlink_basename) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }

    const full_out_path = try directory.join(arena, &[_][]const u8{self.base.options.emit.?.sub_path});

    if (self.base.options.output_mode == .Obj) {
        // LLD's MachO driver does not support the equvialent of `-r` so we do a simple file copy
        // here. TODO: think carefully about how we can avoid this redundant operation when doing
        // build-obj. See also the corresponding TODO in linkAsArchive.
        const the_object_path = blk: {
            if (self.base.options.objects.len != 0)
                break :blk self.base.options.objects[0];

            if (comp.c_object_table.count() != 0)
                break :blk comp.c_object_table.items()[0].key.status.success.object_path;

            if (module_obj_path) |p|
                break :blk p;

            // TODO I think this is unreachable. Audit this situation when solving the above TODO
            // regarding eliding redundant object -> object transformations.
            return error.NoObjectsToLink;
        };
        // This can happen when using --enable-cache and using the stage1 backend. In this case
        // we can skip the file copy.
        if (!mem.eql(u8, the_object_path, full_out_path)) {
            try fs.cwd().copyFile(the_object_path, fs.cwd(), full_out_path, .{});
        }
    } else {
        // Create an LLD command line and invoke it.
        var argv = std.ArrayList([]const u8).init(self.base.allocator);
        defer argv.deinit();

        // TODO https://github.com/ziglang/zig/issues/6971
        // Note that there is no need to check if running natively since we do that already
        // when setting `system_linker_hack` in Compilation struct.
        if (self.base.options.system_linker_hack) {
            try argv.append("ld");
        } else {
            // The first argument is ignored as LLD is called as a library, set
            // it anyway to the correct LLD driver name for this target so that
            // it's correctly printed when `verbose_link` is true. This is
            // needed for some tools such as CMake when Zig is used as C
            // compiler.
            try argv.append("ld64");

            try argv.append("-error-limit");
            try argv.append("0");
        }

        try argv.append("-demangle");

        if (self.base.options.rdynamic and !self.base.options.system_linker_hack) {
            try argv.append("--export-dynamic");
        }

        try argv.appendSlice(self.base.options.extra_lld_args);

        if (self.base.options.z_nodelete) {
            try argv.append("-z");
            try argv.append("nodelete");
        }
        if (self.base.options.z_defs) {
            try argv.append("-z");
            try argv.append("defs");
        }

        if (is_dyn_lib) {
            try argv.append("-static");
        } else {
            try argv.append("-dynamic");
        }

        if (is_dyn_lib) {
            try argv.append("-dylib");

            if (self.base.options.version) |ver| {
                const compat_vers = try std.fmt.allocPrint(arena, "{d}.0.0", .{ver.major});
                try argv.append("-compatibility_version");
                try argv.append(compat_vers);

                const cur_vers = try std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ ver.major, ver.minor, ver.patch });
                try argv.append("-current_version");
                try argv.append(cur_vers);
            }

            const dylib_install_name = try std.fmt.allocPrint(arena, "@rpath/{}", .{self.base.options.emit.?.sub_path});
            try argv.append("-install_name");
            try argv.append(dylib_install_name);
        }

        try argv.append("-arch");
        try argv.append(darwinArchString(target.cpu.arch));

        switch (target.os.tag) {
            .macos => {
                try argv.append("-macosx_version_min");
            },
            .ios, .tvos, .watchos => switch (target.cpu.arch) {
                .i386, .x86_64 => {
                    try argv.append("-ios_simulator_version_min");
                },
                else => {
                    try argv.append("-iphoneos_version_min");
                },
            },
            else => unreachable,
        }
        const ver = target.os.version_range.semver.min;
        const version_string = try std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ ver.major, ver.minor, ver.patch });
        try argv.append(version_string);

        try argv.append("-sdk_version");
        try argv.append(version_string);

        if (target_util.requiresPIE(target) and self.base.options.output_mode == .Exe) {
            try argv.append("-pie");
        }

        try argv.append("-o");
        try argv.append(full_out_path);

        // rpaths
        var rpath_table = std.StringHashMap(void).init(self.base.allocator);
        defer rpath_table.deinit();
        for (self.base.options.rpath_list) |rpath| {
            if ((try rpath_table.fetchPut(rpath, {})) == null) {
                try argv.append("-rpath");
                try argv.append(rpath);
            }
        }
        if (is_dyn_lib) {
            if ((try rpath_table.fetchPut(full_out_path, {})) == null) {
                try argv.append("-rpath");
                try argv.append(full_out_path);
            }
        }

        if (self.base.options.syslibroot) |dir| {
            try argv.append("-syslibroot");
            try argv.append(dir);
        }

        for (self.base.options.lib_dirs) |lib_dir| {
            try argv.append("-L");
            try argv.append(lib_dir);
        }

        // Positional arguments to the linker such as object files.
        try argv.appendSlice(self.base.options.objects);

        for (comp.c_object_table.items()) |entry| {
            try argv.append(entry.key.status.success.object_path);
        }
        if (module_obj_path) |p| {
            try argv.append(p);
        }

        // compiler_rt on darwin is missing some stuff, so we still build it and rely on LinkOnce
        if (is_exe_or_dyn_lib and !self.base.options.is_compiler_rt_or_libc) {
            try argv.append(comp.compiler_rt_static_lib.?.full_object_path);
        }

        // Shared libraries.
        const system_libs = self.base.options.system_libs.items();
        try argv.ensureCapacity(argv.items.len + system_libs.len);
        for (system_libs) |entry| {
            const link_lib = entry.key;
            // By this time, we depend on these libs being dynamically linked libraries and not static libraries
            // (the check for that needs to be earlier), but they could be full paths to .dylib files, in which
            // case we want to avoid prepending "-l".
            const ext = Compilation.classifyFileExt(link_lib);
            const arg = if (ext == .shared_library) link_lib else try std.fmt.allocPrint(arena, "-l{}", .{link_lib});
            argv.appendAssumeCapacity(arg);
        }

        // libc++ dep
        if (self.base.options.link_libcpp) {
            try argv.append(comp.libcxxabi_static_lib.?.full_object_path);
            try argv.append(comp.libcxx_static_lib.?.full_object_path);
        }

        // On Darwin, libSystem has libc in it, but also you have to use it
        // to make syscalls because the syscall numbers are not documented
        // and change between versions. So we always link against libSystem.
        // LLD craps out if you do -lSystem cross compiling, so until that
        // codebase gets some love from the new maintainers we're left with
        // this dirty hack.
        if (self.base.options.is_native_os) {
            try argv.append("-lSystem");
        }

        for (self.base.options.framework_dirs) |framework_dir| {
            try argv.append("-F");
            try argv.append(framework_dir);
        }
        for (self.base.options.frameworks) |framework| {
            try argv.append("-framework");
            try argv.append(framework);
        }

        if (allow_shlib_undefined) {
            try argv.append("-undefined");
            try argv.append("dynamic_lookup");
        }
        if (self.base.options.bind_global_refs_locally) {
            try argv.append("-Bsymbolic");
        }

        if (self.base.options.verbose_link) {
            Compilation.dump_argv(argv.items);
        }

        // TODO https://github.com/ziglang/zig/issues/6971
        // Note that there is no need to check if running natively since we do that already
        // when setting `system_linker_hack` in Compilation struct.
        if (self.base.options.system_linker_hack) {
            const result = try std.ChildProcess.exec(.{ .allocator = self.base.allocator, .argv = argv.items });
            defer {
                self.base.allocator.free(result.stdout);
                self.base.allocator.free(result.stderr);
            }
            if (result.stdout.len != 0) {
                std.log.warn("unexpected LD stdout: {}", .{result.stdout});
            }
            if (result.stderr.len != 0) {
                std.log.warn("unexpected LD stderr: {}", .{result.stderr});
            }
            if (result.term != .Exited or result.term.Exited != 0) {
                // TODO parse this output and surface with the Compilation API rather than
                // directly outputting to stderr here.
                std.log.err("{}", .{result.stderr});
                return error.LDReportedFailure;
            }
        } else {
            const new_argv = try arena.allocSentinel(?[*:0]const u8, argv.items.len, null);
            for (argv.items) |arg, i| {
                new_argv[i] = try arena.dupeZ(u8, arg);
            }

            var stderr_context: LLDContext = .{
                .macho = self,
                .data = std.ArrayList(u8).init(self.base.allocator),
            };
            defer stderr_context.data.deinit();
            var stdout_context: LLDContext = .{
                .macho = self,
                .data = std.ArrayList(u8).init(self.base.allocator),
            };
            defer stdout_context.data.deinit();
            const llvm = @import("../llvm.zig");
            const ok = llvm.Link(
                .MachO,
                new_argv.ptr,
                new_argv.len,
                append_diagnostic,
                @ptrToInt(&stdout_context),
                @ptrToInt(&stderr_context),
            );
            if (stderr_context.oom or stdout_context.oom) return error.OutOfMemory;
            if (stdout_context.data.items.len != 0) {
                std.log.warn("unexpected LLD stdout: {}", .{stdout_context.data.items});
            }
            if (!ok) {
                // TODO parse this output and surface with the Compilation API rather than
                // directly outputting to stderr here.
                std.log.err("{}", .{stderr_context.data.items});
                return error.LLDReportedFailure;
            }
            if (stderr_context.data.items.len != 0) {
                std.log.warn("unexpected LLD stderr: {}", .{stderr_context.data.items});
            }

            // At this stage, LLD has done its job. It is time to patch the resultant
            // binaries up!
            const out_file = try directory.handle.openFile(self.base.options.emit.?.sub_path, .{ .write = true });
            try self.parseFromFile(out_file);
            if (self.code_signature_cmd_index == null) {
                const text_segment = self.load_commands.items[self.text_segment_cmd_index.?].Segment;
                const text_section = text_segment.sections.items[self.text_section_index.?];
                const after_last_cmd_offset = self.header.?.sizeofcmds + @sizeOf(macho.mach_header_64);
                const needed_size = @sizeOf(macho.linkedit_data_command);
                if (needed_size + after_last_cmd_offset > text_section.offset) {
                    // TODO We are in the position to be able to increase the padding by moving all sections
                    // by the required offset, but this requires a little bit more thinking and bookkeeping.
                    // For now, return an error informing the user of the problem.
                    std.log.err("Not enough padding between load commands and start of __text section:\n", .{});
                    std.log.err("Offset after last load command: 0x{x}\n", .{after_last_cmd_offset});
                    std.log.err("Beginning of __text section: 0x{x}\n", .{text_section.offset});
                    std.log.err("Needed size: 0x{x}\n", .{needed_size});
                    return error.NotEnoughPadding;
                }
                const linkedit_segment = self.load_commands.items[self.linkedit_segment_cmd_index.?].Segment;
                // TODO This is clunky.
                self.linkedit_segment_next_offset = @intCast(u32, mem.alignForwardGeneric(u64, linkedit_segment.inner.fileoff + linkedit_segment.inner.filesize, @sizeOf(u64)));
                // Add code signature load command
                self.code_signature_cmd_index = @intCast(u16, self.load_commands.items.len);
                try self.load_commands.append(self.base.allocator, .{
                    .LinkeditData = .{
                        .cmd = macho.LC_CODE_SIGNATURE,
                        .cmdsize = @sizeOf(macho.linkedit_data_command),
                        .dataoff = 0,
                        .datasize = 0,
                    },
                });
                // Pad out space for code signature
                try self.writeCodeSignaturePadding();
                // Write updated load commands and the header
                try self.writeLoadCommands();
                try self.writeHeader();
                // Generate adhoc code signature
                try self.writeCodeSignature();
            }
        }
    }

    if (!self.base.options.disable_lld_caching) {
        // Update the file with the digest. If it fails we can continue; it only
        // means that the next invocation will have an unnecessary cache miss.
        Cache.writeSmallFile(directory.handle, id_symlink_basename, &digest) catch |err| {
            std.log.warn("failed to save linking hash digest file: {}", .{@errorName(err)});
        };
        // Again failure here only means an unnecessary cache miss.
        man.writeManifest() catch |err| {
            std.log.warn("failed to write cache manifest when linking: {}", .{@errorName(err)});
        };
        // We hang on to this lock so that the output file path can be used without
        // other processes clobbering it.
        self.base.lock = man.toOwnedLock();
    }
}

const LLDContext = struct {
    data: std.ArrayList(u8),
    macho: *MachO,
    oom: bool = false,
};

fn append_diagnostic(context: usize, ptr: [*]const u8, len: usize) callconv(.C) void {
    const lld_context = @intToPtr(*LLDContext, context);
    const msg = ptr[0..len];
    lld_context.data.appendSlice(msg) catch |err| switch (err) {
        error.OutOfMemory => lld_context.oom = true,
    };
}

fn darwinArchString(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .aarch64, .aarch64_be, .aarch64_32 => "arm64",
        .thumb, .arm => "arm",
        .thumbeb, .armeb => "armeb",
        .powerpc => "ppc",
        .powerpc64 => "ppc64",
        .powerpc64le => "ppc64le",
        else => @tagName(arch),
    };
}

pub fn deinit(self: *MachO) void {
    self.pie_fixups.deinit(self.base.allocator);
    self.text_block_free_list.deinit(self.base.allocator);
    self.offset_table.deinit(self.base.allocator);
    self.offset_table_free_list.deinit(self.base.allocator);
    self.string_table.deinit(self.base.allocator);
    self.undef_symbols.deinit(self.base.allocator);
    self.global_symbols.deinit(self.base.allocator);
    self.global_symbol_free_list.deinit(self.base.allocator);
    self.local_symbols.deinit(self.base.allocator);
    self.local_symbol_free_list.deinit(self.base.allocator);
    for (self.load_commands.items) |*lc| {
        lc.deinit(self.base.allocator);
    }
    self.load_commands.deinit(self.base.allocator);
}

fn freeTextBlock(self: *MachO, text_block: *TextBlock) void {
    var already_have_free_list_node = false;
    {
        var i: usize = 0;
        // TODO turn text_block_free_list into a hash map
        while (i < self.text_block_free_list.items.len) {
            if (self.text_block_free_list.items[i] == text_block) {
                _ = self.text_block_free_list.swapRemove(i);
                continue;
            }
            if (self.text_block_free_list.items[i] == text_block.prev) {
                already_have_free_list_node = true;
            }
            i += 1;
        }
    }
    // TODO process free list for dbg info just like we do above for vaddrs

    if (self.last_text_block == text_block) {
        // TODO shrink the __text section size here
        self.last_text_block = text_block.prev;
    }

    if (text_block.prev) |prev| {
        prev.next = text_block.next;

        if (!already_have_free_list_node and prev.freeListEligible(self.*)) {
            // The free list is heuristics, it doesn't have to be perfect, so we can ignore
            // the OOM here.
            self.text_block_free_list.append(self.base.allocator, prev) catch {};
        }
    } else {
        text_block.prev = null;
    }

    if (text_block.next) |next| {
        next.prev = text_block.prev;
    } else {
        text_block.next = null;
    }
}

fn shrinkTextBlock(self: *MachO, text_block: *TextBlock, new_block_size: u64) void {
    // TODO check the new capacity, and if it crosses the size threshold into a big enough
    // capacity, insert a free list node for it.
}

fn growTextBlock(self: *MachO, text_block: *TextBlock, new_block_size: u64, alignment: u64) !u64 {
    const sym = self.local_symbols.items[text_block.local_sym_index];
    const align_ok = mem.alignBackwardGeneric(u64, sym.n_value, alignment) == sym.n_value;
    const need_realloc = !align_ok or new_block_size > text_block.capacity(self.*);
    if (!need_realloc) return sym.n_value;
    return self.allocateTextBlock(text_block, new_block_size, alignment);
}

pub fn allocateDeclIndexes(self: *MachO, decl: *Module.Decl) !void {
    if (decl.link.macho.local_sym_index != 0) return;

    try self.local_symbols.ensureCapacity(self.base.allocator, self.local_symbols.items.len + 1);
    try self.offset_table.ensureCapacity(self.base.allocator, self.offset_table.items.len + 1);

    if (self.local_symbol_free_list.popOrNull()) |i| {
        log.debug("reusing symbol index {} for {}\n", .{ i, decl.name });
        decl.link.macho.local_sym_index = i;
    } else {
        log.debug("allocating symbol index {} for {}\n", .{ self.local_symbols.items.len, decl.name });
        decl.link.macho.local_sym_index = @intCast(u32, self.local_symbols.items.len);
        _ = self.local_symbols.addOneAssumeCapacity();
    }

    if (self.offset_table_free_list.popOrNull()) |i| {
        decl.link.macho.offset_table_index = i;
    } else {
        decl.link.macho.offset_table_index = @intCast(u32, self.offset_table.items.len);
        _ = self.offset_table.addOneAssumeCapacity();
    }

    self.local_symbols.items[decl.link.macho.local_sym_index] = .{
        .n_strx = 0,
        .n_type = 0,
        .n_sect = 0,
        .n_desc = 0,
        .n_value = 0,
    };
    self.offset_table.items[decl.link.macho.offset_table_index] = 0;
}

pub fn updateDecl(self: *MachO, module: *Module, decl: *Module.Decl) !void {
    const tracy = trace(@src());
    defer tracy.end();

    var code_buffer = std.ArrayList(u8).init(self.base.allocator);
    defer code_buffer.deinit();

    const typed_value = decl.typed_value.most_recent.typed_value;
    const res = try codegen.generateSymbol(&self.base, decl.src(), typed_value, &code_buffer, .none);

    const code = switch (res) {
        .externally_managed => |x| x,
        .appended => code_buffer.items,
        .fail => |em| {
            decl.analysis = .codegen_failure;
            try module.failed_decls.put(module.gpa, decl, em);
            return;
        },
    };

    const required_alignment = typed_value.ty.abiAlignment(self.base.options.target);
    assert(decl.link.macho.local_sym_index != 0); // Caller forgot to call allocateDeclIndexes()
    const symbol = &self.local_symbols.items[decl.link.macho.local_sym_index];

    if (decl.link.macho.size != 0) {
        const capacity = decl.link.macho.capacity(self.*);
        const need_realloc = code.len > capacity or !mem.isAlignedGeneric(u64, symbol.n_value, required_alignment);
        if (need_realloc) {
            const vaddr = try self.growTextBlock(&decl.link.macho, code.len, required_alignment);
            log.debug("growing {} from 0x{x} to 0x{x}\n", .{ decl.name, symbol.n_value, vaddr });
            if (vaddr != symbol.n_value) {
                symbol.n_value = vaddr;
                log.debug(" (writing new offset table entry)\n", .{});
                self.offset_table.items[decl.link.macho.offset_table_index] = vaddr;
                try self.writeOffsetTableEntry(decl.link.macho.offset_table_index);
            }
        } else if (code.len < decl.link.macho.size) {
            self.shrinkTextBlock(&decl.link.macho, code.len);
        }
        decl.link.macho.size = code.len;
        symbol.n_strx = try self.updateString(symbol.n_strx, mem.spanZ(decl.name));
        symbol.n_type = macho.N_SECT;
        symbol.n_sect = @intCast(u8, self.text_section_index.?) + 1;
        symbol.n_desc = 0;
    } else {
        const decl_name = mem.spanZ(decl.name);
        const name_str_index = try self.makeString(decl_name);
        const addr = try self.allocateTextBlock(&decl.link.macho, code.len, required_alignment);
        log.debug("allocated text block for {} at 0x{x}\n", .{ decl_name, addr });
        errdefer self.freeTextBlock(&decl.link.macho);

        symbol.* = .{
            .n_strx = name_str_index,
            .n_type = macho.N_SECT,
            .n_sect = @intCast(u8, self.text_section_index.?) + 1,
            .n_desc = 0,
            .n_value = addr,
        };
        self.offset_table.items[decl.link.macho.offset_table_index] = addr;
        try self.writeOffsetTableEntry(decl.link.macho.offset_table_index);
    }

    // Perform PIE fixups (if any)
    const text_segment = self.load_commands.items[self.text_segment_cmd_index.?].Segment;
    const got_section = text_segment.sections.items[self.got_section_index.?];
    while (self.pie_fixups.popOrNull()) |fixup| {
        const target_addr = fixup.address;
        const this_addr = symbol.n_value + fixup.start;
        switch (self.base.options.target.cpu.arch) {
            .x86_64 => {
                const displacement = @intCast(u32, target_addr - this_addr - fixup.len);
                var placeholder = code_buffer.items[fixup.start + fixup.len - @sizeOf(u32) ..][0..@sizeOf(u32)];
                mem.writeIntSliceLittle(u32, placeholder, displacement);
            },
            .aarch64 => {
                const displacement = @intCast(u27, target_addr - this_addr);
                var placeholder = code_buffer.items[fixup.start..][0..fixup.len];
                mem.writeIntSliceLittle(u32, placeholder, aarch64.Instruction.b(@intCast(i28, displacement)).toU32());
            },
            else => unreachable, // unsupported target architecture
        }
    }

    const text_section = text_segment.sections.items[self.text_section_index.?];
    const section_offset = symbol.n_value - text_section.addr;
    const file_offset = text_section.offset + section_offset;
    try self.base.file.?.pwriteAll(code, file_offset);

    // Since we updated the vaddr and the size, each corresponding export symbol also needs to be updated.
    const decl_exports = module.decl_exports.get(decl) orelse &[0]*Module.Export{};
    try self.updateDeclExports(module, decl, decl_exports);
}

pub fn updateDeclLineNumber(self: *MachO, module: *Module, decl: *const Module.Decl) !void {}

pub fn updateDeclExports(
    self: *MachO,
    module: *Module,
    decl: *const Module.Decl,
    exports: []const *Module.Export,
) !void {
    const tracy = trace(@src());
    defer tracy.end();

    try self.global_symbols.ensureCapacity(self.base.allocator, self.global_symbols.items.len + exports.len);
    if (decl.link.macho.local_sym_index == 0) return;
    const decl_sym = &self.local_symbols.items[decl.link.macho.local_sym_index];

    for (exports) |exp| {
        if (exp.options.section) |section_name| {
            if (!mem.eql(u8, section_name, "__text")) {
                try module.failed_exports.ensureCapacity(module.gpa, module.failed_exports.items().len + 1);
                module.failed_exports.putAssumeCapacityNoClobber(
                    exp,
                    try Compilation.ErrorMsg.create(self.base.allocator, 0, "Unimplemented: ExportOptions.section", .{}),
                );
                continue;
            }
        }
        const n_desc = switch (exp.options.linkage) {
            .Internal => macho.REFERENCE_FLAG_PRIVATE_DEFINED,
            .Strong => blk: {
                if (mem.eql(u8, exp.options.name, "_start")) {
                    self.entry_addr = decl_sym.n_value;
                    self.cmd_table_dirty = true; // TODO This should be handled more granularly instead of invalidating all commands.
                }
                break :blk macho.REFERENCE_FLAG_DEFINED;
            },
            .Weak => macho.N_WEAK_REF,
            .LinkOnce => {
                try module.failed_exports.ensureCapacity(module.gpa, module.failed_exports.items().len + 1);
                module.failed_exports.putAssumeCapacityNoClobber(
                    exp,
                    try Compilation.ErrorMsg.create(self.base.allocator, 0, "Unimplemented: GlobalLinkage.LinkOnce", .{}),
                );
                continue;
            },
        };
        const n_type = decl_sym.n_type | macho.N_EXT;
        if (exp.link.macho.sym_index) |i| {
            const sym = &self.global_symbols.items[i];
            sym.* = .{
                .n_strx = try self.updateString(sym.n_strx, exp.options.name),
                .n_type = n_type,
                .n_sect = @intCast(u8, self.text_section_index.?) + 1,
                .n_desc = n_desc,
                .n_value = decl_sym.n_value,
            };
        } else {
            const name_str_index = try self.makeString(exp.options.name);
            const i = if (self.global_symbol_free_list.popOrNull()) |i| i else blk: {
                _ = self.global_symbols.addOneAssumeCapacity();
                break :blk self.global_symbols.items.len - 1;
            };
            self.global_symbols.items[i] = .{
                .n_strx = name_str_index,
                .n_type = n_type,
                .n_sect = @intCast(u8, self.text_section_index.?) + 1,
                .n_desc = n_desc,
                .n_value = decl_sym.n_value,
            };

            exp.link.macho.sym_index = @intCast(u32, i);
        }
    }
}

pub fn deleteExport(self: *MachO, exp: Export) void {
    const sym_index = exp.sym_index orelse return;
    self.global_symbol_free_list.append(self.base.allocator, sym_index) catch {};
    self.global_symbols.items[sym_index].n_type = 0;
}

pub fn freeDecl(self: *MachO, decl: *Module.Decl) void {
    // Appending to free lists is allowed to fail because the free lists are heuristics based anyway.
    self.freeTextBlock(&decl.link.macho);
    if (decl.link.macho.local_sym_index != 0) {
        self.local_symbol_free_list.append(self.base.allocator, decl.link.macho.local_sym_index) catch {};
        self.offset_table_free_list.append(self.base.allocator, decl.link.macho.offset_table_index) catch {};

        self.local_symbols.items[decl.link.macho.local_sym_index].n_type = 0;

        decl.link.macho.local_sym_index = 0;
    }
}

pub fn getDeclVAddr(self: *MachO, decl: *const Module.Decl) u64 {
    assert(decl.link.macho.local_sym_index != 0);
    return self.local_symbols.items[decl.link.macho.local_sym_index].n_value;
}

pub fn populateMissingMetadata(self: *MachO) !void {
    switch (self.base.options.output_mode) {
        .Exe => {},
        .Obj => return error.TODOImplementWritingObjFiles,
        .Lib => return error.TODOImplementWritingLibFiles,
    }

    if (self.header == null) {
        var header: macho.mach_header_64 = undefined;
        header.magic = macho.MH_MAGIC_64;

        const CpuInfo = struct {
            cpu_type: macho.cpu_type_t,
            cpu_subtype: macho.cpu_subtype_t,
        };

        const cpu_info: CpuInfo = switch (self.base.options.target.cpu.arch) {
            .aarch64 => .{
                .cpu_type = macho.CPU_TYPE_ARM64,
                .cpu_subtype = macho.CPU_SUBTYPE_ARM_ALL,
            },
            .x86_64 => .{
                .cpu_type = macho.CPU_TYPE_X86_64,
                .cpu_subtype = macho.CPU_SUBTYPE_X86_64_ALL,
            },
            else => return error.UnsupportedMachOArchitecture,
        };
        header.cputype = cpu_info.cpu_type;
        header.cpusubtype = cpu_info.cpu_subtype;

        const filetype: u32 = switch (self.base.options.output_mode) {
            .Exe => macho.MH_EXECUTE,
            .Obj => macho.MH_OBJECT,
            .Lib => switch (self.base.options.link_mode) {
                .Static => return error.TODOStaticLibMachOType,
                .Dynamic => macho.MH_DYLIB,
            },
        };
        header.filetype = filetype;
        // These will get populated at the end of flushing the results to file.
        header.ncmds = 0;
        header.sizeofcmds = 0;

        switch (self.base.options.output_mode) {
            .Exe => {
                header.flags = macho.MH_NOUNDEFS | macho.MH_DYLDLINK | macho.MH_PIE;
            },
            else => {
                header.flags = 0;
            },
        }
        header.reserved = 0;
        self.header = header;
    }
    if (self.pagezero_segment_cmd_index == null) {
        self.pagezero_segment_cmd_index = @intCast(u16, self.load_commands.items.len);
        try self.load_commands.append(self.base.allocator, .{
            .Segment = SegmentCommand.empty(.{
                .cmd = macho.LC_SEGMENT_64,
                .cmdsize = @sizeOf(macho.segment_command_64),
                .segname = makeStaticString("__PAGEZERO"),
                .vmaddr = 0,
                .vmsize = 0x100000000, // size always set to 4GB
                .fileoff = 0,
                .filesize = 0,
                .maxprot = 0,
                .initprot = 0,
                .nsects = 0,
                .flags = 0,
            }),
        });
        self.cmd_table_dirty = true;
    }
    if (self.text_segment_cmd_index == null) {
        self.text_segment_cmd_index = @intCast(u16, self.load_commands.items.len);
        const maxprot = macho.VM_PROT_READ | macho.VM_PROT_WRITE | macho.VM_PROT_EXECUTE;
        const initprot = macho.VM_PROT_READ | macho.VM_PROT_EXECUTE;
        try self.load_commands.append(self.base.allocator, .{
            .Segment = SegmentCommand.empty(.{
                .cmd = macho.LC_SEGMENT_64,
                .cmdsize = @sizeOf(macho.segment_command_64),
                .segname = makeStaticString("__TEXT"),
                .vmaddr = 0x100000000, // always starts at 4GB
                .vmsize = 0,
                .fileoff = 0,
                .filesize = 0,
                .maxprot = maxprot,
                .initprot = initprot,
                .nsects = 0,
                .flags = 0,
            }),
        });
        self.cmd_table_dirty = true;
    }
    if (self.text_section_index == null) {
        const text_segment = &self.load_commands.items[self.text_segment_cmd_index.?].Segment;
        self.text_section_index = @intCast(u16, text_segment.sections.items.len);

        const program_code_size_hint = self.base.options.program_code_size_hint;
        const file_size = mem.alignForwardGeneric(u64, program_code_size_hint, self.page_size);
        const off = @intCast(u32, self.findFreeSpace(file_size, self.page_size)); // TODO maybe findFreeSpace should return u32 directly?

        log.debug("found __text section free space 0x{x} to 0x{x}\n", .{ off, off + file_size });

        try text_segment.sections.append(self.base.allocator, .{
            .sectname = makeStaticString("__text"),
            .segname = makeStaticString("__TEXT"),
            .addr = text_segment.inner.vmaddr + off,
            .size = file_size,
            .offset = off,
            .@"align" = if (self.base.options.target.cpu.arch == .aarch64) 2 else 0, // 2^2 for aarch64, 2^0 for x86_64
            .reloff = 0,
            .nreloc = 0,
            .flags = macho.S_REGULAR | macho.S_ATTR_PURE_INSTRUCTIONS | macho.S_ATTR_SOME_INSTRUCTIONS,
            .reserved1 = 0,
            .reserved2 = 0,
            .reserved3 = 0,
        });

        text_segment.inner.vmsize = file_size + off; // We add off here since __TEXT segment includes everything prior to __text section.
        text_segment.inner.filesize = file_size + off;
        text_segment.inner.cmdsize += @sizeOf(macho.section_64);
        text_segment.inner.nsects += 1;
        self.cmd_table_dirty = true;
    }
    if (self.got_section_index == null) {
        const text_segment = &self.load_commands.items[self.text_segment_cmd_index.?].Segment;
        const text_section = &text_segment.sections.items[self.text_section_index.?];
        self.got_section_index = @intCast(u16, text_segment.sections.items.len);

        const file_size = @sizeOf(u64) * self.base.options.symbol_count_hint;
        // TODO looking for free space should be done *within* a segment it belongs to
        const off = @intCast(u32, text_section.offset + text_section.size);

        log.debug("found __got section free space 0x{x} to 0x{x}\n", .{ off, off + file_size });

        try text_segment.sections.append(self.base.allocator, .{
            .sectname = makeStaticString("__got"),
            .segname = makeStaticString("__TEXT"),
            .addr = text_section.addr + text_section.size,
            .size = file_size,
            .offset = off,
            .@"align" = if (self.base.options.target.cpu.arch == .aarch64) 2 else 0,
            .reloff = 0,
            .nreloc = 0,
            .flags = macho.S_REGULAR | macho.S_ATTR_PURE_INSTRUCTIONS | macho.S_ATTR_SOME_INSTRUCTIONS,
            .reserved1 = 0,
            .reserved2 = 0,
            .reserved3 = 0,
        });

        const added_size = mem.alignForwardGeneric(u64, file_size, self.page_size);
        text_segment.inner.vmsize += added_size;
        text_segment.inner.filesize += added_size;
        text_segment.inner.cmdsize += @sizeOf(macho.section_64);
        text_segment.inner.nsects += 1;
        self.cmd_table_dirty = true;
    }
    if (self.linkedit_segment_cmd_index == null) {
        self.linkedit_segment_cmd_index = @intCast(u16, self.load_commands.items.len);
        const text_segment = &self.load_commands.items[self.text_segment_cmd_index.?].Segment;
        const maxprot = macho.VM_PROT_READ | macho.VM_PROT_WRITE | macho.VM_PROT_EXECUTE;
        const initprot = macho.VM_PROT_READ;
        const off = text_segment.inner.fileoff + text_segment.inner.filesize;
        try self.load_commands.append(self.base.allocator, .{
            .Segment = SegmentCommand.empty(.{
                .cmd = macho.LC_SEGMENT_64,
                .cmdsize = @sizeOf(macho.segment_command_64),
                .segname = makeStaticString("__LINKEDIT"),
                .vmaddr = text_segment.inner.vmaddr + text_segment.inner.vmsize,
                .vmsize = 0,
                .fileoff = off,
                .filesize = 0,
                .maxprot = maxprot,
                .initprot = initprot,
                .nsects = 0,
                .flags = 0,
            }),
        });
        self.linkedit_segment_next_offset = @intCast(u32, off);
        self.cmd_table_dirty = true;
    }
    if (self.dyld_info_cmd_index == null) {
        self.dyld_info_cmd_index = @intCast(u16, self.load_commands.items.len);
        try self.load_commands.append(self.base.allocator, .{
            .DyldInfoOnly = .{
                .cmd = macho.LC_DYLD_INFO_ONLY,
                .cmdsize = @sizeOf(macho.dyld_info_command),
                .rebase_off = 0,
                .rebase_size = 0,
                .bind_off = 0,
                .bind_size = 0,
                .weak_bind_off = 0,
                .weak_bind_size = 0,
                .lazy_bind_off = 0,
                .lazy_bind_size = 0,
                .export_off = 0,
                .export_size = 0,
            },
        });
        self.cmd_table_dirty = true;
    }
    if (self.symtab_cmd_index == null) {
        self.symtab_cmd_index = @intCast(u16, self.load_commands.items.len);
        try self.load_commands.append(self.base.allocator, .{
            .Symtab = .{
                .cmd = macho.LC_SYMTAB,
                .cmdsize = @sizeOf(macho.symtab_command),
                .symoff = 0,
                .nsyms = 0,
                .stroff = 0,
                .strsize = 0,
            },
        });
        self.cmd_table_dirty = true;
    }
    if (self.dysymtab_cmd_index == null) {
        self.dysymtab_cmd_index = @intCast(u16, self.load_commands.items.len);
        try self.load_commands.append(self.base.allocator, .{
            .Dysymtab = .{
                .cmd = macho.LC_DYSYMTAB,
                .cmdsize = @sizeOf(macho.dysymtab_command),
                .ilocalsym = 0,
                .nlocalsym = 0,
                .iextdefsym = 0,
                .nextdefsym = 0,
                .iundefsym = 0,
                .nundefsym = 0,
                .tocoff = 0,
                .ntoc = 0,
                .modtaboff = 0,
                .nmodtab = 0,
                .extrefsymoff = 0,
                .nextrefsyms = 0,
                .indirectsymoff = 0,
                .nindirectsyms = 0,
                .extreloff = 0,
                .nextrel = 0,
                .locreloff = 0,
                .nlocrel = 0,
            },
        });
        self.cmd_table_dirty = true;
    }
    if (self.dylinker_cmd_index == null) {
        self.dylinker_cmd_index = @intCast(u16, self.load_commands.items.len);
        const cmdsize = mem.alignForwardGeneric(u64, @sizeOf(macho.dylinker_command) + mem.lenZ(DEFAULT_DYLD_PATH), @sizeOf(u64));
        var dylinker_cmd = emptyGenericCommandWithData(macho.dylinker_command{
            .cmd = macho.LC_LOAD_DYLINKER,
            .cmdsize = @intCast(u32, cmdsize),
            .name = @sizeOf(macho.dylinker_command),
        });
        dylinker_cmd.data = try self.base.allocator.alloc(u8, cmdsize - dylinker_cmd.inner.name);
        mem.set(u8, dylinker_cmd.data, 0);
        mem.copy(u8, dylinker_cmd.data, mem.spanZ(DEFAULT_DYLD_PATH));
        try self.load_commands.append(self.base.allocator, .{ .Dylinker = dylinker_cmd });
        self.cmd_table_dirty = true;
    }
    if (self.libsystem_cmd_index == null) {
        self.libsystem_cmd_index = @intCast(u16, self.load_commands.items.len);
        const cmdsize = mem.alignForwardGeneric(u64, @sizeOf(macho.dylib_command) + mem.lenZ(LIB_SYSTEM_PATH), @sizeOf(u64));
        // TODO Find a way to work out runtime version from the OS version triple stored in std.Target.
        // In the meantime, we're gonna hardcode to the minimum compatibility version of 0.0.0.
        const min_version = 0x0;
        var dylib_cmd = emptyGenericCommandWithData(macho.dylib_command{
            .cmd = macho.LC_LOAD_DYLIB,
            .cmdsize = @intCast(u32, cmdsize),
            .dylib = .{
                .name = @sizeOf(macho.dylib_command),
                .timestamp = 2, // not sure why not simply 0; this is reverse engineered from Mach-O files
                .current_version = min_version,
                .compatibility_version = min_version,
            },
        });
        dylib_cmd.data = try self.base.allocator.alloc(u8, cmdsize - dylib_cmd.inner.dylib.name);
        mem.set(u8, dylib_cmd.data, 0);
        mem.copy(u8, dylib_cmd.data, mem.spanZ(LIB_SYSTEM_PATH));
        try self.load_commands.append(self.base.allocator, .{ .Dylib = dylib_cmd });
        self.cmd_table_dirty = true;
    }
    if (self.main_cmd_index == null) {
        self.main_cmd_index = @intCast(u16, self.load_commands.items.len);
        try self.load_commands.append(self.base.allocator, .{
            .Main = .{
                .cmd = macho.LC_MAIN,
                .cmdsize = @sizeOf(macho.entry_point_command),
                .entryoff = 0x0,
                .stacksize = 0,
            },
        });
        self.cmd_table_dirty = true;
    }
    if (self.version_min_cmd_index == null) {
        self.version_min_cmd_index = @intCast(u16, self.load_commands.items.len);
        const cmd: u32 = switch (self.base.options.target.os.tag) {
            .macos => macho.LC_VERSION_MIN_MACOSX,
            .ios => macho.LC_VERSION_MIN_IPHONEOS,
            .tvos => macho.LC_VERSION_MIN_TVOS,
            .watchos => macho.LC_VERSION_MIN_WATCHOS,
            else => unreachable, // wrong OS
        };
        const ver = self.base.options.target.os.version_range.semver.min;
        const version = ver.major << 16 | ver.minor << 8 | ver.patch;
        try self.load_commands.append(self.base.allocator, .{
            .VersionMin = .{
                .cmd = cmd,
                .cmdsize = @sizeOf(macho.version_min_command),
                .version = version,
                .sdk = version,
            },
        });
    }
    if (self.source_version_cmd_index == null) {
        self.source_version_cmd_index = @intCast(u16, self.load_commands.items.len);
        try self.load_commands.append(self.base.allocator, .{
            .SourceVersion = .{
                .cmd = macho.LC_SOURCE_VERSION,
                .cmdsize = @sizeOf(macho.source_version_command),
                .version = 0x0,
            },
        });
    }
    if (self.code_signature_cmd_index == null) {
        self.code_signature_cmd_index = @intCast(u16, self.load_commands.items.len);
        try self.load_commands.append(self.base.allocator, .{
            .LinkeditData = .{
                .cmd = macho.LC_CODE_SIGNATURE,
                .cmdsize = @sizeOf(macho.linkedit_data_command),
                .dataoff = 0,
                .datasize = 0,
            },
        });
    }
    if (self.dyld_stub_binder_index == null) {
        self.dyld_stub_binder_index = @intCast(u16, self.undef_symbols.items.len);
        const name = try self.makeString("dyld_stub_binder");
        try self.undef_symbols.append(self.base.allocator, .{
            .n_strx = name,
            .n_type = macho.N_UNDF | macho.N_EXT,
            .n_sect = 0,
            .n_desc = macho.REFERENCE_FLAG_UNDEFINED_NON_LAZY | macho.N_SYMBOL_RESOLVER,
            .n_value = 0,
        });
    }
}

fn allocateTextBlock(self: *MachO, text_block: *TextBlock, new_block_size: u64, alignment: u64) !u64 {
    const text_segment = &self.load_commands.items[self.text_segment_cmd_index.?].Segment;
    const text_section = &text_segment.sections.items[self.text_section_index.?];
    const new_block_ideal_capacity = new_block_size * alloc_num / alloc_den;

    // We use these to indicate our intention to update metadata, placing the new block,
    // and possibly removing a free list node.
    // It would be simpler to do it inside the for loop below, but that would cause a
    // problem if an error was returned later in the function. So this action
    // is actually carried out at the end of the function, when errors are no longer possible.
    var block_placement: ?*TextBlock = null;
    var free_list_removal: ?usize = null;

    // First we look for an appropriately sized free list node.
    // The list is unordered. We'll just take the first thing that works.
    const vaddr = blk: {
        var i: usize = 0;
        while (i < self.text_block_free_list.items.len) {
            const big_block = self.text_block_free_list.items[i];
            // We now have a pointer to a live text block that has too much capacity.
            // Is it enough that we could fit this new text block?
            const sym = self.local_symbols.items[big_block.local_sym_index];
            const capacity = big_block.capacity(self.*);
            const ideal_capacity = capacity * alloc_num / alloc_den;
            const ideal_capacity_end_vaddr = sym.n_value + ideal_capacity;
            const capacity_end_vaddr = sym.n_value + capacity;
            const new_start_vaddr_unaligned = capacity_end_vaddr - new_block_ideal_capacity;
            const new_start_vaddr = mem.alignBackwardGeneric(u64, new_start_vaddr_unaligned, alignment);
            if (new_start_vaddr < ideal_capacity_end_vaddr) {
                // Additional bookkeeping here to notice if this free list node
                // should be deleted because the block that it points to has grown to take up
                // more of the extra capacity.
                if (!big_block.freeListEligible(self.*)) {
                    _ = self.text_block_free_list.swapRemove(i);
                } else {
                    i += 1;
                }
                continue;
            }
            // At this point we know that we will place the new block here. But the
            // remaining question is whether there is still yet enough capacity left
            // over for there to still be a free list node.
            const remaining_capacity = new_start_vaddr - ideal_capacity_end_vaddr;
            const keep_free_list_node = remaining_capacity >= min_text_capacity;

            // Set up the metadata to be updated, after errors are no longer possible.
            block_placement = big_block;
            if (!keep_free_list_node) {
                free_list_removal = i;
            }
            break :blk new_start_vaddr;
        } else if (self.last_text_block) |last| {
            const last_symbol = self.local_symbols.items[last.local_sym_index];
            // TODO We should pad out the excess capacity with NOPs. For executables,
            // no padding seems to be OK, but it will probably not be for objects.
            const ideal_capacity = last.size * alloc_num / alloc_den;
            const ideal_capacity_end_vaddr = last_symbol.n_value + ideal_capacity;
            const new_start_vaddr = mem.alignForwardGeneric(u64, ideal_capacity_end_vaddr, alignment);
            block_placement = last;
            break :blk new_start_vaddr;
        } else {
            break :blk text_section.addr;
        }
    };

    const expand_text_section = block_placement == null or block_placement.?.next == null;
    if (expand_text_section) {
        const text_capacity = self.allocatedSize(text_section.offset);
        const needed_size = (vaddr + new_block_size) - text_section.addr;
        assert(needed_size <= text_capacity); // TODO must move the entire text section.

        self.last_text_block = text_block;
        text_section.size = needed_size;

        self.cmd_table_dirty = true; // TODO Make more granular.
    }
    text_block.size = new_block_size;

    if (text_block.prev) |prev| {
        prev.next = text_block.next;
    }
    if (text_block.next) |next| {
        next.prev = text_block.prev;
    }

    if (block_placement) |big_block| {
        text_block.prev = big_block;
        text_block.next = big_block.next;
        big_block.next = text_block;
    } else {
        text_block.prev = null;
        text_block.next = null;
    }
    if (free_list_removal) |i| {
        _ = self.text_block_free_list.swapRemove(i);
    }

    return vaddr;
}

pub fn makeStaticString(comptime bytes: []const u8) [16]u8 {
    var buf = [_]u8{0} ** 16;
    if (bytes.len > buf.len) @compileError("string too long; max 16 bytes");
    mem.copy(u8, buf[0..], bytes);
    return buf;
}

fn makeString(self: *MachO, bytes: []const u8) !u32 {
    try self.string_table.ensureCapacity(self.base.allocator, self.string_table.items.len + bytes.len + 1);
    const result = self.string_table.items.len;
    self.string_table.appendSliceAssumeCapacity(bytes);
    self.string_table.appendAssumeCapacity(0);
    return @intCast(u32, result);
}

fn getString(self: *MachO, str_off: u32) []const u8 {
    assert(str_off < self.string_table.items.len);
    return mem.spanZ(@ptrCast([*:0]const u8, self.string_table.items.ptr + str_off));
}

fn updateString(self: *MachO, old_str_off: u32, new_name: []const u8) !u32 {
    const existing_name = self.getString(old_str_off);
    if (mem.eql(u8, existing_name, new_name)) {
        return old_str_off;
    }
    return self.makeString(new_name);
}

fn detectAllocCollision(self: *MachO, start: u64, size: u64) ?u64 {
    const hdr_size: u64 = @sizeOf(macho.mach_header_64);
    if (start < hdr_size) return hdr_size;
    const end = start + satMul(size, alloc_num) / alloc_den;
    {
        const off = @sizeOf(macho.mach_header_64);
        var tight_size: u64 = 0;
        for (self.load_commands.items) |cmd| {
            tight_size += cmd.cmdsize();
        }
        const increased_size = satMul(tight_size, alloc_num) / alloc_den;
        const test_end = off + increased_size;
        if (end > off and start < test_end) {
            return test_end;
        }
    }
    if (self.text_segment_cmd_index) |text_index| {
        const text_segment = self.load_commands.items[text_index].Segment;
        for (text_segment.sections.items) |section| {
            const increased_size = satMul(section.size, alloc_num) / alloc_den;
            const test_end = section.offset + increased_size;
            if (end > section.offset and start < test_end) {
                return test_end;
            }
        }
    }
    if (self.dyld_info_cmd_index) |dyld_info_index| {
        const dyld_info = self.load_commands.items[dyld_info_index].DyldInfoOnly;
        const tight_size = dyld_info.export_size;
        const increased_size = satMul(tight_size, alloc_num) / alloc_den;
        const test_end = dyld_info.export_off + increased_size;
        if (end > dyld_info.export_off and start < test_end) {
            return test_end;
        }
    }
    if (self.symtab_cmd_index) |symtab_index| {
        const symtab = self.load_commands.items[symtab_index].Symtab;
        {
            const tight_size = @sizeOf(macho.nlist_64) * symtab.nsyms;
            const increased_size = satMul(tight_size, alloc_num) / alloc_den;
            const test_end = symtab.symoff + increased_size;
            if (end > symtab.symoff and start < test_end) {
                return test_end;
            }
        }
        {
            const increased_size = satMul(symtab.strsize, alloc_num) / alloc_den;
            const test_end = symtab.stroff + increased_size;
            if (end > symtab.stroff and start < test_end) {
                return test_end;
            }
        }
    }
    return null;
}

fn allocatedSize(self: *MachO, start: u64) u64 {
    if (start == 0)
        return 0;
    var min_pos: u64 = std.math.maxInt(u64);
    {
        const off = @sizeOf(macho.mach_header_64);
        if (off > start and off < min_pos) min_pos = off;
    }
    if (self.text_segment_cmd_index) |text_index| {
        const text_segment = self.load_commands.items[text_index].Segment;
        for (text_segment.sections.items) |section| {
            if (section.offset <= start) continue;
            if (section.offset < min_pos) min_pos = section.offset;
        }
    }
    if (self.dyld_info_cmd_index) |dyld_info_index| {
        const dyld_info = self.load_commands.items[dyld_info_index].DyldInfoOnly;
        if (dyld_info.export_off > start and dyld_info.export_off < min_pos) min_pos = dyld_info.export_off;
    }
    if (self.symtab_cmd_index) |symtab_index| {
        const symtab = self.load_commands.items[symtab_index].Symtab;
        if (symtab.symoff > start and symtab.symoff < min_pos) min_pos = symtab.symoff;
        if (symtab.stroff > start and symtab.stroff < min_pos) min_pos = symtab.stroff;
    }
    return min_pos - start;
}

fn findFreeSpace(self: *MachO, object_size: u64, min_alignment: u16) u64 {
    var start: u64 = 0;
    while (self.detectAllocCollision(start, object_size)) |item_end| {
        start = mem.alignForwardGeneric(u64, item_end, min_alignment);
    }
    return start;
}

fn writeOffsetTableEntry(self: *MachO, index: usize) !void {
    const text_semgent = &self.load_commands.items[self.text_segment_cmd_index.?].Segment;
    const sect = &text_semgent.sections.items[self.got_section_index.?];
    const off = sect.offset + @sizeOf(u64) * index;
    const vmaddr = sect.addr + @sizeOf(u64) * index;

    var code: [8]u8 = undefined;
    switch (self.base.options.target.cpu.arch) {
        .x86_64 => {
            const pos_symbol_off = @intCast(u31, vmaddr - self.offset_table.items[index] + 7);
            const symbol_off = @bitCast(u32, @intCast(i32, pos_symbol_off) * -1);
            // lea %rax, [rip - disp]
            code[0] = 0x48;
            code[1] = 0x8D;
            code[2] = 0x5;
            mem.writeIntLittle(u32, code[3..7], symbol_off);
            // ret
            code[7] = 0xC3;
        },
        .aarch64 => {
            const pos_symbol_off = @intCast(u20, vmaddr - self.offset_table.items[index]);
            const symbol_off = @intCast(i21, pos_symbol_off) * -1;
            // adr x0, #-disp
            mem.writeIntLittle(u32, code[0..4], aarch64.Instruction.adr(.x0, symbol_off).toU32());
            // ret x28
            mem.writeIntLittle(u32, code[4..8], aarch64.Instruction.ret(.x28).toU32());
        },
        else => unreachable, // unsupported target architecture
    }
    log.debug("writing offset table entry 0x{x} at 0x{x}\n", .{ self.offset_table.items[index], off });
    try self.base.file.?.pwriteAll(&code, off);
}

fn writeSymbolTable(self: *MachO) !void {
    // TODO workout how we can cache these so that we only overwrite symbols that were updated
    const symtab = &self.load_commands.items[self.symtab_cmd_index.?].Symtab;

    const locals_off = self.linkedit_segment_next_offset.?;
    const locals_size = self.local_symbols.items.len * @sizeOf(macho.nlist_64);
    log.debug("writing local symbols from 0x{x} to 0x{x}\n", .{ locals_off, locals_size + locals_off });
    try self.base.file.?.pwriteAll(mem.sliceAsBytes(self.local_symbols.items), locals_off);

    const globals_off = locals_off + locals_size;
    const globals_size = self.global_symbols.items.len * @sizeOf(macho.nlist_64);
    log.debug("writing global symbols from 0x{x} to 0x{x}\n", .{ globals_off, globals_size + globals_off });
    try self.base.file.?.pwriteAll(mem.sliceAsBytes(self.global_symbols.items), globals_off);

    const undefs_off = globals_off + globals_size;
    const undefs_size = self.undef_symbols.items.len * @sizeOf(macho.nlist_64);
    log.debug("writing undef symbols from 0x{x} to 0x{x}\n", .{ undefs_off, undefs_size + undefs_off });
    try self.base.file.?.pwriteAll(mem.sliceAsBytes(self.undef_symbols.items), undefs_off);

    // Update symbol table.
    const nlocals = @intCast(u32, self.local_symbols.items.len);
    const nglobals = @intCast(u32, self.global_symbols.items.len);
    const nundefs = @intCast(u32, self.undef_symbols.items.len);
    symtab.symoff = self.linkedit_segment_next_offset.?;
    symtab.nsyms = nlocals + nglobals + nundefs;
    self.linkedit_segment_next_offset = symtab.symoff + symtab.nsyms * @sizeOf(macho.nlist_64);

    // Update dynamic symbol table.
    const dysymtab = &self.load_commands.items[self.dysymtab_cmd_index.?].Dysymtab;
    dysymtab.nlocalsym = nlocals;
    dysymtab.iextdefsym = nlocals;
    dysymtab.nextdefsym = nglobals;
    dysymtab.iundefsym = nlocals + nglobals;
    dysymtab.nundefsym = nundefs;

    // Advance size of __LINKEDIT segment
    const linkedit = &self.load_commands.items[self.linkedit_segment_cmd_index.?].Segment;
    linkedit.inner.filesize += symtab.nsyms * @sizeOf(macho.nlist_64);
    if (linkedit.inner.vmsize < linkedit.inner.filesize) {
        linkedit.inner.vmsize = mem.alignForwardGeneric(u64, linkedit.inner.filesize, self.page_size);
    }
    self.cmd_table_dirty = true;
}

fn writeCodeSignaturePadding(self: *MachO) !void {
    const code_sig_cmd = &self.load_commands.items[self.code_signature_cmd_index.?].LinkeditData;
    const fileoff = self.linkedit_segment_next_offset.?;
    const datasize = CodeSignature.calcCodeSignaturePadding(self.base.options.emit.?.sub_path, fileoff);
    code_sig_cmd.dataoff = fileoff;
    code_sig_cmd.datasize = datasize;

    self.linkedit_segment_next_offset = fileoff + datasize;
    // Advance size of __LINKEDIT segment
    const linkedit = &self.load_commands.items[self.linkedit_segment_cmd_index.?].Segment;
    linkedit.inner.filesize += datasize;
    if (linkedit.inner.vmsize < linkedit.inner.filesize) {
        linkedit.inner.vmsize = mem.alignForwardGeneric(u64, linkedit.inner.filesize, self.page_size);
    }
    log.debug("writing code signature padding from 0x{x} to 0x{x}\n", .{ fileoff, fileoff + datasize });
    // Pad out the space. We need to do this to calculate valid hashes for everything in the file
    // except for code signature data.
    try self.base.file.?.pwriteAll(&[_]u8{0}, fileoff + datasize - 1);
}

fn writeCodeSignature(self: *MachO) !void {
    const text_segment = self.load_commands.items[self.text_segment_cmd_index.?].Segment;
    const code_sig_cmd = self.load_commands.items[self.code_signature_cmd_index.?].LinkeditData;

    var code_sig = CodeSignature.init(self.base.allocator);
    defer code_sig.deinit();
    try code_sig.calcAdhocSignature(
        self.base.file.?,
        self.base.options.emit.?.sub_path,
        text_segment.inner,
        code_sig_cmd,
        self.base.options.output_mode,
    );

    var buffer = try self.base.allocator.alloc(u8, code_sig.size());
    defer self.base.allocator.free(buffer);
    code_sig.write(buffer);

    log.debug("writing code signature from 0x{x} to 0x{x}\n", .{ code_sig_cmd.dataoff, code_sig_cmd.dataoff + buffer.len });

    try self.base.file.?.pwriteAll(buffer, code_sig_cmd.dataoff);
}

fn writeExportTrie(self: *MachO) !void {
    if (self.global_symbols.items.len == 0) return;

    var trie: Trie = .{};
    defer trie.deinit(self.base.allocator);

    const text_segment = self.load_commands.items[self.text_segment_cmd_index.?].Segment;
    for (self.global_symbols.items) |symbol| {
        // TODO figure out if we should put all global symbols into the export trie
        const name = self.getString(symbol.n_strx);
        assert(symbol.n_value >= text_segment.inner.vmaddr);
        try trie.put(self.base.allocator, .{
            .name = name,
            .vmaddr_offset = symbol.n_value - text_segment.inner.vmaddr,
            .export_flags = 0, // TODO workout creation of export flags
        });
    }

    var buffer: std.ArrayListUnmanaged(u8) = .{};
    defer buffer.deinit(self.base.allocator);

    try trie.writeULEB128Mem(self.base.allocator, &buffer);

    const dyld_info = &self.load_commands.items[self.dyld_info_cmd_index.?].DyldInfoOnly;
    const export_size = @intCast(u32, mem.alignForward(buffer.items.len, @sizeOf(u64)));
    dyld_info.export_off = self.linkedit_segment_next_offset.?;
    dyld_info.export_size = export_size;

    log.debug("writing export trie from 0x{x} to 0x{x}\n", .{ dyld_info.export_off, dyld_info.export_off + export_size });

    if (export_size > buffer.items.len) {
        // Pad out to align(8).
        try self.base.file.?.pwriteAll(&[_]u8{0}, dyld_info.export_off + export_size);
    }
    try self.base.file.?.pwriteAll(buffer.items, dyld_info.export_off);

    self.linkedit_segment_next_offset = dyld_info.export_off + dyld_info.export_size;
    // Advance size of __LINKEDIT segment
    const linkedit = &self.load_commands.items[self.linkedit_segment_cmd_index.?].Segment;
    linkedit.inner.filesize += dyld_info.export_size;
    if (linkedit.inner.vmsize < linkedit.inner.filesize) {
        linkedit.inner.vmsize = mem.alignForwardGeneric(u64, linkedit.inner.filesize, self.page_size);
    }
    self.cmd_table_dirty = true;
}

fn writeStringTable(self: *MachO) !void {
    const symtab = &self.load_commands.items[self.symtab_cmd_index.?].Symtab;
    const needed_size = self.string_table.items.len;

    symtab.stroff = self.linkedit_segment_next_offset.?;
    symtab.strsize = @intCast(u32, mem.alignForward(needed_size, @sizeOf(u64)));

    log.debug("writing string table from 0x{x} to 0x{x}\n", .{ symtab.stroff, symtab.stroff + symtab.strsize });

    if (symtab.strsize > needed_size) {
        // Pad out to align(8);
        try self.base.file.?.pwriteAll(&[_]u8{0}, symtab.stroff + symtab.strsize);
    }
    try self.base.file.?.pwriteAll(self.string_table.items, symtab.stroff);

    self.linkedit_segment_next_offset = symtab.stroff + symtab.strsize;
    // Advance size of __LINKEDIT segment
    const linkedit = &self.load_commands.items[self.linkedit_segment_cmd_index.?].Segment;
    linkedit.inner.filesize += symtab.strsize;
    if (linkedit.inner.vmsize < linkedit.inner.filesize) {
        linkedit.inner.vmsize = mem.alignForwardGeneric(u64, linkedit.inner.filesize, self.page_size);
    }
    self.cmd_table_dirty = true;
}

/// Writes all load commands and section headers.
fn writeLoadCommands(self: *MachO) !void {
    var sizeofcmds: usize = 0;
    for (self.load_commands.items) |lc| {
        sizeofcmds += lc.cmdsize();
    }

    var buffer = try self.base.allocator.alloc(u8, sizeofcmds);
    defer self.base.allocator.free(buffer);
    var writer = std.io.fixedBufferStream(buffer).writer();
    for (self.load_commands.items) |lc| {
        try lc.write(writer);
    }

    try self.base.file.?.pwriteAll(buffer, @sizeOf(macho.mach_header_64));
}

/// Writes Mach-O file header.
fn writeHeader(self: *MachO) !void {
    self.header.?.ncmds = @intCast(u32, self.load_commands.items.len);
    var sizeofcmds: u32 = 0;
    for (self.load_commands.items) |cmd| {
        sizeofcmds += cmd.cmdsize();
    }
    self.header.?.sizeofcmds = sizeofcmds;
    log.debug("writing Mach-O header {}\n", .{self.header.?});
    const slice = [1]macho.mach_header_64{self.header.?};
    try self.base.file.?.pwriteAll(mem.sliceAsBytes(slice[0..1]), 0);
}

/// Saturating multiplication
fn satMul(a: anytype, b: anytype) @TypeOf(a, b) {
    const T = @TypeOf(a, b);
    return std.math.mul(T, a, b) catch std.math.maxInt(T);
}

/// Parse MachO contents from existing binary file.
/// TODO This method is incomplete and currently parses only the header
/// plus the load commands.
fn parseFromFile(self: *MachO, file: fs.File) !void {
    self.base.file = file;
    var reader = file.reader();
    const header = try reader.readStruct(macho.mach_header_64);
    try self.load_commands.ensureCapacity(self.base.allocator, header.ncmds);
    var i: u16 = 0;
    while (i < header.ncmds) : (i += 1) {
        const cmd = try LoadCommand.read(self.base.allocator, reader);
        switch (cmd.cmd()) {
            macho.LC_SEGMENT_64 => {
                const x = cmd.Segment;
                if (isSegmentOrSection(&x.inner.segname, "__LINKEDIT")) {
                    self.linkedit_segment_cmd_index = i;
                } else if (isSegmentOrSection(&x.inner.segname, "__TEXT")) {
                    self.text_segment_cmd_index = i;
                    for (x.sections.items) |sect, j| {
                        if (isSegmentOrSection(&sect.sectname, "__text")) {
                            self.text_section_index = @intCast(u16, j);
                        }
                    }
                }
            },
            macho.LC_SYMTAB => {
                self.symtab_cmd_index = i;
            },
            macho.LC_CODE_SIGNATURE => {
                self.code_signature_cmd_index = i;
            },
            // TODO populate more MachO fields
            else => {},
        }
        self.load_commands.appendAssumeCapacity(cmd);
    }
    self.header = header;

    // TODO parse memory mapped segments
}

fn isSegmentOrSection(name: *const [16]u8, needle: []const u8) bool {
    return mem.eql(u8, mem.trimRight(u8, name.*[0..], &[_]u8{0}), needle);
}