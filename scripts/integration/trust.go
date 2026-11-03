// Run in the pinned snapd module. Its public system-test root is never copied
// into the application or used outside the disposable VM.
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/snapcore/snapd/asserts"
	"github.com/snapcore/snapd/asserts/assertstest"
	"github.com/snapcore/snapd/asserts/systestkeys"
)

func run() error {
	request, err := os.ReadFile(os.Args[1])
	if err != nil {
		return err
	}
	a, err := asserts.Decode(request)
	if err != nil {
		return err
	}
	public, err := asserts.DecodePublicKey(a.Body())
	if err != nil {
		return err
	}
	root, _ := assertstest.ReadPrivKey(systestkeys.TestRootPrivKey)
	db := assertstest.NewSigningDB("testrootorg", root)
	account := assertstest.NewAccount(db, "developer1", map[string]any{
		"account-id": "developer1",
	}, "")
	key := assertstest.NewAccountKey(db, account, map[string]any{
		"name":  "integration",
		"since": "2016-01-01T00:00:00Z",
	}, public, "")
	for name, assertion := range map[string]asserts.Assertion{"account": account, "account-key": key} {
		if err := os.WriteFile(filepath.Join(os.Args[2], name), asserts.Encode(assertion), 0600); err != nil {
			return err
		}
	}
	return nil
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: trust key-request output-directory")
		os.Exit(2)
	}
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
