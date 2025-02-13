const std = @import("std");

//

pub const Counter = struct {
    count: usize = 0,
    next_time_us: ?i64 = null,

    const Self = @This();

    /// returns the "per second" approximate every 5 seconds
    pub fn next(self: *Self, _now_us: ?i64) ?u32 {
        const now_us = _now_us orelse std.time.microTimestamp();

        self.count += 1;
        if (now_us >= self.next_time_us orelse 0) {
            return self.coldNext(now_us);
        }

        return null;
    }

    fn coldNext(self: *Self, now_us: i64) u32 {
        @setCold(true);

        const us_since_last = now_us - (self.next_time_us orelse now_us) + 5_000_000;
        // const seconds: f64 = @floatFromInt(us_since_last);
        // const count: f64 = @floatFromInt(self.count);
        // const per_second = count / seconds;

        const per_second: u32 = @truncate(@divTrunc(self.count * 1_000_000, @abs(us_since_last)));

        self.next_time_us = (self.next_time_us orelse now_us) + 5_000_000;
        self.count = 0;

        return per_second;
    }
};
