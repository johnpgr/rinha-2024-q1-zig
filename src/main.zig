const std = @import("std");
const zap = @import("zap");
const pg = @import("pg");
const Time = @import("time.zig").Time;
const exit = std.os.exit;
const PORT = 8080;

var gpa = std.heap.GeneralPurposeAllocator(.{
    .thread_safe = true,
}){};
var allocator = gpa.allocator();
var pool: *pg.Pool = undefined;

const TransacaoResponse = struct {
    saldo: i32,
    limite: i32,
};

const Cliente = struct {
    const Self = @This();

    id: u8,
    nome: []const u8,
    limite: i64,
    saldo: i64,

    pub fn efetuar_transacao(db: *pg.Conn, cliente_id: u8, valor_transacao: i64) !TransacaoResponse {
        const query =
            \\ UPDATE cliente
            \\ SET saldo = saldo + $2
            \\ WHERE
            \\   id = $1
            \\   AND $2 + saldo + limite >= 0
            \\ RETURNING saldo, limite
        ;

        var res = try db.query(query, .{
            cliente_id,
            valor_transacao,
        });
        defer res.deinit();

        while (try res.next()) |row| {
            //TODO: Find why this panics if using row.get(i64) here
            var saldo = row.get(i32, 0);
            var limite = row.get(i32, 1);
            return .{ .saldo = saldo, .limite = limite };
        }

        return error.InsufficientFunds;
    }
};

const Extrato = struct {
    const Self = @This();

    saldo: struct {
        total: i64,
        data_extrato: []const u8,
        limite: i64,
    },
    ultimas_transacoes: [10]Transacao,
};

const TransacaoRequestError = error{
    InvalidValor,
    InvalidTipo,
    InvalidDescricao,
    InsufficientFunds,
};

const TransacaoRequest = struct {
    const Self = @This();

    valor: f64,
    tipo: []const u8,
    descricao: []const u8,

    pub fn to_transacao(self: *Self, cliente_id: u8) TransacaoRequestError!Transacao {
        var valor_mod = std.math.modf(self.valor);

        if (valor_mod.ipart < 0.0 or (valor_mod.fpart != 0.0)) {
            return error.InvalidValor;
        }
        if (self.descricao.len == 0 or self.descricao.len > 10) {
            return error.InvalidDescricao;
        }

        var is_credito = std.mem.eql(u8, self.tipo, "c");
        var is_debito = std.mem.eql(u8, self.tipo, "d");
        if (!is_credito and !is_debito) {
            return error.InvalidTipo;
        }

        var tipo = [1]u8{self.tipo[0]};
        var descricao: [10]u8 = undefined;
        std.mem.copy(u8, &descricao, self.descricao);
        var valor: i64 = @intFromFloat(valor_mod.ipart);

        return Transacao{
            .id = null,
            .cliente_id = cliente_id,
            .valor = valor,
            .tipo = tipo,
            .descricao = descricao,
            .realizada_em = Time.now(),
        };
    }
};

const Transacao = struct {
    const Self = @This();

    id: ?u8,
    cliente_id: u8,
    valor: i64,
    tipo: [1]u8,
    descricao: [10]u8,
    realizada_em: Time,

    pub fn from_json(json_str: []const u8, cliente_id: u8) !Self {
        var parsed = try std.json.parseFromSlice(TransacaoRequest, allocator, json_str, .{});
        defer parsed.deinit();
        return try parsed.value.to_transacao(cliente_id);
    }

    pub fn save(self: *Self, db: *pg.Conn) !void {
        const query =
            \\ INSERT INTO transacao (cliente_id, valor, tipo, descricao, realizada_em)
            \\ VALUES ($1, $2, $3, $4, $5)
        ;

        try db.exec(query, .{
            self.cliente_id,
            self.valor,
            self.tipo,
            self.descricao,
            self.realizada_em,
        });
    }
};

fn on_request(r: zap.Request) void {
    var path = r.path orelse return bad_request(&r);
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
    var buffer: [100]u8 = undefined;
    var json_to_send: []const u8 = undefined;

    if (zap.stringifyBuf(&buffer, res, .{})) |json_str| {
        json_to_send = json_str;
    } else {
        req.setStatus(.internal_server_error);
        req.sendBody("") catch unreachable;
        return;
    }

    req.setStatus(.ok);
    req.setContentType(.JSON) catch unreachable;
    req.sendBody(json_to_send) catch unreachable;
}

fn route_cliente_extrato(r: *const zap.Request, cliente_id: u8) void {
    _ = cliente_id;
    _ = r;
}

fn route_cliente_transacoes(r: *const zap.Request, cliente_id: u8) void {
    var db = pool.acquire() catch |err| {
        std.debug.print("err: {any}\n", .{err});
        return internal_error(r);
    };
    defer db.release();

    if (r.body) |body| {
        var transacao = Transacao.from_json(body, cliente_id) catch |err| {
            std.debug.print("err: {any}\n", .{err});
            return unprocessable_entity(r);
        };

        var valor_transacao = transacao.valor;
        if (std.mem.eql(u8, &transacao.tipo, "d")) {
            valor_transacao = valor_transacao * -1;
        }

        var result = Cliente.efetuar_transacao(db, cliente_id, valor_transacao) catch {
            return unprocessable_entity(r);
        };

        return json(r, result);
    }

    return bad_request(r);
}

pub fn main() !void {
    var nr_workers = try std.Thread.getCpuCount();
    var db_user = std.os.getenv("DB_USER") orelse {
        std.debug.print("DB_USER not set\n", .{});
        exit(1);
    };
    var db_pass = std.os.getenv("DB_PASSWORD") orelse {
        std.debug.print("DB_PASSWORD not set\n", .{});
        exit(1);
    };
    var db_name = std.os.getenv("DB_NAME") orelse {
        std.debug.print("DB_NAME not set\n", .{});
        exit(1);
    };

    pool = try pg.Pool.init(allocator, .{
        .size = @intCast(nr_workers),
        .connect = .{
            .port = 5432,
            .host = "localhost",
        },
        .auth = .{
            .username = db_user,
            .password = db_pass,
            .database = db_name,
            .timeout = 10_000,
        },
    });
    defer pool.deinit();

    var listener = zap.HttpListener.init(.{
        .port = PORT,
        .on_request = on_request,
        .log = true,
        .max_clients = 100_000,
    });

    listener.listen() catch |err| {
        std.debug.print("Error: {any}\n", .{err});
        exit(1);
    };

    std.debug.print("[ZAP] Running app on 0.0.0.0:{}\n[ZAP] We have {} workers\n", .{ PORT, nr_workers });

    zap.start(.{
        .threads = @intCast(nr_workers),
        .workers = @intCast(nr_workers),
    });
}
