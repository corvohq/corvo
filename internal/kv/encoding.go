package kv

import "encoding/binary"

// PutUint8 appends a single byte to dst.
func PutUint8(dst []byte, v uint8) []byte {
	return append(dst, v)
}

// PutUint32BE appends a big-endian uint32 to dst (4 bytes).
func PutUint32BE(dst []byte, v uint32) []byte {
	var buf [4]byte
	binary.BigEndian.PutUint32(buf[:], v)
	return append(dst, buf[:]...)
}

// PutUint64BE appends a big-endian uint64 to dst (8 bytes).
func PutUint64BE(dst []byte, v uint64) []byte {
	var buf [8]byte
	binary.BigEndian.PutUint64(buf[:], v)
	return append(dst, buf[:]...)
}

// GetUint32BE reads a big-endian uint32 from b.
func GetUint32BE(b []byte) uint32 {
	return binary.BigEndian.Uint32(b)
}

// GetUint64BE reads a big-endian uint64 from b.
func GetUint64BE(b []byte) uint64 {
	return binary.BigEndian.Uint64(b)
}
