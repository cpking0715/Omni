package protocol

import (
	"fmt"
	"strings"
)

// DumpProto renders a protobuf byte slice as an indented field tree —
// used to reverse-engineer frames captured from the browser.
func DumpProto(data []byte) string {
	var sb strings.Builder
	dumpProto(&sb, data, 0)
	return sb.String()
}

func dumpProto(sb *strings.Builder, data []byte, depth int) {
	p := &parser{data: data}
	indent := strings.Repeat("  ", depth)
	for !p.eof() {
		f, wt, err := p.next()
		if err != nil {
			fmt.Fprintf(sb, "%s<parse error: %v>\n", indent, err)
			return
		}
		switch wt {
		case wtVarint:
			v, err := p.varint()
			if err != nil {
				return
			}
			// int32 fields are often enum/sn values; int64 for timestamps
			fmt.Fprintf(sb, "%sf%d varint: %d\n", indent, f, v)
		case wtLen:
			b, err := p.lengthBytes()
			if err != nil {
				return
			}
			printable := isPrintable(b)
			if printable && len(b) > 0 {
				fmt.Fprintf(sb, "%sf%d len%d: %q\n", indent, f, len(b), string(b))
			} else {
				fmt.Fprintf(sb, "%sf%d len%d: <bytes>\n", indent, f, len(b))
				dumpProto(sb, b, depth+1)
			}
		case wtI64:
			if p.pos+8 > len(p.data) {
				return
			}
			fmt.Fprintf(sb, "%sf%d fixed64: %x\n", indent, f, p.data[p.pos:p.pos+8])
			p.pos += 8
		case wtI32:
			if p.pos+4 > len(p.data) {
				return
			}
			fmt.Fprintf(sb, "%sf%d fixed32: %x\n", indent, f, p.data[p.pos:p.pos+4])
			p.pos += 4
		default:
			fmt.Fprintf(sb, "%sf%d wiretype %d (skip)\n", indent, f, wt)
			if err := p.skip(wt); err != nil {
				return
			}
		}
	}
}

// isPrintable reports whether b is a UTF-8 printable string.
func isPrintable(b []byte) bool {
	if len(b) == 0 {
		return false
	}
	printable := 0
	for _, c := range b {
		if c >= 0x20 && c <= 0x7e {
			printable++
		} else if c == '\n' || c == '\r' || c == '\t' {
			printable++
		}
	}
	return float64(printable)/float64(len(b)) > 0.85
}
