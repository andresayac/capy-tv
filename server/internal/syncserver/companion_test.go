package syncserver

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The copies served here are the app's own page: go:embed cannot reach outside this module.
func TestTheCompanionPageIsTheAppsOwn(t *testing.T) {
	for _, name := range []string{"index.html", "seal.js"} {
		app, err := os.ReadFile("../../../app/assets/companion/" + name)
		if errors.Is(err, fs.ErrNotExist) {
			t.Skip("the app is not next to the server (only server/ was copied)")
		}
		if err != nil {
			t.Fatal(err)
		}
		copied, _ := companionFiles.ReadFile("companion/" + name)
		if !bytes.Equal(app, copied) {
			t.Errorf("internal/syncserver/companion/%s differs from app/assets/companion/%s: copy it over", name, name)
		}
	}
}

// The page's own texts, for while it waits for the device (which sends all the others), by their
// name in the page and their key in the app's translations
var relayTextKeys = map[string]string{"waiting": "webRelayWaiting", "noAnswer": "webRelayNoAnswer", "expired": "webRelayExpired"}

// relay-texts.json is made from the app's translations, so each text is translated once. After
// changing them: UPDATE_RELAY_TEXTS=1 go test -run TestTheRelayTextsAreTheAppsOwn ./internal/syncserver
func TestTheRelayTextsAreTheAppsOwn(t *testing.T) {
	files, err := filepath.Glob("../../../app/lib/l10n/app_*.arb")
	if err != nil || len(files) == 0 {
		t.Skip("the app is not next to the server (only server/ was copied)")
	}
	all := map[string]map[string]string{}
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		var arb map[string]any
		if err := json.Unmarshal(b, &arb); err != nil {
			t.Fatalf("%s: %v", f, err)
		}
		texts := map[string]string{}
		for name, key := range relayTextKeys {
			s, ok := arb[key].(string)
			if !ok || s == "" {
				t.Fatalf("%s has no %s", f, key)
			}
			texts[name] = s
		}
		all[strings.TrimSuffix(strings.TrimPrefix(filepath.Base(f), "app_"), ".arb")] = texts
	}
	want, _ := json.Marshal(all) // keys in order, and "<" escaped: it goes inside a <script>
	want = append(want, '\n')
	if os.Getenv("UPDATE_RELAY_TEXTS") != "" {
		if err := os.WriteFile("companion/relay-texts.json", want, 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	got, _ := companionFiles.ReadFile("companion/relay-texts.json")
	if !bytes.Equal(got, want) {
		t.Errorf("companion/relay-texts.json is not what the app's translations say: " +
			"UPDATE_RELAY_TEXTS=1 go test -run TestTheRelayTextsAreTheAppsOwn ./internal/syncserver")
	}
}

func TestTheCompanionPageComesForTheRelay(t *testing.T) {
	srv := start(t, false)

	res, err := http.Get(srv.url + "/companion")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != 200 || !strings.HasPrefix(res.Header.Get("Content-Type"), "text/html") {
		t.Fatalf("got %d %s", res.StatusCode, res.Header.Get("Content-Type"))
	}
	page := string(body)
	for _, want := range []string{"const Seal", "let STRINGS = {};", `let DEVICE = "";`, "relay/tv"} {
		if !strings.Contains(page, want) {
			t.Errorf("the page lacks %s", want)
		}
	}
	if !strings.Contains(page, `const RELAY_TEXTS = {"en":{`) || !strings.Contains(page, `"es":{`) {
		t.Errorf("the page lacks its own texts for while it waits for the device")
	}
	for _, unwanted := range []string{"/*SEAL*/", "/*STRINGS*/", "/*DEVICE*/", "/*RELAY_TEXTS*/", "/fonts/"} {
		if strings.Contains(page, unwanted) {
			t.Errorf("the page still has %s", unwanted)
		}
	}

	// Its policy lets exactly its own two scripts run
	policy := res.Header.Get("Content-Security-Policy")
	scripts := inlineScripts.FindAllStringSubmatch(page, -1)
	expect(t, "inline scripts", len(scripts), 2)
	for _, m := range scripts {
		sum := sha256.Sum256([]byte(m[1]))
		if hash := "'sha256-" + base64.StdEncoding.EncodeToString(sum[:]) + "'"; !strings.Contains(policy, hash) {
			t.Errorf("the policy does not allow a script of the page: %s", policy)
		}
	}
	for _, want := range []string{"default-src 'none'", "connect-src 'self'", "frame-ancestors 'none'"} {
		if !strings.Contains(policy, want) {
			t.Errorf("the policy lacks %s: %s", want, policy)
		}
	}
	expect(t, "referrer", res.Header.Get("Referrer-Policy"), "no-referrer")

	// Behind Cloudflare: no Rocket Loader, whose script the policy would block
	expect(t, "cache", res.Header.Get("Cache-Control"), "no-cache, no-transform")
	expect(t, "scripts left alone", strings.Count(page, `<script data-cfasync="false">`), 2)
}
