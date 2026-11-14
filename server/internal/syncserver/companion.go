package syncserver

import (
	"crypto/sha256"
	"embed"
	"encoding/base64"
	"net/http"
	"regexp"
	"strings"
)

// The companion page, for phones that reach their device through the relay: the device (the
// Samsung TV app) cannot serve it itself. It is the app's own page (app/assets/companion; the
// copies here are kept the same by a test), with its sealing code and without texts or a device
// name: those come sealed in the device's first answer. Until then it says what it is waiting for
// with a few texts of its own, in every language the app has (relay-texts.json, made from the app's
// translations: see TestTheRelayTextsAreTheAppsOwn). Nothing in it is secret or personal: the room
// and the key are in the address's #fragment, which browsers never send.

//go:embed companion/index.html companion/seal.js companion/relay-texts.json
var companionFiles embed.FS

var companionPage, companionPolicy = buildCompanion()

// The Inter fonts the device serves next to the page: not here, where system fonts take over
var fontFaces = regexp.MustCompile(`(?m)^[ \t]*@font-face[^\n]*\n`)

var inlineScripts = regexp.MustCompile(`(?s)<script(?: [^>]*)?>(.*?)</script>`)

func buildCompanion() ([]byte, string) {
	read := func(name string) string {
		b, err := companionFiles.ReadFile("companion/" + name)
		if err != nil {
			panic(err)
		}
		return string(b)
	}
	page := read("index.html")
	for _, r := range [][2]string{
		{"/*SEAL*/", read("seal.js")},
		{"/*STRINGS*/{}", "{}"},
		{`/*DEVICE*/""`, `""`},
		{"/*RELAY_TEXTS*/{}", strings.TrimSpace(read("relay-texts.json"))},
	} {
		if !strings.Contains(page, r[0]) {
			panic("companion page without " + r[0])
		}
		page = strings.Replace(page, r[0], r[1], 1)
	}
	page = fontFaces.ReplaceAllString(page, "")
	// Only its own scripts run: by their hashes, as they are inline
	scripts := ""
	for _, m := range inlineScripts.FindAllStringSubmatch(page, -1) {
		sum := sha256.Sum256([]byte(m[1]))
		scripts += " 'sha256-" + base64.StdEncoding.EncodeToString(sum[:]) + "'"
	}
	policy := "default-src 'none'; script-src" + scripts + "; style-src 'unsafe-inline'; img-src * data: blob:; " +
		"connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
	// Cloudflare's Rocket Loader rewrites scripts to load them its own way, with a script of its own
	// the policy above blocks: the page would stay blank. It leaves these alone
	page = strings.ReplaceAll(page, "<script>", `<script data-cfasync="false">`)
	return []byte(page), policy
}

func companion(w http.ResponseWriter, _ *http.Request) {
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Content-Security-Policy", companionPolicy)
	// no-transform: proxies such as Cloudflare must not rewrite it (its scripts are allowed by hash)
	h.Set("Cache-Control", "no-cache, no-transform")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Content-Type-Options", "nosniff")
	w.Write(companionPage)
}
