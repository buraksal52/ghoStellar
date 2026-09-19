// Package envx is the tiny environment-variable reader shared by every
// service's cmd/<svc>/main.go. Contract: an empty value for an optional
// dependency disables that feature and the service falls back to a simpler
// implementation (docs/reference/platform/architecture.md §4.6) — nothing
// here panics on a missing optional value.
package envx

import (
	"os"
	"strconv"
)

// Get returns the environment variable's value, or fallback if unset/empty.
func Get(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// GetInt returns the environment variable parsed as an int, or fallback if
// unset/empty/unparseable.
func GetInt(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return fallback
	}
	return n
}

// MustGet returns the environment variable's value, or panics at boot if
// unset — reserved for values with no safe fallback (e.g. a signing key
// path), never for the optional-dependency values Get covers.
func MustGet(key string) string {
	v := os.Getenv(key)
	if v == "" {
		panic("envx: required environment variable " + key + " is not set")
	}
	return v
}
