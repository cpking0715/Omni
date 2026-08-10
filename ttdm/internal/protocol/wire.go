// Package protocol implements the TikTok Android IM WebSocket protocol
// (protobuf wire format), recovered from the decompiled Juytu client.
package protocol

import (
	"errors"
	"fmt"
)

// protobuf wire types used by the TikTok IM protocol.
const (
	wtVarint = 0
	wtI64    = 1
	wtLen    = 2
	wtI32    = 5
)

// encoder accumulates protobuf wire bytes.
type encoder struct{ b []byte }

func (e *encoder) varint(field int, v uint64) {
	e.b = appendVarint(e.b, uint64(field)<<3|wtVarint)
	e.b = appendVarint(e.b, v)
}

func (e *encoder) int32(field int, v int32) { e.varint(field, uint64(int64(v))) }

func (e *encoder) str(field int, s string) {
	e.b = appendVarint(e.b, uint64(field)<<3|wtLen)
	e.b = appendVarint(e.b, uint64(len(s)))
	e.b = append(e.b, s...)
}

func (e *encoder) bytes(field int, v []byte) {
	e.b = appendVarint(e.b, uint64(field)<<3|wtLen)
	e.b = appendVarint(e.b, uint64(len(v)))
	e.b = append(e.b, v...)
}

// msg embeds a pre-encoded sub-message on the given field.
func (e *encoder) msg(field int, inner []byte) { e.bytes(field, inner) }

// strMap encodes map<string,string> as repeated message entries.
func (e *encoder) strMap(field int, m map[string]string) {
	for k, v := range m {
		var entry encoder
		entry.str(1, k)
		entry.str(2, v)
		e.msg(field, entry.b)
	}
}

func appendVarint(b []byte, v uint64) []byte {
	for v >= 0x80 {
		b = append(b, byte(v)|0x80)
		v >>= 7
	}
	return append(b, byte(v))
}

// parser decodes protobuf wire bytes.
type parser struct {
	data []byte
	pos  int
}

func (p *parser) eof() bool { return p.pos >= len(p.data) }

// next returns the next field number and wire type.
func (p *parser) next() (field int, wt int, err error) {
	if p.eof() {
		return 0, 0, errors.New("unexpected EOF")
	}
	tag, n, err := readVarint(p.data[p.pos:])
	if err != nil {
		return 0, 0, err
	}
	p.pos += n
	return int(tag >> 3), int(tag & 7), nil
}

func (p *parser) skip(wt int) error {
	switch wt {
	case wtVarint:
		_, n, err := readVarint(p.data[p.pos:])
		if err != nil {
			return err
		}
		p.pos += n
	case wtI64:
		if p.pos+8 > len(p.data) {
			return errors.New("truncated fixed64")
		}
		p.pos += 8
	case wtLen:
		l, n, err := readVarint(p.data[p.pos:])
		if err != nil {
			return err
		}
		p.pos += n + int(l)
	case wtI32:
		if p.pos+4 > len(p.data) {
			return errors.New("truncated fixed32")
		}
		p.pos += 4
	default:
		return fmt.Errorf("unsupported wire type %d", wt)
	}
	return nil
}

func (p *parser) varint() (uint64, error) {
	v, n, err := readVarint(p.data[p.pos:])
	if err != nil {
		return 0, err
	}
	p.pos += n
	return v, nil
}

// lengthBytes reads a length-delimited payload.
func (p *parser) lengthBytes() ([]byte, error) {
	l, err := p.varint()
	if err != nil {
		return nil, err
	}
	if p.pos+int(l) > len(p.data) {
		return nil, errors.New("truncated length-delimited")
	}
	out := p.data[p.pos : p.pos+int(l)]
	p.pos += int(l)
	return out, nil
}

func (p *parser) str() (string, error) {
	b, err := p.lengthBytes()
	return string(b), err
}

// get first occurrence of a length-delimited field; nil if absent.
func (p *parser) findLen(field int) ([]byte, bool, error) {
	for !p.eof() {
		f, wt, err := p.next()
		if err != nil {
			return nil, false, err
		}
		if f == field {
			if wt != wtLen {
				return nil, false, fmt.Errorf("field %d wire type %d, want %d", field, wt, wtLen)
			}
			b, err := p.lengthBytes()
			return b, true, err
		}
		if err := p.skip(wt); err != nil {
			return nil, false, err
		}
	}
	return nil, false, nil
}

// getVarint returns the first varint field value.
func (p *parser) findVarint(field int) (uint64, bool, error) {
	for !p.eof() {
		f, wt, err := p.next()
		if err != nil {
			return 0, false, err
		}
		if f == field {
			if wt != wtVarint {
				return 0, false, fmt.Errorf("field %d wire type %d, want %d", field, wt, wtVarint)
			}
			v, err := p.varint()
			return v, true, err
		}
		if err := p.skip(wt); err != nil {
			return 0, false, err
		}
	}
	return 0, false, nil
}

// getStr returns the first string field value.
func (p *parser) findStr(field int) (string, bool, error) {
	b, ok, err := p.findLen(field)
	if err != nil || !ok {
		return "", ok, err
	}
	return string(b), true, nil
}

func readVarint(b []byte) (uint64, int, error) {
	var v uint64
	for i := 0; i < len(b); i++ {
		if i >= 10 {
			return 0, 0, errors.New("varint too long")
		}
		v |= uint64(b[i]&0x7f) << (7 * i)
		if b[i] < 0x80 {
			return v, i + 1, nil
		}
	}
	return 0, 0, errors.New("truncated varint")
}
