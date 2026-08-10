//go:build windows

package protocol

import (
	"strings"

	"golang.org/x/sys/windows/registry"
)

// SystemProxy returns the Windows Internet Settings proxy (e.g. Clash),
// or "" when none is configured. Go's websocket dialer does not use the
// OS proxy automatically, but browsers do — matching it keeps the account
// egress consistent with the AdsPower environment.
func SystemProxy() string {
	k, err := registry.OpenKey(registry.CURRENT_USER,
		`Software\Microsoft\Windows\CurrentVersion\Internet Settings`, registry.QUERY_VALUE)
	if err != nil {
		return ""
	}
	defer k.Close()

	enable, _, err := k.GetIntegerValue("ProxyEnable")
	if err != nil || enable == 0 {
		return ""
	}
	server, _, err := k.GetStringValue("ProxyServer")
	if err != nil {
		return ""
	}
	for _, part := range strings.Split(server, ";") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if v, ok := strings.CutPrefix(part, "http="); ok {
			return "http://" + v
		}
		if v, ok := strings.CutPrefix(part, "https="); ok {
			return "http://" + v
		}
	}
	if !strings.Contains(server, "=") {
		return "http://" + server
	}
	return ""
}
