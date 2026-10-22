//go:build linux

package main

// The wire protocol, the same shapes as the macOS engine (SPEC.md). Requests
// name intent; where a value lives is this engine's business.

import (
	"bytes"
	"encoding/json"
)

// request is one input line. Fields are op-specific; unknown fields are
// ignored, absent ones stay nil and are checked per op.
type request struct {
	Op    *string `json:"op"`
	Path  *string `json:"path"`
	Blob  *string `json:"blob"`
	Value *string `json:"value"`
	Key   *string `json:"key"`  // set_meta/get_meta: groups | id | sync | comment
	Mode  *string `json:"mode"` // set_meta: add | remove | set
	By    *string `json:"by"`   // query: tag | groups | id | filename
	Name  *string `json:"name"` // per-request override of the sync name
}

// response is one output line. The fields are in key order, so a line is
// byte for byte what the macOS engine writes (it sorts its keys). Pointers
// keep an empty list ([]) apart from an absent one.
type response struct {
	Action     string    `json:"action,omitempty"`
	Blob       string    `json:"blob,omitempty"`
	Error      string    `json:"error,omitempty"`
	LastPath   string    `json:"last_path,omitempty"`
	OK         bool      `json:"ok"`
	Path       string    `json:"path,omitempty"`
	Paths      *[]string `json:"paths,omitempty"`
	Searchable *bool     `json:"searchable,omitempty"`
	Stale      bool      `json:"stale,omitempty"`
	Tags       *[]string `json:"tags,omitempty"`
	Value      *string   `json:"value,omitempty"`
	Values     *[]string `json:"values,omitempty"`
}

func failure(message string) response { return response{Error: message} }

// engineError is a per-op failure; its text goes on the wire as is.
type engineError string

func (e engineError) Error() string { return string(e) }

func missingField(f string) error { return engineError("missing required field: " + f) }
func unknownOp(o string) error    { return engineError("unknown op: " + o) }
func unknownKey(k string) error {
	return engineError("unknown meta key: " + k + " (expected groups|id|sync|comment)")
}
func unknownBy(b string) error {
	return engineError("unknown query selector: " + b + " (expected tag|groups|id|filename)")
}
func invalidMode(m string) error {
	return engineError("invalid mode: " + m + " (expected add|remove|set)")
}
func invalidValue(why string) error { return engineError("invalid value: " + why) }
func noSuchFile(p string) error     { return engineError("no such file: " + p) }

var errSyncNameNotConfigured = engineError(`sync key used but no sync name set (pass --sync-name or a per-request "name")`)

func encode(r response) string {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(r); err != nil {
		return `{"ok":false,"error":"response encoding failed"}`
	}
	return string(bytes.TrimRight(buf.Bytes(), "\n"))
}
