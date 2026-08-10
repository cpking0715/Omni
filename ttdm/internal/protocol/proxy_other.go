//go:build !windows

package protocol

// SystemProxy is a no-op on non-Windows platforms.
func SystemProxy() string { return "" }
