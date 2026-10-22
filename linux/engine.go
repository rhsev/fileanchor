//go:build linux

package main

// Dispatch: one decoded request to one response, never a panic or a halt.

import (
	"encoding/json"
	"os"
	"strings"
)

type engine struct {
	syncName string
	roots    []root
	index    *walkIndex // built by the first answer that needs the walk
}

func newEngine(syncName string) *engine {
	return &engine{syncName: syncName, roots: loadRoots()}
}

// handle turns one input line into one response line (no newline).
func (e *engine) handle(line string) string {
	trimmed := strings.TrimSpace(line)
	if trimmed == "" {
		return encode(failure("empty input line"))
	}
	var req request
	if err := json.Unmarshal([]byte(trimmed), &req); err != nil || req.Op == nil {
		return encode(failure("invalid request json"))
	}
	r, err := e.dispatch(req)
	if err != nil {
		return encode(failure(err.Error()))
	}
	return encode(r)
}

func (e *engine) dispatch(req request) (response, error) {
	switch *req.Op {
	case "save":
		path, err := requireFile(req.Path)
		if err != nil {
			return response{}, err
		}
		b, err := save(path)
		if err != nil {
			return response{}, err
		}
		return response{OK: true, Blob: b}, nil

	case "resolve":
		// An unresolvable or empty blob is a valid negative, not a hard
		// error; last_path tells a gone file from one on an absent disk.
		blob := ""
		if req.Blob != nil {
			blob = *req.Blob
		}
		res, last, ok := e.resolve(blob)
		if !ok {
			r := failure("unresolvable")
			r.LastPath = last
			return r, nil
		}
		return response{OK: true, Path: res.path, Stale: res.stale}, nil

	case "tag", "untag":
		path, err := requireFile(req.Path)
		if err != nil {
			return response{}, err
		}
		value, err := require(req.Value, "value")
		if err != nil {
			return response{}, err
		}
		var action string
		if *req.Op == "tag" {
			action, err = addTag(path, value)
		} else {
			action, err = removeTag(path, value)
		}
		if err != nil {
			return response{}, err
		}
		e.noteWrite(path)
		return response{OK: true, Action: action}, nil

	case "tags":
		path, err := requireFile(req.Path)
		if err != nil {
			return response{}, err
		}
		tags, err := getTags(path)
		if err != nil {
			return response{}, err
		}
		return response{OK: true, Tags: &tags}, nil

	case "set_meta":
		path, err := requireFile(req.Path)
		if err != nil {
			return response{}, err
		}
		key, err := require(req.Key, "key")
		if err != nil {
			return response{}, err
		}
		value, err := require(req.Value, "value")
		if err != nil {
			return response{}, err
		}
		action, err := e.setMeta(path, key, value, req.Mode, req.Name)
		if err != nil {
			return response{}, err
		}
		e.noteWrite(path)
		return response{OK: true, Action: action}, nil

	case "get_meta":
		path, err := requireFile(req.Path)
		if err != nil {
			return response{}, err
		}
		key, err := require(req.Key, "key")
		if err != nil {
			return response{}, err
		}
		return e.getMeta(path, key, req.Name)

	case "query":
		by, err := require(req.By, "by")
		if err != nil {
			return response{}, err
		}
		switch by {
		case "tag", "groups", "id", "filename":
		default:
			return response{}, unknownBy(by)
		}
		value, err := require(req.Value, "value")
		if err != nil {
			return response{}, err
		}
		paths := e.query(by, value)
		return response{OK: true, Paths: &paths}, nil

	case "searchable":
		// Not requireFile: the file asked about is usually the one that is gone.
		path, err := require(req.Path, "path")
		if err != nil {
			return response{}, err
		}
		if path == "" {
			return response{}, missingField("path")
		}
		s := e.searchable(path)
		return response{OK: true, Searchable: &s}, nil
	}
	return response{}, unknownOp(*req.Op)
}

func require(field *string, name string) (string, error) {
	if field == nil {
		return "", missingField(name)
	}
	return *field, nil
}

// requireFile: getxattr cannot tell a vanished file from one without the
// attribute, so a missing file would read as "no metadata" without this.
func requireFile(field *string) (string, error) {
	path, err := require(field, "path")
	if err != nil {
		return "", err
	}
	if _, err := os.Stat(path); err != nil {
		return "", noSuchFile(path)
	}
	return path, nil
}
