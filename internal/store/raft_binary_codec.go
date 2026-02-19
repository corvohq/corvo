package store

import (
	"encoding/binary"
	"fmt"
	"math"

	oldproto "github.com/golang/protobuf/proto" //nolint:staticcheck // hand-written proto structs use v1 API
)

var raftBinaryPrefix = []byte{0x43, 0x42, 0x31} // "CB1"

// marshalMultiBinary encodes a MultiOp with custom binary encoding.
// Hot-path ops (FetchBatch, AckBatch) use hand-written encoding;
// all other ops fall back to per-op protobuf encoding.
func marshalMultiBinary(inputs []OpInput) ([]byte, error) {
	// Pre-allocate: 3 (prefix) + 1 (numOps uvarint) + estimate per op.
	buf := make([]byte, 0, 3+1+len(inputs)*128)
	buf = append(buf, raftBinaryPrefix...)

	var tmp [binary.MaxVarintLen64]byte
	n := binary.PutUvarint(tmp[:], uint64(len(inputs)))
	buf = append(buf, tmp[:n]...)

	for _, in := range inputs {
		n = binary.PutUvarint(tmp[:], uint64(in.Type))
		buf = append(buf, tmp[:n]...)

		var opData []byte
		var err error
		switch in.Type {
		case OpFetchBatch:
			v, ok := in.Data.(FetchBatchOp)
			if !ok {
				return nil, fmt.Errorf("fetch batch op type mismatch: %T", in.Data)
			}
			opData = appendFetchBatch(nil, &v)
		case OpAckBatch:
			v, ok := in.Data.(AckBatchOp)
			if !ok {
				return nil, fmt.Errorf("ack batch op type mismatch: %T", in.Data)
			}
			opData = appendAckBatch(nil, &v)
		default:
			opData, err = marshalPBOpData(in.Type, in.Data)
			if err != nil {
				return nil, err
			}
		}

		n = binary.PutUvarint(tmp[:], uint64(len(opData)))
		buf = append(buf, tmp[:n]...)
		buf = append(buf, opData...)
	}
	return buf, nil
}

// marshalPBOpData encodes a single op as protobuf bytes (fallback path).
func marshalPBOpData(opType OpType, data any) ([]byte, error) {
	pb, err := buildPBOp(opType, data)
	if err != nil {
		return nil, err
	}
	return oldproto.Marshal(pb)
}

// decodeMultiBinary decodes a CB1-prefixed multi op.
func decodeMultiBinary(data []byte) (*DecodedRaftOp, error) {
	pos := len(raftBinaryPrefix)
	if pos >= len(data) {
		return nil, fmt.Errorf("binary op too short")
	}

	numOps, n := binary.Uvarint(data[pos:])
	if n <= 0 {
		return nil, fmt.Errorf("binary op: invalid numOps uvarint")
	}
	pos += n

	out := &DecodedRaftOp{
		Type:  OpMulti,
		Multi: make([]*DecodedRaftOp, 0, int(numOps)),
	}

	for i := 0; i < int(numOps); i++ {
		if pos >= len(data) {
			return nil, fmt.Errorf("binary op: truncated at op %d", i)
		}

		opType, n := binary.Uvarint(data[pos:])
		if n <= 0 {
			return nil, fmt.Errorf("binary op: invalid opType uvarint at op %d", i)
		}
		pos += n

		dataLen, n := binary.Uvarint(data[pos:])
		if n <= 0 {
			return nil, fmt.Errorf("binary op: invalid dataLen uvarint at op %d", i)
		}
		pos += n

		if pos+int(dataLen) > len(data) {
			return nil, fmt.Errorf("binary op: data overflow at op %d", i)
		}
		opData := data[pos : pos+int(dataLen)]
		pos += int(dataLen)

		var decoded *DecodedRaftOp
		var err error
		switch OpType(opType) {
		case OpFetchBatch:
			decoded, err = decodeFetchBatch(opData)
		case OpAckBatch:
			decoded, err = decodeAckBatch(opData)
		default:
			decoded, err = decodePBOpData(OpType(opType), opData)
		}
		if err != nil {
			return nil, fmt.Errorf("binary op %d (type %d): %w", i, opType, err)
		}
		out.Multi = append(out.Multi, decoded)
	}
	return out, nil
}

// decodePBOpData decodes a single protobuf-encoded op (fallback path).
func decodePBOpData(opType OpType, data []byte) (*DecodedRaftOp, error) {
	var pb pbOp
	if err := oldproto.Unmarshal(data, &pb); err != nil {
		return nil, fmt.Errorf("unmarshal fallback protobuf op: %w", err)
	}
	return fromPBOp(&pb)
}

// --- FetchBatchOp binary encoding ---
// Layout: fixed64(NowNs) + fixed64(RandomSeed) + uvarint(LeaseDuration) +
//         uvarint(Count) + lenStrings(Queues) + lenStr(WorkerID) +
//         lenStr(Hostname) + lenStrings(CandidateJobIDs) + lenStrings(CandidateQueues)

func appendFetchBatch(buf []byte, op *FetchBatchOp) []byte {
	buf = appendFixed64(buf, op.NowNs)
	buf = appendFixed64(buf, op.RandomSeed)
	buf = appendUvarint(buf, uint64(op.LeaseDuration))
	buf = appendUvarint(buf, uint64(op.Count))
	buf = appendStringSlice(buf, op.Queues)
	buf = appendLenString(buf, op.WorkerID)
	buf = appendLenString(buf, op.Hostname)
	buf = appendStringSlice(buf, op.CandidateJobIDs)
	buf = appendStringSlice(buf, op.CandidateQueues)
	return buf
}

func decodeFetchBatch(data []byte) (*DecodedRaftOp, error) {
	var op FetchBatchOp
	r := &binReader{data: data}

	op.NowNs = r.readFixed64()
	op.RandomSeed = r.readFixed64()
	op.LeaseDuration = int(r.readUvarint())
	op.Count = int(r.readUvarint())
	op.Queues = r.readStringSlice()
	op.WorkerID = r.readLenString()
	op.Hostname = r.readLenString()
	op.CandidateJobIDs = r.readStringSlice()
	op.CandidateQueues = r.readStringSlice()

	if r.err != nil {
		return nil, fmt.Errorf("decode fetch batch: %w", r.err)
	}
	return &DecodedRaftOp{Type: OpFetchBatch, FetchBatch: &op}, nil
}

// --- AckBatchOp binary encoding ---
// Layout: fixed64(NowNs) + uvarint(NumAcks) + per-ack encoding

func appendAckBatch(buf []byte, op *AckBatchOp) []byte {
	buf = appendFixed64(buf, op.NowNs)
	buf = appendUvarint(buf, uint64(len(op.Acks)))
	for i := range op.Acks {
		buf = appendAckOp(buf, &op.Acks[i])
	}
	return buf
}

func appendAckOp(buf []byte, ack *AckOp) []byte {
	buf = appendFixed64(buf, ack.NowNs)
	buf = appendLenString(buf, ack.JobID)
	buf = appendLenBytes(buf, ack.Result)
	buf = appendLenBytes(buf, ack.Checkpoint)
	buf = appendLenString(buf, ack.AgentStatus)
	buf = appendLenString(buf, ack.HoldReason)
	buf = appendLenString(buf, ack.StepStatus)
	buf = appendLenString(buf, ack.ExitReason)
	// Usage report: 1-byte flag + fields if present.
	if ack.Usage != nil && !ack.Usage.IsZero() {
		buf = append(buf, 1)
		buf = appendUsageReport(buf, ack.Usage)
	} else {
		buf = append(buf, 0)
	}
	return buf
}

func appendUsageReport(buf []byte, u *UsageReport) []byte {
	buf = appendVarint(buf, u.InputTokens)
	buf = appendVarint(buf, u.OutputTokens)
	buf = appendVarint(buf, u.CacheCreationTokens)
	buf = appendVarint(buf, u.CacheReadTokens)
	buf = appendLenString(buf, u.Model)
	buf = appendLenString(buf, u.Provider)
	buf = appendFixed64(buf, math.Float64bits(u.CostUSD))
	return buf
}

func decodeAckBatch(data []byte) (*DecodedRaftOp, error) {
	var op AckBatchOp
	r := &binReader{data: data}

	op.NowNs = r.readFixed64()
	numAcks := int(r.readUvarint())
	op.Acks = make([]AckOp, numAcks)
	for i := 0; i < numAcks; i++ {
		if r.err != nil {
			return nil, fmt.Errorf("decode ack batch at ack %d: %w", i, r.err)
		}
		op.Acks[i] = r.readAckOp()
	}

	if r.err != nil {
		return nil, fmt.Errorf("decode ack batch: %w", r.err)
	}
	return &DecodedRaftOp{Type: OpAckBatch, AckBatch: &op}, nil
}

func (r *binReader) readAckOp() AckOp {
	var ack AckOp
	ack.NowNs = r.readFixed64()
	ack.JobID = r.readLenString()
	ack.Result = r.readLenBytesJSON()
	ack.Checkpoint = r.readLenBytesJSON()
	ack.AgentStatus = r.readLenString()
	ack.HoldReason = r.readLenString()
	ack.StepStatus = r.readLenString()
	ack.ExitReason = r.readLenString()
	flag := r.readByte()
	if flag == 1 {
		ack.Usage = r.readUsageReport()
	}
	return ack
}

func (r *binReader) readUsageReport() *UsageReport {
	u := &UsageReport{}
	u.InputTokens = r.readVarint()
	u.OutputTokens = r.readVarint()
	u.CacheCreationTokens = r.readVarint()
	u.CacheReadTokens = r.readVarint()
	u.Model = r.readLenString()
	u.Provider = r.readLenString()
	u.CostUSD = math.Float64frombits(r.readFixed64())
	return u
}

// --- Primitives ---

func appendFixed64(buf []byte, v uint64) []byte {
	var tmp [8]byte
	binary.LittleEndian.PutUint64(tmp[:], v)
	return append(buf, tmp[:]...)
}

func appendUvarint(buf []byte, v uint64) []byte {
	var tmp [binary.MaxVarintLen64]byte
	n := binary.PutUvarint(tmp[:], v)
	return append(buf, tmp[:n]...)
}

func appendVarint(buf []byte, v int64) []byte {
	var tmp [binary.MaxVarintLen64]byte
	n := binary.PutVarint(tmp[:], v)
	return append(buf, tmp[:n]...)
}

func appendLenString(buf []byte, s string) []byte {
	buf = appendUvarint(buf, uint64(len(s)))
	return append(buf, s...)
}

func appendLenBytes(buf []byte, b []byte) []byte {
	buf = appendUvarint(buf, uint64(len(b)))
	return append(buf, b...)
}

func appendStringSlice(buf []byte, ss []string) []byte {
	buf = appendUvarint(buf, uint64(len(ss)))
	for _, s := range ss {
		buf = appendLenString(buf, s)
	}
	return buf
}

// binReader is a simple sequential reader over a byte slice.
type binReader struct {
	data []byte
	pos  int
	err  error
}

func (r *binReader) remaining() int {
	return len(r.data) - r.pos
}

func (r *binReader) readByte() byte {
	if r.err != nil {
		return 0
	}
	if r.pos >= len(r.data) {
		r.err = fmt.Errorf("unexpected end of data at pos %d", r.pos)
		return 0
	}
	b := r.data[r.pos]
	r.pos++
	return b
}

func (r *binReader) readFixed64() uint64 {
	if r.err != nil {
		return 0
	}
	if r.remaining() < 8 {
		r.err = fmt.Errorf("not enough data for fixed64 at pos %d", r.pos)
		return 0
	}
	v := binary.LittleEndian.Uint64(r.data[r.pos:])
	r.pos += 8
	return v
}

func (r *binReader) readUvarint() uint64 {
	if r.err != nil {
		return 0
	}
	v, n := binary.Uvarint(r.data[r.pos:])
	if n <= 0 {
		r.err = fmt.Errorf("invalid uvarint at pos %d", r.pos)
		return 0
	}
	r.pos += n
	return v
}

func (r *binReader) readVarint() int64 {
	if r.err != nil {
		return 0
	}
	v, n := binary.Varint(r.data[r.pos:])
	if n <= 0 {
		r.err = fmt.Errorf("invalid varint at pos %d", r.pos)
		return 0
	}
	r.pos += n
	return v
}

func (r *binReader) readLenString() string {
	length := int(r.readUvarint())
	if r.err != nil {
		return ""
	}
	if r.remaining() < length {
		r.err = fmt.Errorf("not enough data for string (need %d, have %d) at pos %d", length, r.remaining(), r.pos)
		return ""
	}
	s := string(r.data[r.pos : r.pos+length])
	r.pos += length
	return s
}

func (r *binReader) readLenBytes() []byte {
	length := int(r.readUvarint())
	if r.err != nil {
		return nil
	}
	if length == 0 {
		return nil
	}
	if r.remaining() < length {
		r.err = fmt.Errorf("not enough data for bytes (need %d, have %d) at pos %d", length, r.remaining(), r.pos)
		return nil
	}
	b := make([]byte, length)
	copy(b, r.data[r.pos:r.pos+length])
	r.pos += length
	return b
}

// readLenBytesJSON reads length-prefixed bytes and returns them as json.RawMessage.
// Returns nil for zero-length (preserving json.RawMessage nil semantics).
func (r *binReader) readLenBytesJSON() []byte {
	return r.readLenBytes()
}

func (r *binReader) readStringSlice() []string {
	count := int(r.readUvarint())
	if r.err != nil || count == 0 {
		return nil
	}
	ss := make([]string, count)
	for i := 0; i < count; i++ {
		ss[i] = r.readLenString()
		if r.err != nil {
			return nil
		}
	}
	return ss
}
