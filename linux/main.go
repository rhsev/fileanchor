//go:build linux

// fileanchor for Linux: the batch stdio metadata engine of SPEC.md, built on
// user.* extended attributes and on file identity by file system, inode and
// generation (PLATFORMS.md). One JSON request per stdin line, one JSON
// response per stdout line, in input order. The process handles a batch and
// exits; it is not a daemon.
//
// Usage:
//
//	fileanchor [--sync-name <xattr-name>]
//	fileanchor --version
//
// --sync-name sets the default name for the single-valued cross-device `sync`
// key (fileregister passes com.fileregister.id#S). A per-request "name" field
// overrides it. The macOS flag suffix (#S) is dropped and the rest stored under
// user.; groups, id, tags and comment map to fixed names.
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"
)

// version is stamped from the git tag by `make linux`; a plain `go build`
// says dev.
var version = "dev"

// Anything else on the command line is refused at startup: a typo like
// --sync_name would otherwise pass silently and only surface later, as a
// confusing "no sync name set" on the first sync op.
func usageError(message string) {
	fmt.Fprintf(os.Stderr, "fileanchor: %s\nusage: fileanchor [--sync-name <xattr-name>] | --version\n", message)
	os.Exit(2)
}

func parseSyncName(args []string) string {
	syncName := ""
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "--version" || arg == "-v":
			fmt.Printf("fileanchor %s\n", version)
			os.Exit(0)
		case arg == "--sync-name":
			if i+1 >= len(args) {
				usageError("--sync-name needs a value")
			}
			i++
			syncName = args[i]
		case strings.HasPrefix(arg, "--sync-name="):
			syncName = strings.TrimPrefix(arg, "--sync-name=")
		default:
			usageError("unknown argument: " + arg)
		}
	}
	return syncName
}

func main() {
	e := newEngine(parseSyncName(os.Args[1:]))
	in := bufio.NewReaderSize(os.Stdin, 64*1024)
	out := bufio.NewWriter(os.Stdout)
	// Read, handle, write, line by line. Flush after every response so a
	// consumer holding a persistent pipe never waits on a buffered answer.
	for {
		line, err := in.ReadString('\n')
		if err != nil && err != io.EOF {
			fmt.Fprintf(os.Stderr, "fileanchor: reading stdin: %v\n", err)
			os.Exit(1)
		}
		if err == io.EOF && line == "" {
			return
		}
		out.WriteString(e.handle(line))
		out.WriteByte('\n')
		if ferr := out.Flush(); ferr != nil {
			os.Exit(1)
		}
		if err == io.EOF {
			return
		}
	}
}
