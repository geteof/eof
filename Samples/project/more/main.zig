const std = @import("std");
const MAX_ITEMS = 3;

/// Prints a greeting.
pub fn main() !void {
    var i: usize = 0;
    while (i < MAX_ITEMS) : (i += 1) {
        std.debug.print("hello {d}\n", .{i});
    }
}
