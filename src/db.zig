const std = @import("std");
const pg = @import("pg");
const exit = std.os.exit;

pub var pool: ?*pg.Pool = null;

pub fn wait_conn(conn: *pg.Conn) void {
    while (true) {
        conn.readyForQuery() catch {
            continue;
        };
        break;
    }
}

pub fn deinit() void {
    if (pool != null) {
        pool.?.deinit();
    }
}

pub const Config = struct {
    host: []const u8,
    port: u16,
    pool_size: u16,
    db_user: []const u8,
    db_pass: []const u8,
    db_name: []const u8,
};

pub fn init(allocator: std.mem.Allocator, config: Config) !void {
    pool.? = try pg.Pool.init(allocator, .{
        .size = config.pool_size,
        .connect = .{
            .host = config.host,
            .port = config.port,
        },
        .auth = .{
            .username = config.db_user,
            .password = config.db_pass,
            .database = config.db_name,
            .timeout = 10_000,
        },
    });
}
