const std = @import("std");
const zap = @import("zap");
const port = 8080;

fn on_request(r: zap.Request) void {
    var path_parts: [3][]const u8 = [_][]const u8{ "", "", "" };

    var it = std.mem.split(u8, r.path orelse return bad_request(&r), "/");

    while (it.next()) |part| {
        if (part.len == 0) {
            continue;
        }

        var should_continue = false;

        for (path_parts) |p| {
            if (p.len == 0) {
                should_continue = true;
                break;
            }
        }

        if (!should_continue) {
            break;
        }

        for (0..path_parts.len) |i| {
            if (path_parts[i].len == 0) {
                path_parts[i] = part;
                break;
            }
        }
    }

    if (std.mem.eql(u8, path_parts[0], "clientes")) {
        var cliente_id = std.fmt.parseInt(u8, path_parts[1], 10) catch {
            return bad_request(&r);
        };

        if (cliente_id < 1 or cliente_id > 5) {
            return not_found(&r);
        }

        if (std.mem.eql(u8, path_parts[2], "extrato")) {
            return route_cliente_extrato(&r, cliente_id);
        } else if (std.mem.eql(u8, path_parts[2], "transacoes")) {
            return route_cliente_transacoes(&r, cliente_id);
        } else {
            return not_found(&r);
        }
    }

    return not_found(&r);
}

fn not_found(req: *const zap.Request) void {
    req.setStatus(.not_found);
    req.sendBody("") catch return;
}

fn bad_request(req: *const zap.Request) void {
    req.setStatus(.bad_request);
    req.sendBody("") catch return;
}

fn unprocessable_entity(req: *const zap.Request) void {
    req.setStatus(.unprocessable_entity);
    req.sendBody("") catch return;
}

fn json(req: *const zap.Request, body: []const u8) void {
    req.setStatus(.ok);
    req.setContentType(.JSON);
    req.sendBody(body) catch return;
}

fn route_cliente_extrato(r: *const zap.Request, cliente_id: u8) void {
    _ = r;
    std.debug.print("Route: cliente_extrato; cliente_id: {}\n", .{cliente_id});
}

fn route_cliente_transacoes(r: *const zap.Request, cliente_id: u8) void {
    _ = r;
    std.debug.print("Route: cliente_transacoes; cliente_id: {}\n", .{cliente_id});
}

pub fn main() !void {
    var listener = zap.HttpListener.init(.{
        .port = port,
        .on_request = on_request,
        .log = true,
        .max_clients = 100000,
    });
    try listener.listen();

    std.debug.print("Listening on 0.0.0.0:{}\n", .{ .port = port });

    zap.start(.{
        .threads = 11,
        .workers = 11,
    });
}
