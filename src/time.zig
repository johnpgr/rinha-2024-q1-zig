const std = @import("std");

pub const Time = struct {
    const Self = @This();
    var allocator: std.mem.Allocator = undefined;

    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,

    pub fn init_alloc(a: std.mem.Allocator) void {
        allocator = a;
    }

    pub fn now() *Self {
        return Self.from_timestamp(std.time.timestamp());
    }

    /// from_timestamp assumes that the input timestamp is in UTC
    /// please don't pass time zoned timestamps to it
    pub fn from_timestamp(ts: i64) *Self {
        var time = allocator.create(Self) catch unreachable; //BUY MORE RAM LOL
        errdefer allocator.destroy(time);

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

        time.* = .{ .year = year, .month = month, .day = day, .hour = @intCast(seconds_since_midnight / 3600), .minute = @intCast(seconds_since_midnight % 3600 / 60), .second = @intCast(seconds_since_midnight % 60) };

        return time;
    }

    pub fn to_timestamp(self: *Self) i64 {
        const SECONDS_PER_MINUTE = 60;
        const MINUTES_PER_HOUR = 60;
        const HOURS_PER_DAY = 24;

        const days_in_months = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

        var is_leap_year = (self.year % 4 == 0 and self.year % 100 != 0) or (self.year % 400 == 0);
        if (self.month > 2) {
            is_leap_year = false;
        }

        var days: u16 = self.day - 1;
        for (0..self.month - 1) |i| {
            days += days_in_months[i];
        }
        days += (self.year - 1970) * 365 + (self.year - 1969) / 4 - (self.year - 1901) / 100 + (self.year - 1601) / 400;

        return @intCast(((((days * HOURS_PER_DAY + self.hour) * MINUTES_PER_HOUR + self.minute) * SECONDS_PER_MINUTE) + self.second));
    }

    pub fn format_rfc3339(self: *Self) [20]u8 {
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
