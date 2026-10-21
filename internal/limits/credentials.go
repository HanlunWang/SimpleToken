package limits

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"

	"github.com/HanlunWang/SimpleToken/internal/paths"
)

// CredentialFile is credentials.json. It keeps the owner-pasted Claude sessionKey in plain JSON with mode 0600:
// no Keychain prompts, and no defence against processes already running as the same user (the same trade-off
// as before). The Store writes rotated keys back.
type CredentialFile struct {
	Version         int    `json:"version"`
	ClaudeWebCookie string `json:"claudeWebCookie,omitempty"`
}

// CredentialStore reads and writes the credential file. Safe for concurrent use within the process.
type CredentialStore struct {
	// Path is credentials.json; LegacyPath the Electron Token Monitor's file, imported once.
	Path       string
	LegacyPath string
	mu         sync.Mutex
}

// NewCredentialStore uses the standard locations (paths.Credentials, paths.LegacyCredentials).
func NewCredentialStore() *CredentialStore {
	return &CredentialStore{Path: paths.Credentials(), LegacyPath: paths.LegacyCredentials()}
}

// Load returns the file, or an empty one when it is missing or unreadable.
func (c *CredentialStore) Load() CredentialFile {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.load()
}

func (c *CredentialStore) load() CredentialFile {
	f := CredentialFile{Version: 1}
	data, err := os.ReadFile(c.Path)
	if err != nil {
		return f
	}
	if err := json.Unmarshal(data, &f); err != nil {
		return CredentialFile{Version: 1}
	}
	if f.Version == 0 {
		f.Version = 1
	}
	return f
}

// Save writes the file atomically with mode 0600.
func (c *CredentialStore) Save(f CredentialFile) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.save(f)
}

func (c *CredentialStore) save(f CredentialFile) error {
	if f.Version == 0 {
		f.Version = 1
	}
	data, err := json.Marshal(f)
	if err != nil {
		return err
	}
	dir := filepath.Dir(c.Path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".credentials-*.json") // created 0600
	if err != nil {
		return err
	}
	name := tmp.Name()
	_, werr := tmp.Write(data)
	cerr := tmp.Close()
	if werr != nil || cerr != nil {
		_ = os.Remove(name)
		if werr != nil {
			return werr
		}
		return cerr
	}
	if err := os.Chmod(name, 0o600); err != nil {
		_ = os.Remove(name)
		return err
	}
	if err := os.Rename(name, c.Path); err != nil {
		_ = os.Remove(name)
		return err
	}
	return os.Chmod(c.Path, 0o600)
}

// ClaudeCookie is the stored sessionKey ("" when none).
func (c *CredentialStore) ClaudeCookie() string { return c.Load().ClaudeWebCookie }

// SetClaudeCookie stores (or, with "", removes) the sessionKey, keeping the rest of the file.
func (c *CredentialStore) SetClaudeCookie(key string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	f := c.load()
	f.ClaudeWebCookie = key
	return c.save(f)
}

// ImportLegacyIfMissing copies the Token Monitor's Claude webCookie once, only while no cookie is stored (the
// owner approved this migration). It reports whether a cookie was imported.
func (c *CredentialStore) ImportLegacyIfMissing() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	current := c.load()
	if current.ClaudeWebCookie != "" || c.LegacyPath == "" {
		return false
	}
	data, err := os.ReadFile(c.LegacyPath)
	if err != nil {
		return false
	}
	root, ok := decodeObject(data)
	if !ok {
		return false
	}
	cookie, ok := str(object(object(object(root["credentials"])["providers"])["claude"])["webCookie"])
	if !ok || cookie == "" {
		return false
	}
	current.ClaudeWebCookie = cookie
	return c.save(current) == nil
}
