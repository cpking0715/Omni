// decodeframe 解码捕获的 WS 帧: 解析信封 + 解压 f8 载荷 (gzip/zlib) + 字段树
//
// 用法: decodeframe <base64-file> [--f8-raw]
package main

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"compress/zlib"
	"encoding/base64"
	"fmt"
	"os"
	"strings"

	"ttdm/internal/protocol"
)

// 简易 protobuf 字段遍历: 复制自 protocol 内部逻辑 (独立探针, 允许重复)
type walker struct {
	data []byte
	pos  int
}

func (w *walker) eof() bool { return w.pos >= len(w.data) }

func (w *walker) varint() (uint64, error) {
	var v uint64
	var shift uint
	for {
		if w.pos >= len(w.data) {
			return 0, fmt.Errorf("varint 截断")
		}
		b := w.data[w.pos]
		w.pos++
		v |= uint64(b&0x7f) << shift
		if b < 0x80 {
			return v, nil
		}
		shift += 7
		if shift > 63 {
			return 0, fmt.Errorf("varint 过长")
		}
	}
}

// 返回 (field, wireType, 内容), 内容类型由 wireType 决定: 0=varint, 2=bytes
func (w *walker) next() (int, int, any, error) {
	key, err := w.varint()
	if err != nil {
		return 0, 0, nil, err
	}
	field := int(key >> 3)
	wt := int(key & 7)
	switch wt {
	case 0:
		v, err := w.varint()
		return field, wt, v, err
	case 1:
		if w.pos+8 > len(w.data) {
			return 0, 0, nil, fmt.Errorf("fixed64 截断")
		}
		b := w.data[w.pos : w.pos+8]
		w.pos += 8
		return field, wt, b, nil
	case 2:
		l, err := w.varint()
		if err != nil {
			return 0, 0, nil, err
		}
		if w.pos+int(l) > len(w.data) {
			return 0, 0, nil, fmt.Errorf("bytes 截断")
		}
		b := w.data[w.pos : w.pos+int(l)]
		w.pos += int(l)
		return field, wt, b, nil
	case 5:
		if w.pos+4 > len(w.data) {
			return 0, 0, nil, fmt.Errorf("fixed32 截断")
		}
		b := w.data[w.pos : w.pos+4]
		w.pos += 4
		return field, wt, b, nil
	default:
		return 0, 0, nil, fmt.Errorf("wire type %d", wt)
	}
}

func walk(data []byte, indent string, depth int) {
	w := &walker{data: data}
	for !w.eof() {
		field, wt, v, err := w.next()
		if err != nil {
			fmt.Printf("%s<err: %v>\n", indent, err)
			return
		}
		switch wt {
		case 0:
			fmt.Printf("%sf%d varint: %d\n", indent, field, v)
		case 1:
			fmt.Printf("%sf%d fixed64: %x\n", indent, field, v)
		case 5:
			fmt.Printf("%sf%d fixed32: %x\n", indent, field, v)
		case 2:
			b := v.([]byte)
			printable := true
			for _, c := range b {
				if c < 0x20 || c > 0x7e {
					printable = false
					break
				}
			}
			if printable && len(b) > 0 {
				fmt.Printf("%sf%d len%d: %q\n", indent, field, len(b), string(b))
			} else if len(b) > 0 && depth < 6 {
				fmt.Printf("%sf%d len%d: <bytes>\n", indent, field, len(b))
				walk(b, indent+"  ", depth+1)
			} else {
				fmt.Printf("%sf%d len%d: <bytes>\n", indent, field, len(b))
			}
		}
	}
}

// tryInflate 尝试 zlib / gzip / raw deflate 解压
func tryInflate(b []byte) []byte {
	for _, f := range []func([]byte) ([]byte, error){
		func(x []byte) ([]byte, error) { // zlib
			r, err := zlib.NewReader(bytes.NewReader(x))
			if err != nil {
				return nil, err
			}
			defer r.Close()
			var out bytes.Buffer
			_, err = out.ReadFrom(r)
			return out.Bytes(), err
		},
		func(x []byte) ([]byte, error) { // gzip
			r, err := gzip.NewReader(bytes.NewReader(x))
			if err != nil {
				return nil, err
			}
			defer r.Close()
			var out bytes.Buffer
			_, err = out.ReadFrom(r)
			return out.Bytes(), err
		},
	} {
		if out, err := f(b); err == nil && len(out) > 0 {
			return out
		}
	}
	return nil
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "用法: decodeframe <base64-file>")
		os.Exit(1)
	}
	raw, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, "读取失败:", err)
		os.Exit(1)
	}
	// 支持多行: 每行一条 base64
	sc := bufio.NewScanner(bytes.NewReader(raw))
	for ln := 1; sc.Scan(); ln++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		data, err := base64.StdEncoding.DecodeString(line)
		if err != nil {
			fmt.Printf("--- 行 %d: base64 解码失败: %v\n", ln, err)
			continue
		}
		fmt.Printf("--- 行 %d: len=%d\n", ln, len(data))
		walk(data, "", 0)
		// 提取 f8 并尝试解压
		w := &walker{data: data}
		for !w.eof() {
			field, wt, v, err := w.next()
			if err != nil {
				break
			}
			if field == 8 && wt == 2 {
				b := v.([]byte)
				if infl := tryInflate(b); infl != nil {
					fmt.Printf("  >> f8 解压后 len=%d:\n", len(infl))
					walk(infl, "     ", 0)
				} else {
					fmt.Printf("  >> f8 未压缩或无法解压 (len=%d)\n", len(b))
				}
			}
		}
	}
	_ = protocol.DumpProto // 避免未使用
}
