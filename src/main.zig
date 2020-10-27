const std = @import("std");
const builtin = std.builtin;
const debug = std.debug;
const mem = std.mem;
const randomBytes = std.crypto.randomBytes;
const Vector = std.meta.Vector;

const Xoodoo = struct {
    const rcs = [12]u32{ 0x058, 0x038, 0x3c0, 0x0d0, 0x120, 0x014, 0x060, 0x02c, 0x380, 0x0f0, 0x1a0, 0x012 };
    const Lane = Vector(4, u32);
    state: [3]Lane,

    inline fn asWords(self: *Xoodoo) *[12]u32 {
        return @ptrCast(*[12]u32, &self.state);
    }

    inline fn asBytes(self: *Xoodoo) *[48]u8 {
        return @ptrCast(*[48]u8, &self.state);
    }

    inline fn rot(x: Lane, comptime n: comptime_int) Lane {
        return (x << @splat(4, @as(u5, n))) | (x >> @splat(4, @as(u5, 32 - n)));
    }

    fn permute(self: *Xoodoo) void {
        var a = self.state[0];
        var b = self.state[1];
        var c = self.state[2];
        inline for (rcs) |rc| {
            var p = @shuffle(u32, a ^ b ^ c, undefined, [_]i32{ 3, 0, 1, 2 });
            var e = rot(p, 5);
            p = rot(p, 14);
            e ^= p;
            a ^= e;
            b ^= e;
            c ^= e;
            b = @shuffle(u32, b, undefined, [_]i32{ 3, 0, 1, 2 });
            c = rot(c, 11);
            a[0] ^= rc;
            a ^= ~b & c;
            b ^= ~c & a;
            c ^= ~a & b;
            b = rot(b, 1);
            c = @bitCast(Lane, @shuffle(u8, @bitCast(Vector(16, u8), c), undefined, [_]i32{ 11, 8, 9, 10, 15, 12, 13, 14, 3, 0, 1, 2, 7, 4, 5, 6 }));
        }
        self.state[0] = a;
        self.state[1] = b;
        self.state[2] = c;
    }

    inline fn endianSwapRate(self: *Xoodoo) void {
        for (self.asWords()[0..4]) |*w| {
            w.* = mem.littleToNative(u32, w.*);
        }
    }

    inline fn endianSwapAll(self: *Xoodoo) void {
        for (self.asWords()) |*w| {
            w.* = mem.littleToNative(u32, w.*);
        }
    }

    fn squeezePermute(self: *Xoodoo) [16]u8 {
        self.endianSwapRate();
        const bytes = self.asBytes().*;
        self.endianSwapRate();
        self.permute();
        return bytes[0..16].*;
    }

    fn new(key: [32]u8, nonce: ?[16]u8) Xoodoo {
        var self = Xoodoo{ .state = undefined };
        var bytes = self.asBytes();
        if (nonce) |n| {
            mem.copy(u8, bytes[0..16], n[0..]);
        } else {
            mem.set(u8, bytes[0..16], 0);
        }
        mem.copy(u8, bytes[16..][0..32], key[0..]);
        self.endianSwapAll();
        self.permute();
        return self;
    }
};

pub const Charm = struct {
    x: Xoodoo,

    const tag_length = 16;
    const key_length = 32;
    const nonce_length = 16;
    const hash_length = 32;

    pub fn new(key: [key_length]u8, nonce: [nonce_length]u8) Charm {
        return Charm{ .x = Xoodoo.new(key, nonce) };
    }

    fn xor128(out: *[16]u8, in: *const [16]u8) void {
        for (out) |*x, i| {
            x.* ^= in[i];
        }
    }

    fn equal128(a: [16]u8, b: [16]u8) bool {
        var d: u8 = 0;
        for (a) |x, i| {
            d |= x ^ b[i];
        }
        return d == 0;
    }

    pub fn nonceIncrement(nonce: *[nonce_length]u8, endian: comptime builtin.Endian) void {
        const next = mem.readInt(u128, nonce, endian) +% 1;
        mem.writeInt(u128, nonce, next, endian);
    }

    pub fn encrypt(charm: *Charm, msg: []u8) [tag_length]u8 {
        var squeezed: [16]u8 = undefined;
        var bytes = charm.x.asBytes();
        var off: usize = 0;
        if (msg.len > 16) {
            while (off < msg.len - 16) : (off += 16) {
                charm.x.endianSwapRate();
                mem.copy(u8, squeezed[0..], bytes[0..16]);
                xor128(bytes[0..16], msg[off..][0..16]);
                charm.x.endianSwapRate();
                xor128(msg[off..][0..16], squeezed[0..]);
                charm.x.permute();
            }
        }
        const leftover = msg.len - off;
        var padded = [_]u8{0} ** (16 + 1);
        mem.copy(u8, padded[0..leftover], msg[off..][0..leftover]);
        padded[leftover] = 0x80;
        charm.x.endianSwapRate();
        mem.copy(u8, squeezed[0..], bytes[0..16]);
        xor128(bytes[0..16], padded[0..16]);
        charm.x.endianSwapRate();
        charm.x.asWords()[11] ^= (@as(u32, 1) << 24 | @intCast(u32, leftover) >> 4 << 25 | @as(u32, 1) << 26);
        xor128(padded[0..16], squeezed[0..]);
        mem.copy(u8, msg[off..][0..leftover], padded[0..leftover]);
        charm.x.permute();
        return charm.x.squeezePermute();
    }

    pub fn decrypt(charm: *Charm, msg: []u8, expected_tag: [tag_length]u8) !void {
        var squeezed: [16]u8 = undefined;
        var bytes = charm.x.asBytes();
        var off: usize = 0;
        if (msg.len > 16) {
            while (off < msg.len - 16) : (off += 16) {
                charm.x.endianSwapRate();
                mem.copy(u8, squeezed[0..], bytes[0..16]);
                xor128(msg[off..][0..16], squeezed[0..]);
                xor128(bytes[0..16], msg[off..][0..16]);
                charm.x.endianSwapRate();
                charm.x.permute();
            }
        }
        const leftover = msg.len - off;
        var padded = [_]u8{0} ** (16 + 1);
        mem.copy(u8, padded[0..leftover], msg[off..][0..leftover]);
        charm.x.endianSwapRate();
        mem.set(u8, squeezed[0..], 0);
        mem.copy(u8, squeezed[0..leftover], bytes[0..leftover]);
        xor128(padded[0..16], squeezed[0..]);
        padded[leftover] = 0x80;
        xor128(bytes[0..16], padded[0..16]);
        charm.x.endianSwapRate();
        charm.x.asWords()[11] ^= (@as(u32, 1) << 24 | @intCast(u32, leftover) >> 4 << 25 | @as(u32, 1) << 26);
        mem.copy(u8, msg[off..][0..leftover], padded[0..leftover]);
        charm.x.permute();
        const tag = charm.x.squeezePermute();
        if (!equal128(expected_tag, tag)) {
            mem.set(u8, msg, 0);
            return error.AuthenticationFailed;
        }
    }

    pub fn hash(charm: *Charm, msg: []const u8) [hash_length]u8 {
        var bytes = charm.x.asBytes();
        var off: usize = 0;
        if (msg.len > 16) {
            while (off < msg.len - 16) : (off += 16) {
                charm.x.endianSwapRate();
                xor128(bytes[0..16], msg[off..][0..16]);
                charm.x.endianSwapRate();
                charm.x.permute();
            }
        }
        const leftover = msg.len - off;
        var padded = [_]u8{0} ** (16 + 1);
        mem.copy(u8, padded[0..leftover], msg[off..][0..leftover]);
        padded[leftover] = 0x80;
        charm.x.endianSwapRate();
        xor128(bytes[0..16], padded[0..16]);
        charm.x.endianSwapRate();
        charm.x.asWords()[11] ^= (@as(u32, 1) << 24 | @intCast(u32, leftover) >> 4 << 25);
        charm.x.permute();
        var h: [hash_length]u8 = undefined;
        mem.copy(u8, h[0..16], charm.x.squeezePermute()[0..]);
        mem.copy(u8, h[16..32], charm.x.squeezePermute()[0..]);
        return h;
    }
};

test "encrypt and hash in a session" {
    var key: [Charm.key_length]u8 = undefined;
    var nonce: [Charm.nonce_length]u8 = undefined;

    try randomBytes(&key);
    try randomBytes(&nonce);

    const msg1_0 = "message 1";
    const msg2_0 = "message 2";
    var msg1 = msg1_0.*;
    var msg2 = msg2_0.*;

    var charm = Charm.new(key, nonce);
    const tag1 = charm.encrypt(msg1[0..]);
    const tag2 = charm.encrypt(msg2[0..]);
    const h = charm.hash(msg1_0);

    charm = Charm.new(key, nonce);
    try charm.decrypt(msg1[0..], tag1);
    try charm.decrypt(msg2[0..], tag2);
    const hx = charm.hash(msg1_0);

    debug.assert(mem.eql(u8, msg1[0..], msg1_0[0..]));
    debug.assert(mem.eql(u8, msg2[0..], msg2_0[0..]));
    debug.assert(mem.eql(u8, h[0..], hx[0..]));
}