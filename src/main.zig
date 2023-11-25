const std = @import("std");
const fs = std.fs;
const os = std.os;
const expect = std.testing.expect;
const mem = std.mem;

/// Basic entry to hold the file name and the depth inside
/// the filesystem exploration.
const TreeEntry = struct {
    depth: u8,
    basename: []const u8, // final name of the file
    path: []const u8, // relative path + basename of the file

    /// Prints a suitable amount of tabs based on the depth of this entry.
    fn indent(self: *const TreeEntry, writer: *const fs.File.Writer) !void {
        var loop: u8 = 0;
        while (loop < self.depth) : (loop += 1) {
            try writer.print("\t", .{});
        }
    }
};

pub fn main() anyerror!void {
    if (os.argv.len < 2) {
        std.log.warn("Not enough argument to pass", .{});
        os.exit(1);
    }

    const stdout = std.io.getStdOut().writer();
    const dir: []const u8 = mem.span(os.argv[1]);

    // Use an arena allocator since we are running a command line tools that
    // does not last long
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Stack for the folders
    var stack = std.ArrayList(TreeEntry).init(
        allocator,
    );
    defer stack.deinit();

    // Start the process from the input dir.
    try stack.append(TreeEntry{
        .depth = 0,
        .basename = dir,
        .path = dir,
    });

    var total_files: u32 = 0;
    var total_dirs: u32 = 1; // the input directory.

    // Recursively iterate over all the directories.
    while (stack.popOrNull()) |d| {
        try d.indent(&stdout);
        try stdout.print("{s}\n", .{d.basename});

        var fd = try fs.cwd().openIterableDir(d.path, .{});
        defer fd.close();
        var iter = fd.iterate();

        while (try iter.next()) |entry| {
            switch (entry.kind) {
                // When file, directly print it.
                .file => {
                    try d.indent(&stdout);
                    try stdout.print("∟ {s}\n", .{entry.name});
                    total_files += 1;
                },
                // When dir, append to the stack to iterate next.
                .directory => {
                    if (d.path[d.path.len - 1] == '/') {
                        try stack.append(TreeEntry{
                            .depth = d.depth + 1,
                            .basename = try allocator.dupe(u8, entry.name),
                            .path = try concat(allocator, d.path, entry.name),
                        });
                    } else {
                        const norm_dir = try concat(allocator, d.path, "/");
                        try stack.append(TreeEntry{
                            .depth = d.depth + 1,
                            .basename = try allocator.dupe(u8, entry.name),
                            .path = try concat(allocator, norm_dir, entry.name)
                        });
                    }
                    total_dirs += 1;
                    allocator.free(entry.name);
                },
                else => {},
            }
        }
    }
    try stdout.print("{d} files, {d} directories\n", .{ total_files, total_dirs });
}

// @FIXME: support multiple strings.
/// Concat two strings in a new allocated string.
fn concat(allocator: mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    // Allocate spaces for both input string.
    const result = try allocator.alloc(u8, a.len + b.len);
    // Copy the input strings in their slots.
    @memcpy(result[0..a.len], a);
    @memcpy(result[a.len..], b);
    return result;
}

test "concat" {
    const allocator = std.testing.allocator;

    var got = try concat(allocator, "test", "xyz");
    try expect(mem.eql(u8, got, "testxyz"));
    allocator.free(got);

    got = try concat(allocator, "", "xyz");
    try expect(mem.eql(u8, got, "xyz"));
    allocator.free(got);

    const dir = "path/to/dir";
    got = try concat(allocator, dir, "/");
    try expect(mem.eql(u8, got, "path/to/dir/"));
    allocator.free(got);
}

test "Read a directory" {
    try fs.cwd().makeDir("test-directory");
    defer {
        fs.cwd().deleteTree("test-directory") catch unreachable;
    }

    const dir = try fs.cwd().openIterableDir(
        "test-directory",
        .{ .access_sub_paths = true },
    );

    const files: [3][]const u8 = [_][]const u8{ "X", "Y", "Z" };
    const dirs: [2][]const u8 = [_][]const u8{ "D1", "D2" };
    for (files) |file| {
        _ = try dir.dir.createFile(file, .{});
    }

    for (dirs) |d| {
        _ = try dir.dir.makeDir(d);
    }

    var file_count: usize = 0;
    var dir_count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .file => file_count += 1,
            .directory => dir_count += 1,
            else => {},
        }
    }

    try expect(file_count == 3);
    try expect(dir_count == 2);
}

test "Stack" {
    const test_allocator = std.testing.allocator;
    var stack = std.ArrayList([]const u8).init(test_allocator);
    defer stack.deinit();

    const files: [3][]const u8 = [_][]const u8{ "X", "Y", "Z" };

    for (files) |file| {
        try stack.append(file);
    }

    try expect(stack.items.len == 3);

    var entry = stack.popOrNull();
    try expect(mem.eql(u8, entry.?, "Z"));
    entry = stack.popOrNull();
    try expect(mem.eql(u8, entry.?, "Y"));
    entry = stack.popOrNull();
    try expect(mem.eql(u8, entry.?, "X"));

    entry = stack.popOrNull();
    try expect(entry == null);
}
