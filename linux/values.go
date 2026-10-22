//go:build linux

package main

// The value rules of the contract (PLATFORMS.md), as the macOS engine applies
// them: strict on write, tolerant on read and removal, stored NFC.

import (
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

type valueKind int

const (
	kindLabel valueKind = iota // tag, groups
	kindToken                  // id, sync
	kindText                   // comment
)

const (
	maxLabelBytes = 255
	maxTokenBytes = 128
	maxTextBytes  = 1024
)

// validate returns v NFC-normalized, or an invalid-value error naming the
// broken rule.
func validate(v string, kind valueKind, key string) (string, error) {
	v = norm.NFC.String(v)
	reject := func(why string) error { return invalidValue(key + " " + why) }

	if v == "" {
		return "", reject("is empty")
	}
	// A newline ends a Finder tag name on macOS, NUL ends a C string anywhere.
	for _, r := range v {
		if unicode.Is(unicode.Cc, r) && !(kind == kindText && (r == '\n' || r == '\t')) {
			return "", reject("contains a control character")
		}
	}
	switch kind {
	case kindLabel:
		// user.xdg.tags is a comma-separated list without escaping.
		if strings.Contains(v, ",") {
			return "", reject("contains a comma")
		}
		first, _ := utf8.DecodeRuneInString(v)
		last, _ := utf8.DecodeLastRuneInString(v)
		if unicode.IsSpace(first) || unicode.IsSpace(last) {
			return "", reject("has leading or trailing whitespace")
		}
		if len(v) > maxLabelBytes {
			return "", reject("is longer than 255 bytes")
		}
	case kindToken:
		if strings.IndexFunc(v, unicode.IsSpace) >= 0 {
			return "", reject("contains whitespace")
		}
		if strings.Contains(v, ",") {
			return "", reject("contains a comma")
		}
		if len(v) > maxTokenBytes {
			return "", reject("is longer than 128 bytes")
		}
	case kindText:
		// All of a file's xattrs share one block (about 4 KiB) on ext4.
		if len(v) > maxTextBytes {
			return "", reject("is longer than 1024 bytes")
		}
	}
	return v, nil
}

// tokenize splits the space-separated id value into its tokens.
func tokenize(raw string) []string { return strings.FieldsFunc(raw, unicode.IsSpace) }

// splitList reads a comma-separated list (tags, groups): entries NFC, blanks
// and surrounding spaces dropped. No stored label may carry either, so
// trimming only tolerates lists other tools wrote as "a, b".
func splitList(raw string) []string {
	out := []string{}
	for _, part := range strings.Split(raw, ",") {
		if s := strings.TrimSpace(part); s != "" {
			out = append(out, norm.NFC.String(s))
		}
	}
	return out
}

// sameText compares like Swift strings do, canonically: a value stored
// decomposed by another tool still matches its precomposed spelling.
func sameText(a, b string) bool { return norm.NFC.String(a) == norm.NFC.String(b) }
