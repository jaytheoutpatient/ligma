//! Natural, case-insensitive filename ordering.
//!
//! Plain byte ordering puts "Track 10" before "Track 2" and is painful for
//! music, numbered photos, and drive labels. This comparator walks matching
//! digit runs numerically while keeping the rest of the text case-insensitive.

const std = @import("std");

pub fn lessThanIgnoreCase(a: []const u8, b: []const u8) bool {
    return orderIgnoreCase(a, b) == .lt;
}

pub fn orderIgnoreCase(a: []const u8, b: []const u8) std.math.Order {
    var ai: usize = 0;
    var bi: usize = 0;

    while (ai < a.len and bi < b.len) {
        const ac = a[ai];
        const bc = b[bi];

        if (isDigit(ac) and isDigit(bc)) {
            var a_end = ai;
            while (a_end < a.len and isDigit(a[a_end])) a_end += 1;
            var b_end = bi;
            while (b_end < b.len and isDigit(b[b_end])) b_end += 1;

            var a_start = ai;
            while (a_start < a_end and a[a_start] == '0') a_start += 1;
            var b_start = bi;
            while (b_start < b_end and b[b_start] == '0') b_start += 1;

            const a_digits = a_end - a_start;
            const b_digits = b_end - b_start;
            if (a_digits != b_digits) return if (a_digits < b_digits) .lt else .gt;

            const digits = std.mem.order(u8, a[a_start..a_end], b[b_start..b_end]);
            if (digits != .eq) return digits;

            const a_zeros = a_start - ai;
            const b_zeros = b_start - bi;
            if (a_zeros != b_zeros) return if (a_zeros < b_zeros) .lt else .gt;

            ai = a_end;
            bi = b_end;
            continue;
        }

        const a_lower = std.ascii.toLower(ac);
        const b_lower = std.ascii.toLower(bc);
        if (a_lower != b_lower) return if (a_lower < b_lower) .lt else .gt;
        ai += 1;
        bi += 1;
    }

    if (ai < a.len) return .gt;
    if (bi < b.len) return .lt;

    // Equal ignoring case: keep the order deterministic.
    return std.mem.order(u8, a, b);
}

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

test "natural filename order handles track numbers" {
    try std.testing.expect(lessThanIgnoreCase("Track 2.mp3", "Track 10.mp3"));
    try std.testing.expect(lessThanIgnoreCase("track 02.mp3", "track 10.mp3"));
    try std.testing.expect(lessThanIgnoreCase("file 1", "file 01"));
    try std.testing.expect(lessThanIgnoreCase("file 01", "file 1") == false);
    try std.testing.expect(lessThanIgnoreCase("file 1", "file 2"));
    try std.testing.expect(lessThanIgnoreCase("album 9", "album 10"));
}

test "natural order is case-insensitive with a stable tie-break" {
    try std.testing.expect(lessThanIgnoreCase("alpha", "BETA"));
    try std.testing.expect(lessThanIgnoreCase("BETA", "gamma"));
    try std.testing.expect(lessThanIgnoreCase("Same", "same"));
    try std.testing.expect(lessThanIgnoreCase("same", "Same") == false);
}
