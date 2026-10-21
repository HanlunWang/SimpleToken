package limits

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCredentialStore(t *testing.T) {
	dir := t.TempDir()
	c := &CredentialStore{Path: filepath.Join(dir, "data", "credentials.json"), LegacyPath: filepath.Join(dir, "legacy.json")}
	if f := c.Load(); f.ClaudeWebCookie != "" || f.Version != 1 {
		t.Fatalf("missing file: %+v", f)
	}
	if err := c.SetClaudeCookie("sk-ant-test"); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(c.Path)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", st.Mode().Perm())
	}
	data, _ := os.ReadFile(c.Path)
	if string(data) != `{"version":1,"claudeWebCookie":"sk-ant-test"}` {
		t.Fatalf("file: %s", data)
	}
	if c.ClaudeCookie() != "sk-ant-test" {
		t.Fatal("round trip")
	}
	// A cookie is present: the legacy file is not consulted.
	if err := os.WriteFile(c.LegacyPath, []byte(`{"credentials":{"providers":{"claude":{"webCookie":"sk-ant-legacy"}}}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if c.ImportLegacyIfMissing() || c.ClaudeCookie() != "sk-ant-test" {
		t.Fatal("imported over an existing cookie")
	}
	// Removed: the one-time import fills it.
	if err := c.SetClaudeCookie(""); err != nil {
		t.Fatal(err)
	}
	if !c.ImportLegacyIfMissing() || c.ClaudeCookie() != "sk-ant-legacy" {
		t.Fatal("legacy import")
	}
	entries, _ := os.ReadDir(filepath.Dir(c.Path))
	if len(entries) != 1 {
		t.Fatalf("leftover temp files: %d entries", len(entries))
	}
	// A Swift-written file reads back.
	if err := os.WriteFile(c.Path, []byte(`{"claudeWebCookie":"sk-ant-swift","version":1}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if c.ClaudeCookie() != "sk-ant-swift" {
		t.Fatal("swift file")
	}
}
