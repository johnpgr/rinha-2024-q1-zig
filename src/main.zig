const std = @import("std");
const zap = @import("zap");
const db = @import("db.zig");
const pg = @import("pg");
const Time = @import("time.zig").Time;
const exit = std.os.exit;

var gpa = std.heap.GeneralPurposeAllocator(.{
    .thread_safe = true,
}){};
const allocator = gpa.allocator();

const TransacaoResponse = struct {
    saldo: i32,
    limite: i32,
};

const Cliente = struct {
    id: u8,
    nome: []const u8,
    limite: i32,
    saldo: i32,

    const Self = @This();

    pub fn get_extrato(conn: *pg.Conn, cliente_id: u8) !Extrato {
        const query_cliente =
            \\ SELECT saldo, limite
            \\ FROM cliente
            \\ WHERE id = $1
        ;

        const query_transacoes =
            \\ SELECT valor, tipo, descricao, realizada_em
            \\ FROM transacao
            \\ WHERE cliente_id = $1
            \\ ORDER BY id DESC
            \\ LIMIT 10
        ;

        var res_cliente = try conn.query(query_cliente, .{cliente_id});
        defer res_cliente.deinit();

        var saldo: i32 = 0;
        var limite: i32 = 0;
        while (try res_cliente.next()) |row| {
            saldo = row.get(i32, 0);
            limite = row.get(i32, 1);
        }

        const data_extrato = Time.now().format_rfc3339();

        var res_transacoes = try conn.query(query_transacoes, .{cliente_id});
        defer res_transacoes.deinit();
        var ultimas_transacoes: ?std.ArrayList(ExtratoTransacaoResponse) = null;

        while (try res_transacoes.next()) |row| {
            const valor = row.get(i32, 0);
            const realizada_em = Time.from_timestamp(row.get(i64, 3)).format_rfc3339();
            const tipo = row.get([]const u8, 1);
            const descricao = row.get([]const u8, 2);

            const transacao = ExtratoTransacaoResponse{
                .valor = valor,
                .tipo = tipo,
                .descricao = descricao,
                .realizada_em = realizada_em,
            };

            if (ultimas_transacoes == null) {
                ultimas_transacoes = try std.ArrayList(ExtratoTransacaoResponse).initCapacity(allocator, 10);
                try ultimas_transacoes.?.append(transacao);
            } else {
                try ultimas_transacoes.?.append(transacao);
            }
        }

        if (ultimas_transacoes == null) {
            return .{ .saldo = .{ .total = saldo, .data_extrato = data_extrato, .limite = limite }, .ultimas_transacoes = null };
        } else {
            return .{
                .saldo = .{ .total = saldo, .data_extrato = data_extrato, .limite = limite },
                .ultimas_transacoes = try ultimas_transacoes.?.toOwnedSlice(),
            };
        }
    }

    pub fn efetuar_transacao(conn: *pg.Conn, cliente_id: u8, valor_transacao: i32) !TransacaoResponse {
        const query =
            \\ UPDATE cliente
            \\ SET saldo = saldo + $2
            \\ WHERE
            \\   id = $1
            \\   AND $2 + saldo + limite >= 0
            \\ RETURNING saldo, limite
        ;

        var res = try conn.query(query, .{
            cliente_id,
            valor_transacao,
        });
        defer res.deinit();

        while (try res.next()) |row| {
            const saldo = row.get(i32, 0);
            const limite = row.get(i32, 1);
            return .{ .saldo = saldo, .limite = limite };
        }

        return error.InsufficientFunds;
    }
};

///size in bytes: 35
const ExtratoTransacaoResponse = struct {
    valor: i32,
    tipo: []const u8,
    descricao: []const u8,
    realizada_em: [20]u8,
};

const Extrato = struct {
    saldo: struct {
        total: i32,
        data_extrato: [20]u8,
        limite: i32,
    },
    ultimas_transacoes: ?[]ExtratoTransacaoResponse,

    const Self = @This();
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

    pub fn to_transacao(self: *Self, cliente_id: u8) TransacaoRequestError!Transacao {
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

        return .{ .cliente_id = cliente_id, .valor = valor, .tipo = self.tipo, .descricao = self.descricao, .realizada_em = std.time.timestamp() };
    }
};

const Transacao = struct {
    cliente_id: u8,
    valor: i32,
    tipo: []const u8,
    descricao: []const u8,
    realizada_em: i64,

    const Self = @This();

    pub fn from_json(json_str: []const u8, cliente_id: u8) !Self {
        var parsed = try std.json.parseFromSlice(TransacaoRequest, allocator, json_str, .{});
        defer parsed.deinit();
        return try parsed.value.to_transacao(cliente_id);
    }

    pub fn save(self: *const Self, conn: *pg.Conn) !void {
        const query =
            \\ INSERT INTO transacao (cliente_id, valor, tipo, descricao, realizada_em) VALUES ($1, $2, $3, $4, $5)
        ;

        _ = try conn.exec(query, .{
            self.cliente_id,
            self.valor,
            self.tipo,
            self.descricao,
            self.realizada_em,
        });
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
    var json_to_send: []const u8 = undefined;
    var string = std.ArrayList(u8).init(allocator);
    defer string.deinit();

    std.json.stringify(res, .{}, string.writer()) catch {
        return internal_error(req);
    };
    json_to_send = string.items;

    req.setStatus(.ok);
    req.setContentType(.JSON) catch unreachable;
    req.sendBody(json_to_send) catch unreachable;
}

fn route_cliente_extrato(r: *const zap.Request, cliente_id: u8) void {
    const conn = db.pool.?.*.acquire() catch {
        return internal_error(r);
    };
    defer conn.release();

    const extrato = Cliente.get_extrato(conn, cliente_id) catch |err| {
        std.debug.print("Cliente.get_extrato error: {any}\n", .{err});
        return internal_error(r);
    };

    return json(r, extrato);
}

fn route_cliente_transacoes(r: *const zap.Request, cliente_id: u8) void {
    var conn = db.pool.?.*.acquire() catch {
        return internal_error(r);
    };
    defer conn.release();

    if (r.body) |body| {
        var transacao = Transacao.from_json(body, cliente_id) catch {
            return unprocessable_entity(r);
        };

        var valor_transacao = transacao.valor;
        if (std.mem.eql(u8, transacao.tipo, "d")) {
            valor_transacao = valor_transacao * -1;
        }

        const result = Cliente.efetuar_transacao(conn, cliente_id, valor_transacao) catch {
            return unprocessable_entity(r);
        };

        db.wait_conn(conn);

        transacao.save(conn) catch {
            return internal_error(r);
        };

        return json(r, result);
    }

    return bad_request(r);
}

pub fn main() !void {
    const nr_workers = 4;
    // const nr_workers = try std.Thread.getCpuCount();
    const db_user = std.os.getenv("DB_USER") orelse {
        std.debug.print("DB_USER not set\n", .{});
        exit(1);
    };
    const db_pass = std.os.getenv("DB_PASS") orelse {
        std.debug.print("DB_PASSWORD not set\n", .{});
        exit(1);
    };
    const db_name = std.os.getenv("DB_NAME") orelse {
        std.debug.print("DB_NAME not set\n", .{});
        exit(1);
    };
    const db_host = std.os.getenv("DB_HOST") orelse {
        std.debug.print("DB_NAME not set\n", .{});
        exit(1);
    };
    const db_port = std.os.getenv("DB_PORT") orelse {
        std.debug.print("DB_NAME not set\n", .{});
        exit(1);
    };

    const port = std.os.getenv("PORT") orelse {
        std.debug.print("PORT not set\n", .{});
        exit(1);
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
        exit(1);
    };

    std.debug.print("[ZAP] Running app on 0.0.0.0:{s}\n[ZAP] We have {} workers\n", .{ port, nr_workers });

    zap.start(.{
        .threads = @intCast(nr_workers),
        .workers = @intCast(nr_workers),
    });
}
