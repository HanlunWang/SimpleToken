package gui

import (
	_ "embed"
	"encoding/json"
	"strings"
	"sync"

	"github.com/HanlunWang/SimpleToken/internal/format"
)

// The translations are a String Catalog (English keys, Simplified Chinese values), embedded as is. It began as the
// Swift app's App/Localizable.xcstrings and is the Go app's own now.
//
//go:embed i18n/Localizable.xcstrings
var catalogJSON []byte

var (
	catOnce sync.Once
	catZh   map[string]string
	langZh  bool
)

func loadCatalog() {
	catOnce.Do(func() {
		var c struct {
			Strings map[string]struct {
				Localizations map[string]struct {
					StringUnit struct {
						Value string `json:"value"`
					} `json:"stringUnit"`
				} `json:"localizations"`
			} `json:"strings"`
		}
		catZh = map[string]string{}
		if json.Unmarshal(catalogJSON, &c) != nil {
			return
		}
		for k, v := range c.Strings {
			if z, ok := v.Localizations["zh-Hans"]; ok && z.StringUnit.Value != "" {
				catZh[k] = z.StringUnit.Value
			}
		}
	})
}

// setLanguage switches the UI language ("zh…" is Simplified Chinese, anything else English).
func setLanguage(locale string) {
	loadCatalog()
	langZh = strings.HasPrefix(strings.ToLower(locale), "zh")
	fmtr = format.Formatter{CJKUnits: langZh, Translate: translate}
}

func translate(key string) string {
	if !langZh {
		return ""
	}
	return catZh[key]
}

// L renders a catalog string with its arguments (%lld, %@, %lf as in the String Catalog).
func L(key string, args ...any) string { return fmtr.L(format.T(key, args...)) }
