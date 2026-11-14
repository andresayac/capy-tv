package syncserver

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// linkServer serves a release made of files, on a test clock.
func linkServer(t *testing.T, files map[string]string, c Config) *relayServer {
	dir := t.TempDir()
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	c.SignInsPerMinute, c.AppDir = 10, dir
	return startRelay(t, time.Second, c)
}

var bothFiles = map[string]string{
	"app.json": manifest, "CapyTV-64bit.apk": "sixty-four", "CapyTV-32bit.apk": "thirty-two",
}

// link asks for an install link as a signed-in device does.
func (s *relayServer) link(token string) string {
	s.Helper()
	status, body := s.call("POST", "/v1/app/link", nil, token)
	if status != 201 {
		s.Fatalf("link: %d %v", status, body)
	}
	return body["code"].(string)
}

type fetched struct {
	status int
	header http.Header
	body   string
}

// fetch is a GET without a session, as a browser sends it, with headers in pairs.
func (s *relayServer) fetch(path string, headers ...string) fetched {
	s.Helper()
	req, _ := http.NewRequest("GET", s.url+path, nil)
	for i := 0; i+1 < len(headers); i += 2 {
		req.Header.Set(headers[i], headers[i+1])
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		s.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	return fetched{res.StatusCode, res.Header, string(body)}
}

func TestAnInstallLinkIsAPageAndTheAPKsWithoutASession(t *testing.T) {
	s := linkServer(t, bothFiles, Config{})
	token := s.signUp("a@example.com")

	status, body := s.call("POST", "/v1/app/link", nil, token)
	expect(t, "made", status, 201)
	code := body["code"].(string)
	expect(t, "five characters", len(code), linkLength)
	expect(t, "of the alphabet", strings.Trim(code, linkAlphabet), "")
	expect(t, "for half an hour", body["expires"], any("2026-11-06T12:30:00.000Z"))
	status, _ = s.call("POST", "/v1/app/link", nil, "")
	expect(t, "made by signed-in devices only", status, 401)

	page := s.fetch("/i/" + code)
	expect(t, "page", page.status, 200)
	expect(t, "html", page.header.Get("Content-Type"), "text/html; charset=utf-8")
	expect(t, "never cached", page.header.Get("Cache-Control"), "private, no-store, no-transform")
	for _, want := range []string{
		"Capy TV", "Version 0.2.0 (412)",
		`<a href="` + code + `/arm64-v8a">Phones and tablets (64-bit)`,
		`<a href="` + code + `/armeabi-v7a">Fire TV, TVs and Android boxes (32-bit)`,
		"If it does not install, try the other one.",
		"This link works for 30 more minutes.",
	} {
		expect(t, "the page has "+want, strings.Contains(page.body, want), true)
	}
	expect(t, "64-bit first", strings.Index(page.body, "arm64-v8a") < strings.Index(page.body, "armeabi-v7a"), true)
	expect(t, "nothing from elsewhere", strings.Contains(page.body, "://"), false)
	expect(t, "nor scripts", strings.Contains(page.body, "<script"), false)
	expect(t, "in any case", s.fetch("/i/"+strings.ToLower(code)).status, 200)
	capitals := s.fetch("/I/" + code)
	expect(t, "typed in capitals", capitals.status, 200)
	expect(t, "the same page", capitals.body, page.body)
	expect(t, "with its files", s.fetch("/I/"+code+"/armeabi-v7a").body, "thirty-two")
	expect(t, "a slash at the end", s.fetch("/i/"+code+"/").body, page.body)
	noFollow := http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	res, err := noFollow.Get(s.url + "/I/" + code + "/")
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	expect(t, "is taken away", res.StatusCode, http.StatusFound)
	expect(t, "relative, as the links", res.Header.Get("Location"), "../"+code)

	apk := s.fetch("/i/" + strings.ToLower(code) + "/armeabi-v7a")
	expect(t, "download", apk.status, 200)
	expect(t, "content", apk.body, "thirty-two")
	expect(t, "an APK", apk.header.Get("Content-Type"), "application/vnd.android.package-archive")
	expect(t, "named", apk.header.Get("Content-Disposition"), `attachment; filename="CapyTV-32bit.apk"`)
	expect(t, "never cached by a CDN", apk.header.Get("Cache-Control"), "private, no-store")
	rest := s.fetch("/i/"+code+"/arm64-v8a", "Range", "bytes=6-")
	expect(t, "a cut download goes on", rest.status, http.StatusPartialContent)
	expect(t, "rest", rest.body, "four")

	for _, path := range []string{"/i/" + code + "/x86_64", "/i/" + code + "/CapyTV-32bit.apk", "/i/" + code + "/..%2Fapp.json"} {
		missing := s.fetch(path)
		expect(t, path, missing.status, 404)
		expect(t, path+": a page", strings.Contains(missing.body, "Link not found"), true)
	}
}

func TestOneLinkForAUniversalRelease(t *testing.T) {
	s := linkServer(t, map[string]string{
		"app.json": `{"version": "0.3.0", "build": 500, "files": {"universal": "CapyTV.apk"}}`, "CapyTV.apk": "for all",
	}, Config{})
	code := s.link(s.signUp("a@example.com"))
	page := s.fetch("/i/" + code)
	expect(t, "one link", strings.Count(page.body, "<a "), 1)
	expect(t, "for all", strings.Contains(page.body, `<a href="`+code+`/universal">Download Capy TV`), true)
	expect(t, "the file", s.fetch("/i/"+code+"/universal").body, "for all")
}

func TestOtherProcessorsComeLastByTheirNames(t *testing.T) {
	s := linkServer(t, map[string]string{
		"app.json": `{"build": 7, "files": {"x86_64": "x64.apk", "universal": "all.apk", "x86": "x86.apk", "arm64-v8a": "64.apk"}}`,
		"x64.apk":  "a", "all.apk": "b", "x86.apk": "c", "64.apk": "d",
	}, Config{})
	code := s.link(s.signUp("a@example.com"))
	page := s.fetch("/i/" + code).body
	var order []string
	for _, part := range strings.Split(page, `<a href="`+code+"/")[1:] {
		abi, _, _ := strings.Cut(part, `"`)
		order = append(order, abi)
	}
	expect(t, "order", strings.Join(order, " "), "arm64-v8a universal x86 x86_64")
	expect(t, "by its name", strings.Contains(page, `/x86_64">x86_64<span>`), true)
	expect(t, "the build when there is no version", strings.Contains(page, "Version 7 (7)"), true)
}

func TestInstallLinksEndAfterHalfAnHour(t *testing.T) {
	s := linkServer(t, bothFiles, Config{})
	code := s.link(s.signUp("a@example.com"))
	s.clock.add(29 * time.Minute)
	page := s.fetch("/i/" + code)
	expect(t, "still", page.status, 200)
	expect(t, "a minute left", strings.Contains(page.body, "This link works for 1 more minute."), true)
	s.clock.add(time.Minute)
	gone := s.fetch("/i/" + code)
	expect(t, "ended", gone.status, 404)
	expect(t, "a short page", strings.Contains(gone.body, "<h1>Link not found</h1>"), true)
	expect(t, "that says why", strings.Contains(gone.body, "or has expired. Get a new one in Capy TV"), true)
	expect(t, "not cached either", gone.header.Get("Cache-Control"), "private, no-store, no-transform")
	expect(t, "nor its files", s.fetch("/i/"+code+"/arm64-v8a").status, 404)
}

func TestThePageSpeaksTheBrowsersLanguage(t *testing.T) {
	for header, want := range map[string]string{
		"":                               "en",
		"es":                             "es",
		"es-ES,es;q=0.9,en;q=0.8":        "es",
		"en-US,en;q=0.9,es;q=0.5":        "en",
		"fr-FR, es;q=0.5":                "es",
		"fr":                             "en",
		"en;q=0.2, ES-419;q=0.7":         "es",
		"es;q=0, en;q=0.1":               "en",
		"de;q=0.9, es;q=garbage, en;q=1": "en",
	} {
		expect(t, fmt.Sprintf("%q", header), pageLanguage(header), want)
	}

	s := linkServer(t, bothFiles, Config{})
	code := s.link(s.signUp("a@example.com"))
	page := s.fetch("/i/"+code, "Accept-Language", "es-ES,es;q=0.9")
	expect(t, "language", page.header.Get("Content-Language"), "es")
	for _, want := range []string{
		`<html lang="es">`, "Versión 0.2.0 (412)", "Celulares y tablets (64 bits)",
		"Fire TV, televisores y cajas Android (32 bits)", "Si no se instala, prueba con la otra opción.", "Este enlace funciona 30 minutos más.",
	} {
		expect(t, "the page has "+want, strings.Contains(page.body, want), true)
	}
	gone := s.fetch("/i/ZZZZZ", "Accept-Language", "es")
	expect(t, "not found, in Spanish", strings.Contains(gone.body, "Enlace no encontrado"), true)
}

func TestEachAccountMakesSoManyLinksAndThereAreSoManyAtATime(t *testing.T) {
	s := linkServer(t, bothFiles, Config{})
	ana, bob := s.signUp("ana@example.com"), s.signUp("bob@example.com")
	codes := map[string]bool{}
	for range linksPerHour {
		codes[s.link(ana)] = true
	}
	expect(t, "all different", len(codes), linksPerHour)
	status, body := s.call("POST", "/v1/app/link", nil, ana)
	expect(t, "one too many", status, 429)
	expect(t, "code", body["error"], any("rate_limited"))
	s.link(bob) // others still can
	s.clock.add(time.Hour + time.Second)
	s.link(ana) // and an hour later, again

	// Those still alive count against all of them (Ana's last one, and two of Bob's); those that
	// ended do not
	s.api.links.mu.Lock()
	s.api.links.max = 3
	s.api.links.mu.Unlock()
	s.link(bob)
	s.link(bob)
	status, body = s.call("POST", "/v1/app/link", nil, ana)
	expect(t, "too many alive", status, 503)
	expect(t, "code", body["error"], any("busy"))
	s.clock.add(linkFor)
	s.link(ana)
}

func TestNoInstallLinkWithoutARelease(t *testing.T) {
	s := startRelay(t, time.Second, Config{SignInsPerMinute: 10})
	status, body := s.call("POST", "/v1/app/link", nil, s.signUp("a@example.com"))
	expect(t, "status", status, 404)
	expect(t, "code", body["error"], any("no_app"))
}

func TestGuessingCodesIsStoppedPerAddress(t *testing.T) {
	s := linkServer(t, bothFiles, Config{TrustProxy: true})
	code := s.link(s.signUp("a@example.com"))
	guesser := func(i int) []string { return []string{"X-Forwarded-For", fmt.Sprintf("10.0.0.%d, 203.0.113.5", i)} }
	expect(t, "the right one does not count", s.fetch("/i/"+code, guesser(0)...).status, 200)
	for i := range linkMisses {
		// Forged addresses before the proxy's do not dodge it, nor do files of a code
		path := "/i/2222" + string(linkAlphabet[i])
		if i%2 == 1 {
			path += "/arm64-v8a"
		}
		expect(t, "a wrong one", s.fetch(path, guesser(i)...).status, 404)
	}
	stopped := s.fetch("/i/"+code, guesser(99)...)
	expect(t, "stopped, even with the right one", stopped.status, 429)
	expect(t, "said", strings.Contains(stopped.body, "Too many tries"), true)
	expect(t, "the files too", s.fetch("/i/"+code+"/arm64-v8a", guesser(99)...).status, 429)
	expect(t, "others are not", s.fetch("/i/"+code, "X-Forwarded-For", "198.51.100.7").status, 200)
	s.clock.add(linkMissWindow + time.Second)
	expect(t, "for a while", s.fetch("/i/"+code, guesser(0)...).status, 200)
}

func TestAnIPv6AddressIsStoppedWithItsWholeNetwork(t *testing.T) {
	for address, want := range map[string]string{
		"203.0.113.5":           "203.0.113.5",
		"::ffff:203.0.113.5":    "203.0.113.5",
		"2001:db8:1:2:3:4:5:6":  "2001:db8:1:2::/64",
		"2001:db8:1:2::c7":      "2001:db8:1:2::/64",
		"fe80::1%eth0":          "fe80::/64",
		"not an address at all": "not an address at all",
	} {
		expect(t, address, network(address), want)
	}

	s := linkServer(t, bothFiles, Config{TrustProxy: true})
	code := s.link(s.signUp("a@example.com"))
	from := func(address string) []string { return []string{"X-Forwarded-For", address} }
	for i := range linkMisses {
		// A new address of the same /64 for each guess
		expect(t, "a wrong one", s.fetch("/i/2222"+string(linkAlphabet[i]), from(fmt.Sprintf("2001:db8::%x", i))...).status, 404)
	}
	expect(t, "stopped", s.fetch("/i/"+code, from("2001:db8::ffff:1")...).status, 429)
	expect(t, "another network is not", s.fetch("/i/"+code, from("2001:db8:0:1::1")...).status, 200)
}

func TestTooManyWrongCodesFromEverywhereStopEveryone(t *testing.T) {
	s := linkServer(t, bothFiles, Config{TrustProxy: true})
	code := s.link(s.signUp("a@example.com"))
	const all = 15
	s.api.links.all.mu.Lock()
	s.api.links.all.max = all
	s.api.links.all.mu.Unlock()
	from := func(i int) []string { return []string{"X-Forwarded-For", fmt.Sprintf("198.51.100.%d", i)} }
	for i := range all {
		// Each address below its own limit
		expect(t, "a wrong one", s.fetch("/i/2222"+string(linkAlphabet[i]), from(i)...).status, 404)
	}
	// Then every code is answered the same, known or not, so guessing tells nothing
	for _, path := range []string{"/i/" + code, "/i/" + code + "/arm64-v8a", "/i/22222"} {
		stopped := s.fetch(path, from(200)...)
		expect(t, path, stopped.status, 429)
		expect(t, path+": said", strings.Contains(stopped.body, "Too many tries"), true)
	}
	s.clock.add(linkMissWindow + time.Second)
	expect(t, "for a while", s.fetch("/i/"+code, from(200)...).status, 200)
}

func TestCodesAreShortAndHaveNoLookAlikes(t *testing.T) {
	seen := map[string]bool{}
	for range 2000 {
		code := newCode()
		if len(code) != linkLength || strings.ContainsAny(code, "0O1IL") || strings.Trim(code, linkAlphabet) != "" {
			t.Fatalf("code %q", code)
		}
		seen[code] = true
	}
	expect(t, "random", len(seen) > 1990, true)
	letters := map[rune]bool{}
	for code := range seen {
		for _, c := range code {
			letters[c] = true
		}
	}
	expect(t, "the whole alphabet", len(letters), len(linkAlphabet))
}
