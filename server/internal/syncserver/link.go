package syncserver

import (
	"cmp"
	"crypto/rand"
	"fmt"
	"html/template"
	"maps"
	"math"
	"math/big"
	"net/http"
	"net/netip"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Install links: a short code that lets a device with no session take the app's release, such
// as a Fire TV, where one types an address into an app like Downloader. A signed-in device asks
// POST /v1/app/link and shows <server>/i/<code>; that page has a link per file of the release,
// GET /i/{code}/{abi}, the APK itself. Codes are short, to type with a remote, so they end soon,
// there are few at a time, and an address that guesses wrong too often is stopped for a while, as
// is everyone once all of them together do. They live in memory only.

const (
	linkAlphabet   = "23456789ABCDEFGHJKMNPQRSTUVWXYZ" // no 0/O, 1/I/L
	linkLength     = 5                                 // some 28 million codes
	linkFor        = 30 * time.Minute
	linksAlive     = 100  // at the same time, all accounts together
	linksPerHour   = 10   // made per account
	linkMisses     = 10   // unknown codes per address in linkMissWindow
	linkMissesAll  = 1000 // and from all addresses together
	linkMissWindow = 10 * time.Minute
	appName        = "Capy TV"
)

type links struct {
	mu     sync.Mutex
	now    func() time.Time
	codes  map[string]time.Time // when each one ends
	max    int
	made   *limiter // per account
	misses *limiter // per address
	all    *limiter // misses of all addresses together
}

func newLinks(now func() time.Time) *links {
	return &links{
		now:    now,
		codes:  map[string]time.Time{},
		max:    linksAlive,
		made:   newLimiter(linksPerHour, time.Hour, now),
		misses: newLimiter(linkMisses, linkMissWindow, now),
		all:    newLimiter(linkMissesAll, linkMissWindow, now),
	}
}

// add makes a code and returns when it ends; false when there are too many alive already.
func (l *links) add() (string, time.Time, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	for code, ends := range l.codes {
		if !now.Before(ends) {
			delete(l.codes, code)
		}
	}
	if len(l.codes) >= l.max {
		return "", time.Time{}, false
	}
	code := newCode()
	for _, taken := l.codes[code]; taken; _, taken = l.codes[code] {
		code = newCode()
	}
	ends := now.Add(linkFor)
	l.codes[code] = ends
	return code, ends, true
}

// open finds the link code (in any case) names, asked for from address: its code and when it
// ends, with 200. 404 when there is none or it ended, which counts against the address and
// against all of them; 429, for any code, when either missed too often, so the answer tells nothing.
func (l *links) open(address, code string) (string, time.Time, int) {
	code = strings.ToUpper(code)
	l.mu.Lock() // so that requests at the same time do not all get past the limits
	defer l.mu.Unlock()
	if l.misses.over(address) || l.all.over("all") {
		return "", time.Time{}, http.StatusTooManyRequests
	}
	ends, found := l.codes[code]
	if found && !l.now().Before(ends) {
		delete(l.codes, code)
		found = false
	}
	if !found {
		l.misses.tooMany(address)
		l.all.tooMany("all")
		return "", time.Time{}, http.StatusNotFound
	}
	return code, ends, http.StatusOK
}

// network is the part of an address that one client keeps: all of an IPv4 one, the first 64 bits
// of an IPv6 one, as a host normally has a whole /64 to take addresses from.
func network(address string) string {
	ip, err := netip.ParseAddr(address)
	if err != nil {
		return address
	}
	if ip = ip.Unmap(); ip.Is4() {
		return ip.String()
	}
	prefix, _ := ip.Prefix(64)
	return prefix.String()
}

func newCode() string {
	code := make([]byte, linkLength)
	for i := range code {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(linkAlphabet))))
		if err != nil {
			panic(err)
		}
		code[i] = linkAlphabet[n.Int64()]
	}
	return string(code)
}

// The page's texts, by language
type pageText struct {
	Lang, Version, Choose, Phones, FireTV, Universal, Windows, LeftOne, LeftMany string
	Gone, GoneText, TooMany, TooManyText, OtherOne                               string
}

var pageTexts = map[string]pageText{
	"en": {
		Lang:        "en",
		Version:     "Version %s (%d)",
		Choose:      "Choose the one for this device. Android may ask you to allow installing apps from here.",
		Phones:      "Phones and tablets (64-bit)",
		FireTV:      "Fire TV, TVs and Android boxes (32-bit)",
		OtherOne:    "If it does not install, try the other one.",
		Universal:   "Download " + appName,
		Windows:     "Windows computers (installer)",
		LeftOne:     "This link works for 1 more minute.",
		LeftMany:    "This link works for %d more minutes.",
		Gone:        "Link not found",
		GoneText:    "This link doesn't exist or has expired. Get a new one in " + appName + ": Settings, About, Install on another device.",
		TooMany:     "Too many tries",
		TooManyText: "Too many wrong links were tried. Try again in a few minutes.",
	},
	"es": {
		Lang:        "es",
		Version:     "Versión %s (%d)",
		Choose:      "Elige el de este dispositivo. Puede que Android pida permitir instalar apps desde aquí.",
		Phones:      "Celulares y tablets (64 bits)",
		FireTV:      "Fire TV, televisores y cajas Android (32 bits)",
		OtherOne:    "Si no se instala, prueba con la otra opción.",
		Universal:   "Descargar " + appName,
		Windows:     "Computadoras con Windows (instalador)",
		LeftOne:     "Este enlace funciona 1 minuto más.",
		LeftMany:    "Este enlace funciona %d minutos más.",
		Gone:        "Enlace no encontrado",
		GoneText:    "Este enlace no existe o ya venció. Pide uno nuevo en " + appName + ": Ajustes, Acerca de, Instalar en otro dispositivo.",
		TooMany:     "Demasiados intentos",
		TooManyText: "Se probaron demasiados enlaces equivocados. Prueba de nuevo en unos minutos.",
	},
}

// pageLanguage is the page language the browser prefers (Accept-Language); English when it
// names none of them.
func pageLanguage(header string) string {
	best, bestQ := "en", 0.0
	for _, part := range strings.Split(header, ",") {
		tag, params, _ := strings.Cut(part, ";")
		lang, _, _ := strings.Cut(strings.ToLower(strings.TrimSpace(tag)), "-")
		if _, known := pageTexts[lang]; !known {
			continue
		}
		q := 1.0
		if v, found := strings.CutPrefix(strings.TrimSpace(params), "q="); found {
			var err error
			if q, err = strconv.ParseFloat(v, 64); err != nil {
				continue
			}
		}
		if q > bestQ {
			best, bestQ = lang, q
		}
	}
	return best
}

type pageLink struct {
	Href, Label, Size string
}

type page struct {
	Lang, Title, Version, Text, Left string
	Links                            []pageLink
}

// Black and white, large enough to read on a TV, with nothing from elsewhere. A remote's focus
// turns a link white.
var installPage = template.Must(template.New("install").Parse(`<!doctype html>
<html lang="{{.Lang}}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>{{.Title}}</title>
<style>
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body { margin: 0; background: #000; color: #fff; font: clamp(18px, 2.4vw, 30px)/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
main { max-width: 34em; margin: 0 auto; padding: 1.5em 16px; }
h1 { font-size: 1.8em; line-height: 1.2; margin: 0 0 .2em; }
p { margin: 0 0 1em; }
.muted { color: #a6a6a6; }
a { display: block; margin: 0 0 .8em; padding: .8em 1.1em; border: 2px solid #fff; border-radius: 14px; color: #fff; text-decoration: none; font-size: 1.25em; font-weight: 700; }
a span { display: block; font-size: .7em; font-weight: 400; color: #a6a6a6; }
a:focus, a:hover { background: #fff; color: #000; outline: 3px solid #fff; outline-offset: 3px; }
a:focus span, a:hover span { color: #333; }
</style>
</head>
<body>
<main>
<h1>{{.Title}}</h1>
{{if .Version}}<p class="muted">{{.Version}}</p>{{end}}
<p>{{.Text}}</p>
{{range .Links}}<a href="{{.Href}}">{{.Label}}<span>{{.Size}}</span></a>
{{end}}{{if .Left}}<p class="muted">{{.Left}}</p>{{end}}
</main>
</body>
</html>
`))

func writePage(w http.ResponseWriter, status int, p page) {
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Content-Language", p.Lang)
	h.Set("Vary", "Accept-Language")
	// A link works for a while only, and no proxy may rewrite the page (Cloudflare adds scripts)
	h.Set("Cache-Control", "private, no-store, no-transform")
	h.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	installPage.Execute(w, p)
}

func errorPage(w http.ResponseWriter, status int, t pageText) {
	p := page{Lang: t.Lang, Title: t.Gone, Text: t.GoneText}
	if status == http.StatusTooManyRequests {
		p.Title, p.Text = t.TooMany, t.TooManyText
	}
	writePage(w, status, p)
}

// Requests

// appLink makes an install link: 201 {code, expires} · 404 no_app · 429 · 503 busy.
func (a *API) appLink(w http.ResponseWriter, _ *http.Request, au auth) {
	w.Header().Set("Cache-Control", "no-store")
	rel, err := a.releases.current()
	if !ok(w, err) {
		return
	}
	if rel == nil {
		fail(w, http.StatusNotFound, "no_app")
		return
	}
	if a.links.made.tooMany("account:" + strconv.FormatInt(au.accountID, 10)) {
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	code, ends, made := a.links.add()
	if !made {
		fail(w, http.StatusServiceUnavailable, "busy")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"code": code, "expires": stamp(ends)})
}

// linked returns the request's link and the release, or answers itself with a page (false).
// Unknown codes count against the address, an IPv6 one by its /64, which is stopped after too
// many: codes are short.
func (a *API) linked(w http.ResponseWriter, r *http.Request, t pageText) (string, time.Time, *release, bool) {
	code, ends, status := a.links.open("ip:"+network(a.clientIP(r)), r.PathValue("code"))
	if status != http.StatusOK {
		errorPage(w, status, t)
		return "", time.Time{}, nil, false
	}
	rel, err := a.releases.current()
	if !ok(w, err) {
		return "", time.Time{}, nil, false
	}
	if rel == nil { // taken away since
		errorPage(w, http.StatusNotFound, t)
		return "", time.Time{}, nil, false
	}
	return code, ends, rel, true
}

// installLinks is the page of an install link: a link per file of the release.
func (a *API) installLinks(w http.ResponseWriter, r *http.Request) {
	t := pageTexts[pageLanguage(r.Header.Get("Accept-Language"))]
	code, ends, rel, found := a.linked(w, r, t)
	if !found {
		return
	}
	labels := map[string]string{"arm64-v8a": t.Phones, "armeabi-v7a": t.FireTV, "universal": t.Universal, "windows-x64": t.Windows}
	order := map[string]int{"arm64-v8a": 1, "armeabi-v7a": 2, "universal": 3, "windows-x64": 4}
	rank := func(abi string) int { return cmp.Or(order[abi], len(order)+1) } // others after, by name
	abis := slices.Sorted(maps.Keys(rel.Files))
	slices.SortStableFunc(abis, func(x, y string) int { return cmp.Compare(rank(x), rank(y)) })
	version := cmp.Or(rel.Version, strconv.Itoa(rel.Build)) // as the app shows it
	p := page{Lang: t.Lang, Title: appName, Version: fmt.Sprintf(t.Version, version, rel.Build), Text: t.Choose}
	// Android only says "App not installed": with both, say there is another to try
	if _, ok := rel.Files["arm64-v8a"]; ok {
		if _, ok := rel.Files["armeabi-v7a"]; ok {
			p.Text += " " + t.OtherOne
		}
	}
	for _, abi := range abis {
		p.Links = append(p.Links, pageLink{
			Href:  code + "/" + abi, // relative: the server may be under a path of its proxy
			Label: cmp.Or(labels[abi], abi),
			Size:  fmt.Sprintf("%.1f MB", float64(rel.Files[abi].Size)/1e6),
		})
	}
	if left := int(math.Ceil(ends.Sub(a.links.now()).Minutes())); left > 1 {
		p.Left = fmt.Sprintf(t.LeftMany, left)
	} else {
		p.Left = t.LeftOne
	}
	writePage(w, http.StatusOK, p)
}

// installFile is the release's file for an ABI, for whoever has an install link.
func (a *API) installFile(w http.ResponseWriter, r *http.Request) {
	t := pageTexts[pageLanguage(r.Header.Get("Accept-Language"))]
	_, _, rel, found := a.linked(w, r, t)
	if !found {
		return
	}
	file, has := rel.Files[r.PathValue("abi")]
	if !has || !a.sendFile(w, r, file.Name) {
		errorPage(w, http.StatusNotFound, t)
	}
}

// installSlash takes an address typed with a slash at the end to its page, whose links are
// relative to it.
func installSlash(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Location", "../"+url.PathEscape(r.PathValue("code"))) // relative, as those links
	w.WriteHeader(http.StatusFound)
}
