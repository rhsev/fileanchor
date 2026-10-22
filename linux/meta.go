//go:build linux

package main

// Tags and the four meta keys, stored as user.* attributes (PLATFORMS.md):
//
//	tag      user.xdg.tags           comma-separated, the freedesktop list Dolphin reads
//	groups   user.fileanchor.groups  comma-separated
//	id       user.fileanchor.id      space-separated tokens
//	sync     user.<sync name>        one token; the macOS flag (#S) dropped
//	comment  user.xdg.comment        plain UTF-8
//
// The semantics are the macOS engine's: writes are idempotent, an empty set
// deletes, removal takes any value that is there, reads come back NFC.

import (
	"strings"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

type metaKey struct {
	attr  string
	kind  valueKind
	list  bool // comma-separated list (groups)
	multi bool // space-separated tokens (id)
}

// syncAttr maps the consumer's sync name to its attribute. "#S" marks an
// attribute iCloud and AirDrop keep; it is part of the name on macOS and
// meaningless here, so a trailing flag of letters after # is dropped.
func syncAttr(name string) string {
	if i := strings.LastIndexByte(name, '#'); i > 0 {
		flag := name[i+1:]
		letters := flag != ""
		for _, c := range flag {
			if !('A' <= c && c <= 'Z' || 'a' <= c && c <= 'z') {
				letters = false
			}
		}
		if letters {
			name = name[:i]
		}
	}
	if !strings.HasPrefix(name, "user.") {
		name = "user." + name
	}
	return name
}

func (e *engine) metaKey(key string, requestName *string) (metaKey, error) {
	switch key {
	case "groups":
		return metaKey{attr: groupsAttr, kind: kindLabel, list: true}, nil
	case "id":
		return metaKey{attr: idAttr, kind: kindToken, multi: true}, nil
	case "comment":
		return metaKey{attr: commentAttr, kind: kindText}, nil
	case "sync":
		name := e.syncName
		if requestName != nil {
			name = *requestName
		}
		if name == "" {
			return metaKey{}, errSyncNameNotConfigured
		}
		return metaKey{attr: syncAttr(name), kind: kindToken}, nil
	}
	return metaKey{}, unknownKey(key)
}

// readString reads an attribute as text, "" when absent.
func readString(path, attr string) (string, bool, error) {
	data, ok, err := getAttr(path, attr)
	return string(data), ok, err
}

func readList(path, attr string) ([]string, error) {
	raw, _, err := readString(path, attr)
	if err != nil {
		return nil, err
	}
	return splitList(raw), nil
}

func readTokens(path, attr string) ([]string, error) {
	raw, _, err := readString(path, attr)
	if err != nil {
		return nil, err
	}
	out := tokenize(raw)
	if out == nil {
		out = []string{}
	}
	return out, nil
}

// writeList stores a list, deleting the attribute when it empties.
func writeList(path, attr string, items []string, sep string) error {
	if len(items) == 0 {
		return removeAttr(path, attr)
	}
	return setAttr(path, attr, []byte(strings.Join(items, sep)))
}

// clear deletes an attribute: "removed", or "noop" when it was not there.
func clear(path, attr string) (string, error) {
	_, ok, err := getAttr(path, attr)
	if err != nil {
		return "", err
	}
	if !ok {
		return "noop", nil
	}
	if err := removeAttr(path, attr); err != nil {
		return "", err
	}
	return "removed", nil
}

func contains(items []string, v string) bool {
	for _, it := range items {
		if sameText(it, v) {
			return true
		}
	}
	return false
}

func without(items []string, v string) []string {
	out := []string{}
	for _, it := range items {
		if !sameText(it, v) {
			out = append(out, it)
		}
	}
	return out
}

func getTags(path string) ([]string, error) { return readList(path, tagsAttr) }

func addTag(path, value string) (string, error) {
	value, err := validate(value, kindLabel, "tag")
	if err != nil {
		return "", err
	}
	tags, err := readList(path, tagsAttr)
	if err != nil {
		return "", err
	}
	if contains(tags, value) {
		return "noop", nil
	}
	if err := writeList(path, tagsAttr, append(tags, value), ","); err != nil {
		return "", err
	}
	return "added", nil
}

func removeTag(path, value string) (string, error) {
	tags, err := readList(path, tagsAttr)
	if err != nil {
		return "", err
	}
	if !contains(tags, value) {
		return "noop", nil
	}
	if err := writeList(path, tagsAttr, without(tags, value), ","); err != nil {
		return "", err
	}
	return "removed", nil
}

// getMeta: the lists come back as values, sync and comment as value (left
// out when absent).
func (e *engine) getMeta(path, key string, requestName *string) (response, error) {
	k, err := e.metaKey(key, requestName)
	if err != nil {
		return response{}, err
	}
	r := response{OK: true}
	switch {
	case k.list:
		vals, err := readList(path, k.attr)
		if err != nil {
			return response{}, err
		}
		r.Values = &vals
	case k.multi:
		vals, err := readTokens(path, k.attr)
		if err != nil {
			return response{}, err
		}
		r.Values = &vals
	default:
		raw, _, err := readString(path, k.attr)
		if err != nil {
			return response{}, err
		}
		if raw != "" {
			v := norm.NFC.String(raw)
			r.Value = &v
		}
	}
	return r, nil
}

// setMeta writes a value. Lists and tokens: add appends idempotently, remove
// drops one (deleting the attribute when it empties), set replaces the whole
// value (for id a space-separated list). Single values: add and set write,
// remove deletes. An empty set deletes on every key.
func (e *engine) setMeta(path, key, value string, mode *string, requestName *string) (string, error) {
	k, err := e.metaKey(key, requestName)
	if err != nil {
		return "", err
	}
	m := "add"
	if mode != nil {
		m = *mode
	}

	// Only what gets written is validated: an empty set is a delete, and
	// removal takes any value that is there.
	if (m == "add" || m == "set") && value != "" {
		if k.multi && m == "set" {
			var toks []string
			for _, t := range tokenize(value) {
				v, err := validate(t, kindToken, key)
				if err != nil {
					return "", err
				}
				toks = append(toks, v)
			}
			value = strings.Join(toks, " ")
		} else {
			if value, err = validate(value, k.kind, key); err != nil {
				return "", err
			}
		}
	}

	switch {
	case k.list || k.multi:
		var current []string
		sep := ","
		if k.list {
			current, err = readList(path, k.attr)
		} else {
			sep = " "
			current, err = readTokens(path, k.attr)
			// No stored token holds whitespace, so removing one that does is
			// a caller error, not a noop.
			if m == "remove" && strings.IndexFunc(value, unicode.IsSpace) >= 0 {
				return "", invalidValue(key + " token contains whitespace")
			}
		}
		if err != nil {
			return "", err
		}
		switch m {
		case "add":
			if contains(current, value) {
				return "noop", nil
			}
			if err := writeList(path, k.attr, append(current, value), sep); err != nil {
				return "", err
			}
			return "added", nil
		case "remove":
			if !contains(current, value) {
				return "noop", nil
			}
			if err := writeList(path, k.attr, without(current, value), sep); err != nil {
				return "", err
			}
			return "removed", nil
		case "set":
			replacement := []string{value}
			if k.multi {
				replacement = tokenize(value)
			}
			if value == "" || len(replacement) == 0 {
				return clear(path, k.attr)
			}
			if equalLists(current, replacement) {
				return "noop", nil
			}
			if err := writeList(path, k.attr, replacement, sep); err != nil {
				return "", err
			}
			return "set", nil
		}
		return "", invalidMode(m)

	default:
		switch m {
		case "add", "set":
			if value == "" {
				return clear(path, k.attr)
			}
			current, ok, err := readString(path, k.attr)
			if err != nil {
				return "", err
			}
			if ok && sameText(current, value) {
				return "noop", nil
			}
			if err := setAttr(path, k.attr, []byte(value)); err != nil {
				return "", err
			}
			return "set", nil
		case "remove":
			return clear(path, k.attr)
		}
		return "", invalidMode(m)
	}
}

func equalLists(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if !sameText(a[i], b[i]) {
			return false
		}
	}
	return true
}
