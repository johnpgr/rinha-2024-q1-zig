const std = @import("std");
const zap = @import("zap");
const db = @import("db.zig");
const pg = @import("pg");
const Time = @import("time.zig").Time;

var gpa = std.heap.GeneralPurposeAllocator(.{
    .thread_safe = true,
}){};
const allocator = gpa.allocator();

const Cliente = struct {
    id: u8,
    nome: []const u8,
    limite: i32,
    saldo: i32,
    ultimas_transacoes: []Transacao,

    const Self = @This();

    pub fn find(conn: *pg.Conn, cliente_id: u8) !?Self {
        const query = "SELECT * from cliente WHERE id = $1";
        var cliente: Self = undefined;

        var res = try conn.query(query, .{cliente_id});

        defer res.deinit();

        while (try res.next()) |row| {
            cliente.id = row.get(u8, 0);
            cliente.nome = row.get([]const u8, 1);
            cliente.limite = row.get(i32, 2);
            cliente.saldo = row.get(i32, 3);
            const ultimas_transacoes_raw = row.get([]const u8, 4);
            var parsed = try std.json.parseFromSlice([]Transacao, allocator, ultimas_transacoes_raw, .{});
            defer parsed.deinit();
            cliente.ultimas_transacoes = parsed.value;

            return cliente;
        }

        return error.InsufficientFunds;
    }

    pub fn efetuar_transacao(conn: *pg.Conn, cliente_id: u8, transacao: Transacao) !EfetuarTransacaoResponse {
        const query = "SELECT add_transacao($1, $2)";
        const transacao_json = try json_stringify(transacao);

        var res = try conn.query(query, .{
            cliente_id,
            transacao_json,
        });
        defer res.deinit();

        while (try res.next()) |row| {
            var parsed = try std.json.parseFromSlice(EfetuarTransacaoResponse, allocator, row.get([]const u8, 0), .{});
            defer parsed.deinit();
            return parsed.value;
        }

        return error.InsufficientFunds;
    }
};

const EfetuarTransacaoResponse = struct {
    saldo: i32,
    limite: i32,
};

const Extrato = struct {
    saldo: struct {
        total: i32,
        data_extrato: [20]u8,
        limite: i32,
    },
    ultimas_transacoes: []Transacao,
};

const TransacaoRequestError = error{
    InvalidValor,
    InvalidTipo,
    InvalidDescricao,
    InsufficientFunds,
};

const TransacaoRequest = struct {
    valor: f64,
    tipo: []const u8,
    descricao: []const u8,

    const Self = @This();

    pub fn to_transacao(self: *Self) TransacaoRequestError!Transacao {
        const valor_mod = std.math.modf(self.valor);

        if (valor_mod.ipart < 0.0 or (valor_mod.fpart != 0.0)) {
            return error.InvalidValor;
        }
        if (self.descricao.len == 0 or self.descricao.len > 10) {
            return error.InvalidDescricao;
        }

        const is_credito = std.mem.eql(u8, self.tipo, "c");
        const is_debito = std.mem.eql(u8, self.tipo, "d");
        if (!is_credito and !is_debito) {
            return error.InvalidTipo;
        }

        const valor: i32 = @intFromFloat(valor_mod.ipart);

        return .{ .valor = valor, .tipo = self.tipo, .descricao = self.descricao, .realizada_em = Time.now().format_rfc3339() };
    }
};

const Transacao = struct {
    valor: i32,
    tipo: []const u8,
    descricao: []const u8,
    realizada_em: [20]u8,

    const Self = @This();

    pub fn from_json(json_str: []const u8) !Self {
        var parsed = try std.json.parseFromSlice(TransacaoRequest, allocator, json_str, .{});
        defer parsed.deinit();
        return try parsed.value.to_transacao();
    }
};

fn on_request(r: zap.Request) void {
    const path = r.path orelse return bad_request(&r);
    var path_parts: [3][]const u8 = .{ "", "", "" };

    var it = std.mem.split(u8, path, "/");

    while (it.next()) |part| {
        if (part.len == 0) {
            continue;
        }

        var should_continue = false;

        //find the first empty slot in path_parts
        for (path_parts) |p| {
            if (p.len == 0) {
                should_continue = true;
                break;
            }
        }

        if (!should_continue) {
            break;
        }

        //fill the first empty slot with the current part
        for (0..path_parts.len) |i| {
            if (path_parts[i].len == 0) {
                path_parts[i] = part;
                break;
            }
        }
    }

    if (std.mem.eql(u8, path_parts[0], "clientes")) {
        const cliente_id = std.fmt.parseInt(u8, path_parts[1], 10) catch {
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

fn ok(req: *const zap.Request, body: []const u8) void {
    req.setStatus(.ok);
    req.sendBody(body) catch unreachable;
}

fn not_found(req: *const zap.Request) void {
    req.setStatus(.not_found);
    req.sendBody("") catch unreachable;
}

fn bad_request(req: *const zap.Request) void {
    req.setStatus(.bad_request);
    req.sendBody("") catch unreachable;
}

fn unprocessable_entity(req: *const zap.Request) void {
    req.h.*.status = @as(usize, @intCast(422));
    req.sendBody("") catch unreachable;
}

fn internal_error(req: *const zap.Request) void {
    req.setStatus(.internal_server_error);
    req.sendBody("") catch unreachable;
}

fn json(req: *const zap.Request, res: anytype) void {
    const json_to_send = json_stringify(res) catch {
        return internal_error(req);
    };

    req.setStatus(.ok);
    req.setContentType(.JSON) catch unreachable;
    req.sendBody(json_to_send) catch unreachable;
}

fn json_stringify(data: anytype) ![]u8 {
    var string = std.ArrayList(u8).init(allocator);
    defer string.deinit();

    try std.json.stringify(data, .{}, string.writer());

    return try string.toOwnedSlice();
}

fn route_cliente_extrato(r: *const zap.Request, cliente_id: u8) void {
    var conn = db.pool.?.acquire() catch |err| {
        std.debug.print("db.pool.?.acquire error: {any}\n", .{err});
        return internal_error(r);
    };

    defer conn.release();

    const cliente = Cliente.find(conn, cliente_id) catch |err| {
        std.debug.print("Cliente.find error: {any}\n", .{err});
        return internal_error(r);
    } orelse {
        return not_found(r);
    };

    const extrato = Extrato{
        .saldo = .{
            .total = cliente.saldo,
            .data_extrato = Time.now().format_rfc3339(),
            .limite = cliente.limite,
        },
        .ultimas_transacoes = cliente.ultimas_transacoes,
    };

    return json(r, extrato);
}

fn route_cliente_transacoes(r: *const zap.Request, cliente_id: u8) void {
    if (r.body) |body| {
        const transacao = Transacao.from_json(body) catch {
            return unprocessable_entity(r);
        };

        var conn = db.pool.?.acquire() catch |err| {
            std.debug.print("db.pool.?.acquire error: {any}\n", .{err});
            return internal_error(r);
        };
        defer conn.release();

        const result = Cliente.efetuar_transacao(conn, cliente_id, transacao) catch |err| {
            switch (err) {
                error.InsufficientFunds => {
                    return unprocessable_entity(r);
                },
                else => {
                    std.debug.print("Cliente.efetuar_transacao error: {any}\n", .{err});
                    return unprocessable_entity(r);
                },
            }
        };

        return json(r, result);
    }

    return bad_request(r);
}

pub fn main() !void {
    const nr_workers = try std.Thread.getCpuCount();
    // const nr_workers = 4;
    const db_user = std.os.getenv("DB_USER") orelse {
        std.debug.print("DB_USER not set\n", .{});
        std.os.exit(1);
    };
    const db_pass = std.os.getenv("DB_PASS") orelse {
        std.debug.print("DB_PASSWORD not set\n", .{});
        std.os.exit(1);
    };
    const db_name = std.os.getenv("DB_NAME") orelse {
        std.debug.print("DB_NAME not set\n", .{});
        std.os.exit(1);
    };
    const db_host = std.os.getenv("DB_HOST") orelse {
        std.debug.print("DB_NAME not set\n", .{});
        std.os.exit(1);
    };
    const db_port = std.os.getenv("DB_PORT") orelse {
        std.debug.print("DB_NAME not set\n", .{});
        std.os.exit(1);
    };

    const port = std.os.getenv("PORT") orelse {
        std.debug.print("PORT not set\n", .{});
        std.os.exit(1);
    };

    try db.init(allocator, .{
        .host = db_host,
        .port = try std.fmt.parseInt(u16, db_port, 10),
        .pool_size = @intCast(nr_workers),
        .db_user = db_user,
        .db_pass = db_pass,
        .db_name = db_name,
    });
    defer db.deinit();

    var server = zap.HttpListener.init(.{
        .port = try std.fmt.parseInt(usize, port, 10),
        .on_request = on_request,
        .log = false,
        .max_clients = 100_000,
    });

    server.listen() catch |err| {
        std.debug.print("Error: {any}\n", .{err});
        std.os.exit(1);
    };

    std.debug.print("[ZAP] Running app on 0.0.0.0:{s}\n[ZAP] We have {} workers\n", .{ port, nr_workers });

    zap.start(.{
        .threads = @intCast(nr_workers),
        .workers = @intCast(nr_workers),
    });
}
