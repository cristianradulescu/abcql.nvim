// Command abcql-backend executes a single SQL query against a database and
// prints a JSON result. It is designed to be used both by abcql.nvim (spawned
// as a one-shot subprocess per query) and standalone from a shell:
//
//	echo '{"engine":"mysql","host":"127.0.0.1","port":3306,"user":"root",
//	       "database":"shop","sql":"select 1"}' | abcql-backend exec
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
)

// version is overridable at build time via -ldflags "-X main.version=...".
var version = "dev"

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: abcql-backend <exec|version>")
		os.Exit(2)
	}

	switch os.Args[1] {
	case "version":
		fmt.Println("abcql-backend " + version)
	case "exec":
		os.Exit(runExec(os.Stdin, os.Stdout))
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", os.Args[1])
		os.Exit(2)
	}
}

// runExec reads a Request from in, executes it, and writes a Response to
// out. It returns the process exit code (0 on success, 1 on failure) instead
// of calling os.Exit itself, so it can be exercised from tests.
func runExec(in io.Reader, out io.Writer) int {
	body, err := io.ReadAll(in)
	if err != nil {
		writeResponse(out, &Response{Error: "failed to read request: " + err.Error()})
		return 1
	}

	var req Request
	if err := json.Unmarshal(body, &req); err != nil {
		writeResponse(out, &Response{Error: "failed to parse request JSON: " + err.Error()})
		return 1
	}

	if req.Engine != "" && req.Engine != "mysql" {
		writeResponse(out, &Response{Error: fmt.Sprintf("unsupported engine %q", req.Engine)})
		return 1
	}

	resp, err := execRequest(&req)
	if err != nil {
		writeResponse(out, &Response{Error: err.Error()})
		return 1
	}

	writeResponse(out, resp)
	return 0
}

func writeResponse(out io.Writer, resp *Response) {
	enc := json.NewEncoder(out)
	if err := enc.Encode(resp); err != nil {
		// Last resort: nothing more we can do if even the error can't be
		// marshaled.
		fmt.Fprintln(os.Stderr, "abcql-backend: failed to encode response:", err)
	}
}
