const std = @import("std");
const zap = @import("zap");
const pg = @import("pg");
const Time = @import("time.zig").Time;
const exit = std.os.exit;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var allocator = gpa.allocator();

const Cliente = struct { id: u8, nome: []const u8, limite: i64, saldo: i64 };

const Extrato = struct {
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

        if (!std.mem.eql(u8, self.tipo, "c")) {
            return error.InvalidTipo;
        } else if (!std.mem.eql(u8, self.tipo, "d")) {
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
    req.sendBody("") catch return;
}

fn bad_request(req: *const zap.Request) void {
    req.setStatus(.bad_request);
    req.sendBody("") catch return;
}

fn unprocessable_entity(req: *const zap.Request) void {
    req.h.*.status = @as(usize, @intCast(422));
    req.sendBody("") catch return;
}

fn json(req: *const zap.Request, body: []const u8) void {
    req.setStatus(.ok);
    req.setContentType(.JSON);
    req.sendBody(body) catch return;
}

fn route_cliente_extrato(r: *const zap.Request, cliente_id: u8) void {
    _ = cliente_id;
    _ = r;
}

fn route_cliente_transacoes(r: *const zap.Request, cliente_id: u8) void {
    if (r.body) |body| {
        std.debug.print("body: {s}\n", .{body});
        var transacao = Transacao.from_json(body, cliente_id) catch |err| {
            std.debug.print("err: {any}\n", .{err});
            return unprocessable_entity(r);
        };
        std.debug.print("transacao: {any}\n", .{transacao});
    }

    return bad_request(r);
}

pub fn main() !void {
    const PORT = 8080;
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

    var pool = try pg.Pool.init(allocator, .{
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
    try listener.listen();

    std.debug.print("[ZAP] Running app on 0.0.0.0:{}\n[ZAP] We have {} workers", .{ PORT, nr_workers });

    zap.start(.{
        .threads = @intCast(nr_workers),
        .workers = @intCast(nr_workers),
    });
}
