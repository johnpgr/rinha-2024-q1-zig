const std = @import("std");

pub const Time = struct {
    const Self = @This();

    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,

    pub fn now() Self {
        return Self.from_timestamp(std.time.timestamp());
    }

    /// from_timestamp assumes that the input timestamp is in UTC
    /// please don't pass time zoned timestamps to it
    pub fn from_timestamp(ts: i64) Self {
        var ts_u64: u64 = @intCast(ts);

        const SECONDS_PER_DAY = 86400;
        const DAYS_PER_YEAR = 365;
        const DAYS_IN_4YEARS = 1461;
        const DAYS_IN_100YEARS = 36524;
        const DAYS_IN_400YEARS = 146097;
        const DAYS_BEFORE_EPOCH = 719468;

        const seconds_since_midnight: u64 = @rem(ts_u64, SECONDS_PER_DAY);
        var day_n: u64 = DAYS_BEFORE_EPOCH + ts_u64 / SECONDS_PER_DAY;
        var temp: u64 = 0;

        temp = 4 * (day_n + DAYS_IN_100YEARS + 1) / DAYS_IN_400YEARS - 1;
        var year: u16 = @intCast(100 * temp);
        day_n -= DAYS_IN_100YEARS * temp + temp / 4;

        temp = 4 * (day_n + DAYS_PER_YEAR + 1) / DAYS_IN_4YEARS - 1;
        year += @intCast(temp);
        day_n -= DAYS_PER_YEAR * temp + temp / 4;

        var month: u8 = @intCast((5 * day_n + 2) / 153);
        const day: u8 = @intCast(day_n - (@as(u64, @intCast(month)) * 153 + 2) / 5 + 1);

        month += 3;
        if (month > 12) {
            month -= 12;
            year += 1;
        }

        return Self{ .year = year, .month = month, .day = day, .hour = @intCast(seconds_since_midnight / 3600), .minute = @intCast(seconds_since_midnight % 3600 / 60), .second = @intCast(seconds_since_midnight % 60) };
    }

    pub fn format_rfc3339(self: Self) [20]u8 {
        var buf: [20]u8 = undefined;
        _ = std.fmt.formatIntBuf(buf[0..4], self.year, 10, .lower, .{ .width = 4, .fill = '0' });
        buf[4] = '-';
        padding_two_digits(buf[5..7], self.month);
        buf[7] = '-';
        padding_two_digits(buf[8..10], self.day);
        buf[10] = 'T';

        padding_two_digits(buf[11..13], self.hour);
        buf[13] = ':';
        padding_two_digits(buf[14..16], self.minute);
        buf[16] = ':';
        padding_two_digits(buf[17..19], self.second);
        buf[19] = 'Z';

        return buf;
    }

    fn padding_two_digits(buf: *[2]u8, value: u8) void {
        if (value < 10) {
            _ = std.fmt.bufPrint(buf, "0{}", .{value}) catch return;
        } else {
            _ = std.fmt.bufPrint(buf, "{}", .{value}) catch return;
        }
    }
};
