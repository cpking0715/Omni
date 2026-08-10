package protocol

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"strconv"
)

// Protocol commands (mirror the ProtoInclude discriminators).
const (
	cmdCreateConversation = 609
	cmdPreSend            = 411
	cmdSendMessage        = 100
)

// Content message types (field MessageType of the send body).
const (
	MsgText     = 7
	MsgSticker  = 5
	MsgVideo    = 8
	MsgHomePage = 25
	MsgLink     = 26
)

// Constants mirrored from the decompiled Android client.
const (
	deviceBrand = "Samsung"
	deviceType  = "SM-G9900"
	deviceOS    = "android"
	osAPI       = "32"
	osVersion   = "12"
	abi         = "arm64-v8a"
	resolution  = "900*1600"
	appVersion  = "31.7.3"
	appName     = "musical_ly"
	ua          = "okhttp/3.12.13.4-tiktok"
)

// buildAppImRequest assembles the top-level request envelope.
func buildAppImRequest(sn int32, cmd int32, deviceID string, body []byte) []byte {
	var msg encoder
	msg.int32(1, cmd)
	msg.int32(2, sn)
	msg.str(3, "local")
	msg.int32(5, 1)
	msg.str(7, "0")
	msg.bytes(8, body)
	msg.str(9, deviceID)
	msg.str(10, "googleplay")
	msg.str(11, "android")
	msg.str(12, deviceType)
	msg.str(13, osVersion)
	msg.str(14, "2023107030")
	msg.strMap(15, map[string]string{
		"aid":        "1233",
		"user-agent": ua,
		"locale":     "en",
	})

	var req encoder
	req.int32(1, sn)
	req.int32(2, sn)
	req.int32(3, 5)
	req.int32(4, 1)
	req.strMap(5, map[string]string{
		"seq_id": strconv.Itoa(int(sn)),
		"cmd":    strconv.Itoa(int(cmd)),
	})
	req.msg(6, unknownType())
	req.msg(7, unknownType())
	req.msg(8, msg.b)
	return req.b
}

// unknownType is AppWsRequestUnknownType { proto14 = 98 }.
func unknownType() []byte {
	var e encoder
	e.int32(14, 98)
	return e.b
}

// buildCreateConversationBody: Type 609 body {1: 1, 2: [fromUID, toUID]}.
func buildCreateConversationBody(fromUID, toUID int64) []byte {
	var e encoder
	e.int32(1, 1)
	e.varint(2, uint64(fromUID))
	e.varint(2, uint64(toUID))
	return e.b
}

// buildPreSendBody: Type 411 body {1: convId, 2: 1, 3: shortId, 4: 3}.
func buildPreSendBody(cid *ConversationID) []byte {
	var e encoder
	e.str(1, cid.ID)
	e.int32(2, 1)
	e.varint(3, uint64(cid.ShortID))
	e.int32(4, 3)
	return e.b
}

// buildSendBody: Type 100 body with JSON content.
func buildSendBody(cid *ConversationID, msgType int, contentJSON string, ext map[string]string) []byte {
	var e encoder
	e.str(1, cid.ID)
	e.int32(2, 1)
	e.varint(3, uint64(cid.ShortID))
	e.str(4, contentJSON)
	if ext != nil {
		e.strMap(5, ext)
	}
	e.int32(6, int32(msgType))
	e.str(8, newUUID())
	e.bytes(13, nil) // EmptyObject
	e.bytes(14, nil) // EmptyObject
	return e.b
}

// buildLz4Request wraps a compressed AppImRequestMessage.
func buildLz4Request(sn int32, cmd int32, compressed []byte) []byte {
	var req encoder
	req.int32(1, sn)
	req.int32(2, 0) // Unknown1; protobuf-net writes 0 (DefaultValue -1 not equal)
	req.int32(3, 5)
	req.int32(4, 1)
	req.strMap(5, map[string]string{
		"seq_id": strconv.Itoa(int(sn)),
		"cmd":    strconv.Itoa(int(cmd)),
	})
	req.str(6, "__lz4")
	req.msg(7, unknownType())
	req.bytes(8, compressed)
	return req.b
}

// linkExtParams mirrors SetExtParams() for link/homepage cards.
func linkExtParams() map[string]string {
	return map[string]string{
		"s:push_inversion":     "1",
		"s:is_stranger":        "true",
		"s:client_message_id":  newUUID(),
		"s:biz_aid":            "1180",
		"source_aid":           "1180",
	}
}

func newUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err) // crypto/rand failure is unrecoverable
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// EscapeJSONString produces the escaped content used inside the JSON body,
// equivalent to TikTokImMessageCard.GetMessage escaping (\" and \n at minimum).
func EscapeJSONString(s string) string {
	b, _ := json.Marshal(s)
	return string(b[1 : len(b)-1])
}
