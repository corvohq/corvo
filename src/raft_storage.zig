//! raft_storage.zig — Talon-backed Storage for zig-raft.
//!
//! Persists Raft Meta + log entries + snapshot under "r:" prefix in the
//! shared Talon DB. fsync behavior comes from Talon's opts.sync (set at
//! DB.open). Each Storage mutation is one Batch.commit() — Raft callers
//! that need write batching should batch at the propose layer (see Phase 4
//! plan), not here.
//!
//! Layout:
//!   r:meta             encoded Meta (term, voted_for, instance_uuid, cluster_id)
//!   r:log:<be-u64>     encoded Entry at that index
//!   r:snap:meta        encoded SnapshotMeta
//!   r:snap:manifest    chunk_count(4) | total_len(8) | xxhash64-of-blob(8)
//!   r:snap:c:<be-u32>  FSM snapshot blob chunk (max snapshot_chunk_size)
//!
//! The snapshot blob is chunked because Talon's ValueLog caps a single
//! value at 256 KiB — one key per chunk keeps every value comfortably
//! under that cap regardless of FSM size.
//!
//! All multi-byte integers are big-endian on disk.

const std = @import("std");
const assert_mod = @import("assert.zig");
const check = assert_mod.check;
const talon = @import("talon");
const raft = @import("raft");

const StorageError = raft.storage.StorageError;
const Meta = raft.storage.Meta;
const SnapshotMeta = raft.storage.SnapshotMeta;
const Snapshot = raft.storage.Snapshot;
const Entry = raft.messages.Entry;
const EntryType = raft.messages.EntryType;

/// Max length of voted_for ID. Matches zig-raft MemStorage.
pub const max_voted_for_len: usize = 64;

/// Talon key prefixes — kept narrow for fast prefix scans.
const key_meta = "r:meta";
const key_snap_meta = "r:snap:meta";
const key_snap_manifest = "r:snap:manifest";
/// Snapshot blob chunk keys: prefix + be-u32 chunk ordinal.
const snap_chunk_prefix: []const u8 = "r:snap:c:";
const snap_chunk_key_size: usize = snap_chunk_prefix.len + 4;
/// Smallest key strictly greater than every chunk key (':' = 0x3A; ';' = 0x3B).
const snap_chunk_upper: []const u8 = "r:snap:c;";
/// Snapshot blob chunk payload size — half of Talon's 256 KiB single-value
/// cap, so each chunk write is comfortably legal.
pub const snapshot_chunk_size: usize = 128 * 1024;
/// Bound on chunks per snapshot (max blob = 8 GiB). Keeps the reassembly
/// loop explicitly bounded.
pub const max_snapshot_chunks: u32 = 65_536;
/// Manifest layout: chunk_count(4) | total_len(8) | xxhash64(8).
const snap_manifest_size: usize = 4 + 8 + 8;
const log_key_prefix: []const u8 = "r:log:";
const log_key_size: usize = log_key_prefix.len + 8;
/// Smallest key strictly greater than every "r:log:..." entry — used
/// as the exclusive upper bound on prefix scans (':' = 0x3A; ';' = 0x3B).
const log_key_upper: []const u8 = "r:log;";

const meta_max_size: usize = 8 + 1 + max_voted_for_len + 16 + 8;

/// Raft Storage adapter. Caller owns the Talon DB.
pub const Storage = struct {
    db: *talon.DB,
    allocator: std.mem.Allocator,

    // Cached log bounds. last_idx == 0 means empty log.
    first_idx: u64,
    last_idx: u64,

    // Cached meta — read once at init, kept in sync on saveMeta.
    meta: Meta,
    voted_for_buf: [max_voted_for_len]u8 = undefined,
    voted_for_len: usize = 0,

    // Cached snapshot. Owned by self.allocator; freed on next saveSnapshot
    // or deinit.
    snap_meta: ?SnapshotMeta = null,
    snap_data_owned: ?[]u8 = null,
    snap_config_owned: ?[]u8 = null,

    // Arena for entry data slices returned via getEntries. Reset on every
    // mutation so callers get one window of validity per mutation cycle.
    // Heap-allocated so Storage values can be safely copied (returned by
    // value) without aliasing the arena's internal state.
    read_arena: *std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, db: *talon.DB) !Storage {
        const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
        var self: Storage = .{
            .db = db,
            .allocator = allocator,
            .first_idx = 1,
            .last_idx = 0,
            .meta = .{},
            .read_arena = arena_ptr,
        };
        try self.loadCachedState();
        return self;
    }

    pub fn deinit(self: *Storage) void {
        self.read_arena.deinit();
        self.allocator.destroy(self.read_arena);
        self.freeSnapshotCache();
    }

    pub fn storage(self: *Storage) raft.Storage {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    /// Release all entry-data slices returned by getEntries since the last
    /// release. Call once per tick after all sends + applies are done.
    /// Without this, the read arena grows unbounded across heartbeat-only
    /// ticks (no mutations to drive a reset).
    pub fn releaseReads(self: *Storage) void {
        self.resetReadArena();
    }

    // -------------------------------------------------------------------
    // Cached state init (called once from init).
    // -------------------------------------------------------------------

    fn loadCachedState(self: *Storage) !void {
        try self.loadMetaCache();
        try self.loadSnapshotCache();
        try self.scanLogBounds();
        // After scanLogBounds, first_idx may need to reflect the snapshot.
        if (self.last_idx == 0) {
            if (self.snap_meta) |sm| self.first_idx = sm.last_included_index + 1;
        }
    }

    fn loadMetaCache(self: *Storage) !void {
        var buf: [meta_max_size]u8 = undefined;
        const got = (self.db.getInto(key_meta, &buf) catch return StorageError.IoError) orelse return;
        try self.decodeMetaInto(got);
    }

    fn loadSnapshotCache(self: *Storage) !void {
        const meta_bytes = (self.db.get(key_snap_meta) catch return StorageError.IoError) orelse return;
        defer self.allocator.free(meta_bytes);
        // Meta and manifest are written in one batch — meta without a
        // manifest means torn/corrupted state, not "no snapshot".
        const manifest_bytes = (self.db.get(key_snap_manifest) catch return StorageError.IoError) orelse return StorageError.IoError;
        defer self.allocator.free(manifest_bytes);
        const manifest = decodeSnapManifest(manifest_bytes) catch return StorageError.IoError;
        if (manifest.chunk_count > max_snapshot_chunks) return StorageError.IoError;
        const expected_chunks: u64 = (manifest.total_len + snapshot_chunk_size - 1) / snapshot_chunk_size;
        if (manifest.chunk_count != expected_chunks) return StorageError.IoError;
        const data = try self.allocator.alloc(u8, @intCast(manifest.total_len));
        errdefer self.allocator.free(data);
        var i: u32 = 0;
        while (i < manifest.chunk_count) : (i += 1) {
            var key_buf: [snap_chunk_key_size]u8 = undefined;
            encodeSnapChunkKey(&key_buf, i);
            const chunk = (self.db.get(&key_buf) catch return StorageError.IoError) orelse return StorageError.IoError;
            defer self.allocator.free(chunk);
            const off = @as(usize, i) * snapshot_chunk_size;
            const end = @min(off + snapshot_chunk_size, data.len);
            if (chunk.len != end - off) return StorageError.IoError;
            @memcpy(data[off..end], chunk);
        }
        if (std.hash.XxHash64.hash(0, data) != manifest.blob_hash) return StorageError.IoError;
        const sm = decodeSnapshotMeta(meta_bytes) catch return StorageError.IoError;
        const cfg_owned = if (sm.config.len == 0) null else blk: {
            const c = try self.allocator.alloc(u8, sm.config.len);
            @memcpy(c, sm.config);
            break :blk c;
        };
        self.snap_meta = .{
            .last_included_index = sm.last_included_index,
            .last_included_term = sm.last_included_term,
            .config = if (cfg_owned) |c| c else &.{},
        };
        self.snap_data_owned = data;
        self.snap_config_owned = cfg_owned;
    }

    fn scanLogBounds(self: *Storage) !void {
        var batch = self.db.newBatch();
        defer self.db.closeBatch(batch);
        var iter = batch.newIterBounded(log_key_prefix, log_key_upper);
        defer iter.close();
        var found_first = false;
        if (iter.first()) {
            self.first_idx = decodeLogKey(iter.key()) catch return StorageError.IoError;
            self.last_idx = self.first_idx;
            found_first = true;
            while (iter.next()) {
                self.last_idx = decodeLogKey(iter.key()) catch return StorageError.IoError;
            }
        }
        if (!found_first) {
            self.first_idx = 1;
            self.last_idx = 0;
        }
    }

    // -------------------------------------------------------------------
    // Mutation helpers.
    // -------------------------------------------------------------------

    fn resetReadArena(self: *Storage) void {
        // .free_all rather than .retain_capacity — under normal load the
        // arena is reset every tick, so retaining the largest buffer is a
        // perf optimization with marginal payoff and a footgun: on test
        // cleanup any retained buffer must round-trip through deinit
        // exactly. Just free outright.
        _ = self.read_arena.reset(.free_all);
    }

    fn freeSnapshotCache(self: *Storage) void {
        if (self.snap_data_owned) |b| self.allocator.free(b);
        if (self.snap_config_owned) |b| self.allocator.free(b);
        self.snap_data_owned = null;
        self.snap_config_owned = null;
        self.snap_meta = null;
    }

    // -------------------------------------------------------------------
    // VTable bridges.
    // -------------------------------------------------------------------

    const vtable = raft.Storage.VTable{
        .loadMeta = loadMetaImpl,
        .saveMeta = saveMetaImpl,
        .firstIndex = firstIndexImpl,
        .lastIndex = lastIndexImpl,
        .termAt = termAtImpl,
        .getEntries = getEntriesImpl,
        .append = appendImpl,
        .truncate = truncateImpl,
        .snapshotMeta = snapshotMetaImpl,
        .loadSnapshot = loadSnapshotImpl,
        .saveSnapshot = saveSnapshotImpl,
        .compactLog = compactLogImpl,
    };

    fn loadMetaImpl(ptr: *anyopaque) StorageError!Meta {
        const self: *Storage = @ptrCast(@alignCast(ptr));
        return self.meta;
    }

    fn saveMetaImpl(ptr: *anyopaque, m: Meta) StorageError!void {
        const self: *Storage = @ptrCast(@alignCast(ptr));
        check(m.term >= self.meta.term, "raft term regressed: {d} -> {d}", .{ self.meta.term, m.term });
        // Persist first.
        var buf: [meta_max_size]u8 = undefined;
        const written = encodeMeta(&buf, m) catch return StorageError.IoError;
        var batch = self.db.newBatch();
        defer self.db.closeBatch(batch);
        batch.set(key_meta, buf[0..written]);
        batch.commit();
        // Update cache (copy voted_for into our buffer for stable lifetime).
        self.meta.term = m.term;
        self.meta.instance_uuid = m.instance_uuid;
        self.meta.cluster_id = m.cluster_id;
        if (m.voted_for) |vf| {
            check(vf.len <= max_voted_for_len, "voted_for too long: {d}", .{vf.len});
            @memcpy(self.voted_for_buf[0..vf.len], vf);
            self.voted_for_len = vf.len;
            self.meta.voted_for = self.voted_for_buf[0..self.voted_for_len];
        } else {
            self.voted_for_len = 0;
            self.meta.voted_for = null;
        }
    }

    fn firstIndexImpl(ptr: *anyopaque) u64 {
        const self: *Storage = @ptrCast(@alignCast(ptr));
        if (self.last_idx > 0) return self.first_idx;
        if (self.snap_meta) |sm| return sm.last_included_index + 1;
        return 1;
    }

    fn lastIndexImpl(ptr: *anyopaque) u64 {
        const self: *Storage = @ptrCast(@alignCast(ptr));
        if (self.last_idx > 0) return self.last_idx;
        if (self.snap_meta) |sm| return sm.last_included_index;
        return 0;
    }

    fn termAtImpl(ptr: *anyopaque, idx: u64) StorageError!u64 {
        const self: *Storage = @ptrCast(@alignCast(ptr));
        if (idx == 0) return 0;
        if (self.snap_meta) |sm| {
            if (idx == sm.last_included_index) return sm.last_included_term;
            if (idx < sm.last_included_index) return StorageError.IndexOutOfRange;
        }
        if (self.last_idx == 0) return StorageError.IndexOutOfRange;
        if (idx < self.first_idx or idx > self.last_idx) return StorageError.IndexOutOfRange;
        var key_buf: [log_key_size]u8 = undefined;
        encodeLogKey(&key_buf, idx);
        const v = (self.db.get(&key_buf) catch return StorageError.IoError) orelse return StorageError.IndexOutOfRange;
        defer self.allocator.free(v);
        const e = decodeEntry(v, self.allocator) catch return StorageError.IoError;
        // We only need the term — drop the data copy.
        self.allocator.free(e.data);
        return e.term;
    }

    fn getEntriesImpl(ptr: *anyopaque, lo: u64, hi: u64, out: []Entry) StorageError!usize {
        const self: *Storage = @ptrCast(@alignCast(ptr));
        if (lo >= hi) return 0;
        if (self.last_idx == 0) return 0;
        if (lo < self.first_idx) return StorageError.IndexOutOfRange;
        if (lo > self.last_idx) return 0;
        const real_hi = @min(hi, self.last_idx + 1);
        const count: usize = @intCast(real_hi - lo);
        if (count > out.len) return StorageError.IoError;
        const arena_alloc = self.read_arena.allocator();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            var key_buf: [log_key_size]u8 = undefined;
            encodeLogKey(&key_buf, lo + @as(u64, i));
            const v = (self.db.get(&key_buf) catch return StorageError.IoError) orelse return StorageError.IoError;
            defer self.allocator.free(v);
            out[i] = decodeEntry(v, arena_alloc) catch return StorageError.IoError;
        }
        return count;
    }

    fn appendImpl(ptr: *anyopaque, entries: []const Entry) StorageError!void {
        const self: *Storage = @ptrCast(@alignCast(ptr));
        if (entries.len == 0) return;
        const expected_first = if (self.last_idx == 0) entries[0].index else self.last_idx + 1;
        if (entries[0].index != expected_first) return StorageError.IndexOutOfRange;
        // Encode all entries first (heap-buffered for batch lifetime, freed below).
        var encoded = std.array_list.Managed([]u8).init(self.allocator);
        defer {
            for (encoded.items) |b| self.allocator.free(b);
            encoded.deinit();
        }
        for (entries) |e| {
            const buf = encodeEntryAlloc(self.allocator, e) catch return StorageError.OutOfMemory;
            encoded.append(buf) catch return StorageError.OutOfMemory;
        }
        var batch = self.db.newBatch();
        defer self.db.closeBatch(batch);
        for (entries, encoded.items) |e, payload| {
            var key_buf: [log_key_size]u8 = undefined;
            encodeLogKey(&key_buf, e.index);
            batch.set(&key_buf, payload);
        }
        batch.commit();
        // Update cache.
        if (self.last_idx == 0) self.first_idx = entries[0].index;
        self.last_idx = entries[entries.len - 1].index;
        self.resetReadArena();
    }

    fn truncateImpl(ptr: *anyopaque, from_index: u64) StorageError!void {
        const self: *Storage = @ptrCast(@alignCast(ptr));
        if (self.last_idx == 0) return;
        if (from_index > self.last_idx) return; // nothing to truncate
        const new_last: u64 = if (from_index <= self.first_idx) 0 else from_index - 1;
        // Batch delete the range [from_index, last_idx].
        var batch = self.db.newBatch();
        defer self.db.closeBatch(batch);
        var lo_key: [log_key_size]u8 = undefined;
        var hi_key: [log_key_size]u8 = undefined;
        encodeLogKey(&lo_key, from_index);
        // upper is exclusive — pass last_idx + 1, or the prefix-upper if it would overflow.
        if (self.last_idx == std.math.maxInt(u64)) {
            batch.deleteRange(&lo_key, log_key_upper);
        } else {
            encodeLogKey(&hi_key, self.last_idx + 1);
            batch.deleteRange(&lo_key, &hi_key);
        }
        batch.commit();
        if (new_last == 0) {
            self.first_idx = 1;
            self.last_idx = 0;
        } else {
            self.last_idx = new_last;
        }
        self.resetReadArena();
    }

    fn snapshotMetaImpl(ptr: *anyopaque) ?SnapshotMeta {
        const self: *Storage = @ptrCast(@alignCast(ptr));
        return self.snap_meta;
    }

    fn loadSnapshotImpl(ptr: *anyopaque) ?Snapshot {
        const self: *Storage = @ptrCast(@alignCast(ptr));
        const meta = self.snap_meta orelse return null;
        const data = self.snap_data_owned orelse return .{ .meta = meta, .data = "" };
        return .{ .meta = meta, .data = data };
    }

    fn saveSnapshotImpl(ptr: *anyopaque, meta: SnapshotMeta, data: []const u8) StorageError!void {
        const self: *Storage = @ptrCast(@alignCast(ptr));
        const chunk_count: u32 = @intCast((data.len + snapshot_chunk_size - 1) / snapshot_chunk_size);
        check(chunk_count <= max_snapshot_chunks, "snapshot blob too large: {d} bytes", .{data.len});
        var meta_buf: [256]u8 = undefined;
        const written = encodeSnapshotMeta(&meta_buf, meta) catch return StorageError.IoError;
        var manifest_buf: [snap_manifest_size]u8 = undefined;
        encodeSnapManifest(&manifest_buf, chunk_count, data.len, std.hash.XxHash64.hash(0, data));
        var batch = self.db.newBatch();
        defer self.db.closeBatch(batch);
        batch.set(key_snap_meta, meta_buf[0..written]);
        batch.set(key_snap_manifest, &manifest_buf);
        // Drop stale chunks past the new count (a previous snapshot may have
        // been larger); chunks [0, chunk_count) are overwritten below, so the
        // deleted range never overlaps the new writes.
        var stale_lo: [snap_chunk_key_size]u8 = undefined;
        encodeSnapChunkKey(&stale_lo, chunk_count);
        batch.deleteRange(&stale_lo, snap_chunk_upper);
        var i: u32 = 0;
        while (i < chunk_count) : (i += 1) {
            const off = @as(usize, i) * snapshot_chunk_size;
            const end = @min(off + snapshot_chunk_size, data.len);
            var key_buf: [snap_chunk_key_size]u8 = undefined;
            encodeSnapChunkKey(&key_buf, i);
            batch.set(&key_buf, data[off..end]);
        }
        batch.commit();
        // Refresh cache: free old, copy new.
        self.freeSnapshotCache();
        const data_owned = try self.allocator.alloc(u8, data.len);
        @memcpy(data_owned, data);
        const cfg_owned = if (meta.config.len == 0) null else blk: {
            const c = try self.allocator.alloc(u8, meta.config.len);
            @memcpy(c, meta.config);
            break :blk c;
        };
        self.snap_meta = .{
            .last_included_index = meta.last_included_index,
            .last_included_term = meta.last_included_term,
            .config = if (cfg_owned) |c| c else &.{},
        };
        self.snap_data_owned = data_owned;
        self.snap_config_owned = cfg_owned;
        self.resetReadArena();
    }

    fn compactLogImpl(ptr: *anyopaque, through_index: u64) StorageError!void {
        const self: *Storage = @ptrCast(@alignCast(ptr));
        if (self.last_idx == 0) return;
        if (through_index < self.first_idx) return; // already past
        var batch = self.db.newBatch();
        defer self.db.closeBatch(batch);
        var lo_key: [log_key_size]u8 = undefined;
        var hi_key: [log_key_size]u8 = undefined;
        encodeLogKey(&lo_key, self.first_idx);
        if (through_index >= self.last_idx) {
            // Drop everything.
            batch.deleteRange(&lo_key, log_key_upper);
            batch.commit();
            self.first_idx = 1;
            self.last_idx = 0;
        } else {
            encodeLogKey(&hi_key, through_index + 1);
            batch.deleteRange(&lo_key, &hi_key);
            batch.commit();
            self.first_idx = through_index + 1;
        }
        self.resetReadArena();
    }

    // -------------------------------------------------------------------
    // Encode / decode helpers.
    // -------------------------------------------------------------------

    fn decodeMetaInto(self: *Storage, bytes: []const u8) !void {
        // Layout: term(8) | vf_len(1) | voted_for(vf_len) | uuid(16) | cluster_id(8)
        if (bytes.len < 8 + 1) return StorageError.IoError;
        const term = std.mem.readInt(u64, bytes[0..8], .big);
        const vf_len: usize = bytes[8];
        if (vf_len > max_voted_for_len) return StorageError.IoError;
        const after_vf = 9 + vf_len;
        if (bytes.len < after_vf + 16 + 8) return StorageError.IoError;
        const uuid = std.mem.readInt(u128, bytes[after_vf..][0..16], .big);
        const cluster_id = std.mem.readInt(u64, bytes[after_vf + 16 ..][0..8], .big);
        self.meta.term = term;
        self.meta.instance_uuid = uuid;
        self.meta.cluster_id = cluster_id;
        if (vf_len == 0) {
            self.voted_for_len = 0;
            self.meta.voted_for = null;
        } else {
            @memcpy(self.voted_for_buf[0..vf_len], bytes[9 .. 9 + vf_len]);
            self.voted_for_len = vf_len;
            self.meta.voted_for = self.voted_for_buf[0..self.voted_for_len];
        }
    }
};

// =====================================================================
// Encoding helpers — kept as free functions for testability.
// =====================================================================

fn encodeLogKey(out: *[log_key_size]u8, idx: u64) void {
    @memcpy(out[0..log_key_prefix.len], log_key_prefix);
    std.mem.writeInt(u64, out[log_key_prefix.len..][0..8], idx, .big);
}

fn decodeLogKey(key: []const u8) !u64 {
    if (key.len != log_key_size) return error.InvalidKey;
    if (!std.mem.eql(u8, key[0..log_key_prefix.len], log_key_prefix)) return error.InvalidKey;
    return std.mem.readInt(u64, key[log_key_prefix.len..][0..8], .big);
}

fn encodeSnapChunkKey(out: *[snap_chunk_key_size]u8, ordinal: u32) void {
    @memcpy(out[0..snap_chunk_prefix.len], snap_chunk_prefix);
    std.mem.writeInt(u32, out[snap_chunk_prefix.len..][0..4], ordinal, .big);
}

const SnapManifest = struct {
    chunk_count: u32,
    total_len: u64,
    blob_hash: u64,
};

fn encodeSnapManifest(out: *[snap_manifest_size]u8, chunk_count: u32, total_len: usize, blob_hash: u64) void {
    std.mem.writeInt(u32, out[0..4], chunk_count, .big);
    std.mem.writeInt(u64, out[4..12], @intCast(total_len), .big);
    std.mem.writeInt(u64, out[12..20], blob_hash, .big);
}

fn decodeSnapManifest(bytes: []const u8) !SnapManifest {
    if (bytes.len != snap_manifest_size) return error.InvalidManifest;
    return .{
        .chunk_count = std.mem.readInt(u32, bytes[0..4], .big),
        .total_len = std.mem.readInt(u64, bytes[4..12], .big),
        .blob_hash = std.mem.readInt(u64, bytes[12..20], .big),
    };
}

fn encodeMeta(buf: *[meta_max_size]u8, m: Meta) !usize {
    std.mem.writeInt(u64, buf[0..8], m.term, .big);
    const vf_len: usize = if (m.voted_for) |vf| vf.len else 0;
    if (vf_len > max_voted_for_len) return error.VotedForTooLong;
    buf[8] = @intCast(vf_len);
    if (m.voted_for) |vf| @memcpy(buf[9..][0..vf_len], vf);
    const after_vf = 9 + vf_len;
    std.mem.writeInt(u128, buf[after_vf..][0..16], m.instance_uuid, .big);
    std.mem.writeInt(u64, buf[after_vf + 16 ..][0..8], m.cluster_id, .big);
    return after_vf + 16 + 8;
}

fn encodeEntryAlloc(allocator: std.mem.Allocator, e: Entry) ![]u8 {
    // Layout: type(1) | term(8) | index(8) | data_len(4) | data
    const total = 1 + 8 + 8 + 4 + e.data.len;
    const buf = try allocator.alloc(u8, total);
    buf[0] = @intFromEnum(e.type_);
    std.mem.writeInt(u64, buf[1..9], e.term, .big);
    std.mem.writeInt(u64, buf[9..17], e.index, .big);
    std.mem.writeInt(u32, buf[17..21], @intCast(e.data.len), .big);
    @memcpy(buf[21..], e.data);
    return buf;
}

fn decodeEntry(bytes: []const u8, allocator: std.mem.Allocator) !Entry {
    if (bytes.len < 21) return error.InvalidEntry;
    const t: EntryType = @enumFromInt(bytes[0]);
    const term = std.mem.readInt(u64, bytes[1..9], .big);
    const index = std.mem.readInt(u64, bytes[9..17], .big);
    const data_len = std.mem.readInt(u32, bytes[17..21], .big);
    if (bytes.len < 21 + data_len) return error.InvalidEntry;
    const data_copy = try allocator.alloc(u8, data_len);
    @memcpy(data_copy, bytes[21 .. 21 + data_len]);
    return .{ .type_ = t, .term = term, .index = index, .data = data_copy };
}

fn encodeSnapshotMeta(buf: []u8, m: SnapshotMeta) !usize {
    // Layout: last_included_index(8) | last_included_term(8) | cfg_len(4) | cfg
    if (m.config.len > std.math.maxInt(u32)) return error.ConfigTooLong;
    const total = 8 + 8 + 4 + m.config.len;
    if (buf.len < total) return error.BufferTooSmall;
    std.mem.writeInt(u64, buf[0..8], m.last_included_index, .big);
    std.mem.writeInt(u64, buf[8..16], m.last_included_term, .big);
    std.mem.writeInt(u32, buf[16..20], @intCast(m.config.len), .big);
    @memcpy(buf[20..total], m.config);
    return total;
}

fn decodeSnapshotMeta(bytes: []const u8) !SnapshotMeta {
    if (bytes.len < 20) return error.InvalidSnapshotMeta;
    const last_idx = std.mem.readInt(u64, bytes[0..8], .big);
    const last_term = std.mem.readInt(u64, bytes[8..16], .big);
    const cfg_len = std.mem.readInt(u32, bytes[16..20], .big);
    if (bytes.len < 20 + cfg_len) return error.InvalidSnapshotMeta;
    return .{
        .last_included_index = last_idx,
        .last_included_term = last_term,
        .config = bytes[20 .. 20 + cfg_len],
    };
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

const TestEnv = struct {
    db: *talon.DB,
    storage: Storage,
    path: []const u8,

    fn init(allocator: std.mem.Allocator, path: []const u8) !TestEnv {
        // Best effort cleanup.
        std.fs.cwd().deleteFile(path) catch {};
        var vlog_buf: [256]u8 = undefined;
        const vlog_path = std.fmt.bufPrint(&vlog_buf, "{s}.vlog", .{path}) catch unreachable;
        std.fs.cwd().deleteFile(vlog_path) catch {};
        const db = try talon.DB.open(allocator, path, .{});
        const s = try Storage.init(allocator, db);
        return .{ .db = db, .storage = s, .path = path };
    }

    fn deinit(self: *TestEnv, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.storage.deinit();
        self.db.close();
        std.fs.cwd().deleteFile(self.path) catch {};
        var vlog_buf: [256]u8 = undefined;
        const vlog_path = std.fmt.bufPrint(&vlog_buf, "{s}.vlog", .{self.path}) catch unreachable;
        std.fs.cwd().deleteFile(vlog_path) catch {};
    }
};

test "raft_storage: empty log" {
    var env = try TestEnv.init(testing.allocator, "/tmp/corvo-raft-storage-empty");
    defer env.deinit(testing.allocator);
    const s = env.storage.storage();
    try testing.expectEqual(@as(u64, 1), s.firstIndex());
    try testing.expectEqual(@as(u64, 0), s.lastIndex());
    const m = try s.loadMeta();
    try testing.expectEqual(@as(u64, 0), m.term);
    try testing.expect(m.voted_for == null);
}

test "raft_storage: meta round-trip" {
    var env = try TestEnv.init(testing.allocator, "/tmp/corvo-raft-storage-meta");
    defer env.deinit(testing.allocator);
    const s = env.storage.storage();
    try s.saveMeta(.{
        .term = 5,
        .voted_for = "node-3",
        .instance_uuid = 0xDEADBEEF_CAFEBABE_1111_2222,
        .cluster_id = 0x9988_7766_5544_3322,
    });
    const m = try s.loadMeta();
    try testing.expectEqual(@as(u64, 5), m.term);
    try testing.expectEqualStrings("node-3", m.voted_for.?);
    try testing.expectEqual(@as(u128, 0xDEADBEEF_CAFEBABE_1111_2222), m.instance_uuid);
    try testing.expectEqual(@as(u64, 0x9988_7766_5544_3322), m.cluster_id);
}

test "raft_storage: append + getEntries + termAt" {
    var env = try TestEnv.init(testing.allocator, "/tmp/corvo-raft-storage-append");
    defer env.deinit(testing.allocator);
    const s = env.storage.storage();
    const ents = [_]Entry{
        .{ .term = 1, .index = 1, .data = "alpha" },
        .{ .term = 1, .index = 2, .data = "beta" },
        .{ .term = 2, .index = 3, .data = "gamma" },
    };
    try s.append(&ents);
    try testing.expectEqual(@as(u64, 1), s.firstIndex());
    try testing.expectEqual(@as(u64, 3), s.lastIndex());
    try testing.expectEqual(@as(u64, 1), try s.termAt(1));
    try testing.expectEqual(@as(u64, 2), try s.termAt(3));

    var out: [4]Entry = undefined;
    const n = try s.getEntries(1, 4, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("alpha", out[0].data);
    try testing.expectEqualStrings("beta", out[1].data);
    try testing.expectEqualStrings("gamma", out[2].data);
    try testing.expectEqual(@as(u64, 2), out[2].term);
}

test "raft_storage: append rejects non-contiguous" {
    var env = try TestEnv.init(testing.allocator, "/tmp/corvo-raft-storage-noncontig");
    defer env.deinit(testing.allocator);
    const s = env.storage.storage();
    try s.append(&[_]Entry{.{ .term = 1, .index = 1, .data = "a" }});
    const bad = [_]Entry{.{ .term = 1, .index = 5, .data = "skip" }};
    try testing.expectError(StorageError.IndexOutOfRange, s.append(&bad));
}

test "raft_storage: truncate" {
    var env = try TestEnv.init(testing.allocator, "/tmp/corvo-raft-storage-trunc");
    defer env.deinit(testing.allocator);
    const s = env.storage.storage();
    const ents = [_]Entry{
        .{ .term = 1, .index = 1, .data = "a" },
        .{ .term = 1, .index = 2, .data = "b" },
        .{ .term = 1, .index = 3, .data = "c" },
        .{ .term = 1, .index = 4, .data = "d" },
    };
    try s.append(&ents);
    try s.truncate(3);
    try testing.expectEqual(@as(u64, 2), s.lastIndex());
    try testing.expectError(StorageError.IndexOutOfRange, s.termAt(3));
    try testing.expectEqual(@as(u64, 1), try s.termAt(2));
    // Truncating past last is a no-op.
    try s.truncate(99);
    try testing.expectEqual(@as(u64, 2), s.lastIndex());
    // Truncating from index 1 wipes everything.
    try s.truncate(1);
    try testing.expectEqual(@as(u64, 0), s.lastIndex());
    try testing.expectEqual(@as(u64, 1), s.firstIndex());
}

test "raft_storage: snapshot round-trip" {
    var env = try TestEnv.init(testing.allocator, "/tmp/corvo-raft-storage-snap");
    defer env.deinit(testing.allocator);
    const s = env.storage.storage();
    const cfg_bytes = "node-1,node-2,node-3";
    try s.saveSnapshot(.{
        .last_included_index = 42,
        .last_included_term = 7,
        .config = cfg_bytes,
    }, "fsm-bytes");
    const sm = s.snapshotMeta().?;
    try testing.expectEqual(@as(u64, 42), sm.last_included_index);
    try testing.expectEqual(@as(u64, 7), sm.last_included_term);
    try testing.expectEqualStrings(cfg_bytes, sm.config);
    const snap = s.loadSnapshot().?;
    try testing.expectEqualStrings("fsm-bytes", snap.data);
    // After snapshot with no log entries, firstIndex = last_included + 1.
    try testing.expectEqual(@as(u64, 43), s.firstIndex());
    try testing.expectEqual(@as(u64, 42), s.lastIndex());
    try testing.expectEqual(@as(u64, 7), try s.termAt(42));
    try testing.expectError(StorageError.IndexOutOfRange, s.termAt(41));
}

test "raft_storage: chunked snapshot > 256 KiB round-trips, survives reopen, stale chunks reclaimed" {
    const path = "/tmp/corvo-snap-storage-chunked";
    // 3 chunks: two full 128 KiB chunks + a 37,859-byte tail; total is
    // well past Talon's 256 KiB single-value cap.
    const big_len: usize = 300_003;
    const big = try testing.allocator.alloc(u8, big_len);
    defer testing.allocator.free(big);
    var rng = std.Random.DefaultPrng.init(0xC0DEC0DE);
    rng.random().bytes(big);

    std.fs.cwd().deleteFile(path) catch {};
    std.fs.cwd().deleteFile(path ++ ".vlog") catch {};
    {
        const db = try talon.DB.open(testing.allocator, path, .{});
        defer db.close();
        var s_obj = try Storage.init(testing.allocator, db);
        defer s_obj.deinit();
        const s = s_obj.storage();
        try s.saveSnapshot(.{
            .last_included_index = 100,
            .last_included_term = 3,
            .config = "n1,n2,n3",
        }, big);
        const snap = s.loadSnapshot().?;
        try testing.expectEqualSlices(u8, big, snap.data);
    }
    {
        const db = try talon.DB.open(testing.allocator, path, .{});
        defer {
            db.close();
            std.fs.cwd().deleteFile(path) catch {};
            std.fs.cwd().deleteFile(path ++ ".vlog") catch {};
        }
        var s_obj = try Storage.init(testing.allocator, db);
        defer s_obj.deinit();
        const s = s_obj.storage();
        // Reopen reassembles the blob from chunks and verifies the hash.
        const snap = s.loadSnapshot().?;
        try testing.expectEqualSlices(u8, big, snap.data);
        try testing.expectEqual(@as(u64, 100), snap.meta.last_included_index);

        // A smaller follow-up snapshot must reclaim the stale chunk keys.
        try s.saveSnapshot(.{
            .last_included_index = 200,
            .last_included_term = 4,
            .config = "n1,n2,n3",
        }, "tiny");
        const snap2 = s.loadSnapshot().?;
        try testing.expectEqualStrings("tiny", snap2.data);
        var chunk1_key: [snap_chunk_key_size]u8 = undefined;
        var chunk2_key: [snap_chunk_key_size]u8 = undefined;
        encodeSnapChunkKey(&chunk1_key, 1);
        encodeSnapChunkKey(&chunk2_key, 2);
        var probe: [8]u8 = undefined;
        try testing.expect((try db.getInto(&chunk1_key, &probe)) == null);
        try testing.expect((try db.getInto(&chunk2_key, &probe)) == null);
        var chunk0_key: [snap_chunk_key_size]u8 = undefined;
        encodeSnapChunkKey(&chunk0_key, 0);
        const got0 = (try db.getInto(&chunk0_key, &probe)).?;
        try testing.expectEqualStrings("tiny", got0);
    }
}

test "raft_storage: compactLog drops entries" {
    var env = try TestEnv.init(testing.allocator, "/tmp/corvo-raft-storage-compact");
    defer env.deinit(testing.allocator);
    const s = env.storage.storage();
    const ents = [_]Entry{
        .{ .term = 1, .index = 1, .data = "a" },
        .{ .term = 1, .index = 2, .data = "b" },
        .{ .term = 1, .index = 3, .data = "c" },
        .{ .term = 1, .index = 4, .data = "d" },
    };
    try s.append(&ents);
    try s.compactLog(2);
    try testing.expectEqual(@as(u64, 3), s.firstIndex());
    try testing.expectEqual(@as(u64, 4), s.lastIndex());
    try testing.expectError(StorageError.IndexOutOfRange, s.termAt(2));
    try testing.expectEqual(@as(u64, 1), try s.termAt(3));
}

test "raft_storage: durability across reopen" {
    const path = "/tmp/corvo-raft-storage-durable";
    // Best-effort cleanup before first open.
    std.fs.cwd().deleteFile(path) catch {};
    std.fs.cwd().deleteFile(path ++ ".vlog") catch {};
    {
        const db = try talon.DB.open(testing.allocator, path, .{});
        defer db.close();
        var s_obj = try Storage.init(testing.allocator, db);
        defer s_obj.deinit();
        const s = s_obj.storage();
        try s.saveMeta(.{ .term = 9, .voted_for = "n2", .instance_uuid = 1, .cluster_id = 2 });
        try s.append(&[_]Entry{
            .{ .term = 9, .index = 1, .data = "first" },
            .{ .term = 9, .index = 2, .data = "second" },
        });
        try s.saveSnapshot(.{
            .last_included_index = 0,
            .last_included_term = 0,
            .config = "",
        }, "");
    }
    {
        const db = try talon.DB.open(testing.allocator, path, .{});
        defer {
            db.close();
            std.fs.cwd().deleteFile(path) catch {};
            std.fs.cwd().deleteFile(path ++ ".vlog") catch {};
        }
        var s_obj = try Storage.init(testing.allocator, db);
        defer s_obj.deinit();
        const s = s_obj.storage();
        try testing.expectEqual(@as(u64, 1), s.firstIndex());
        try testing.expectEqual(@as(u64, 2), s.lastIndex());
        const m = try s.loadMeta();
        try testing.expectEqual(@as(u64, 9), m.term);
        try testing.expectEqualStrings("n2", m.voted_for.?);
        var out: [2]Entry = undefined;
        const n = try s.getEntries(1, 3, &out);
        try testing.expectEqual(@as(usize, 2), n);
        try testing.expectEqualStrings("first", out[0].data);
        try testing.expectEqualStrings("second", out[1].data);
    }
}
