package syncserver

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http"
	"net/netip"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	MaxItemBytes = 1 << 20
	MaxBatch     = 500
	MaxBodyBytes = 16 << 20
	// What a body may take on the routes that need no more: signing up or in, keys. Read before
	// anything is checked, a big one would cost memory for nothing
	smallBody = 16 << 10
	// Failed sign-ins an hour, and a day, for one account from one network, besides those a minute
	failuresPerHour = 30
	failuresPerDay  = 100
)

// API is the sync API. Devices prove who they are with an "auth key" derived from the user's
// password on the device (the password itself never leaves it); the server keeps only a salted
// hash of that key. The account's recovery key, for a forgotten password, works the same way.
// The keys that encrypt the account's data are kept here too, but wrapped with keys from the
// password and from the recovery key that the server never sees. Data are opaque encrypted items
// with a revision per account, so a device asks for what changed since the revision it last
// saw. A WebSocket tells the account's other devices the moment something changes.
type API struct {
	store    *Store
	config   Config
	limit    *limiter
	failures *limiter // failed sign-ins over an hour, per account and network
	daily    *limiter // and over a day
	live     *hub
	aiLimit  *limiter
	aiTotal  *limiter // all accounts together; nil for none
	aiClient *http.Client
	relay    *relay
	releases *releases
	links    *links
	clock    func() time.Time
}

// Config is what the server's owner decides.
type Config struct {
	TrustProxy       bool          // behind a reverse proxy: client addresses from X-Forwarded-For
	SignInsPerMinute int           // sign-up and sign-in attempts per address and per email
	SignupCode       string        // when set, creating an account needs it
	NoSignups        bool          // no new accounts at all: no code, and not opened to anyone
	MaxDataBytes     int64         // the whole database; past it, no new accounts nor more data. 0 is no limit
	MaxAccounts      int           // no more accounts than this are created; 0 is no limit
	QuotaBytes       int64         // per account, all payloads together; 0 is no limit
	SessionIdle      time.Duration // sessions unused for this long end; 0 is never
	AI               AIConfig      // a language model for the devices' recommendations, if any
	AppDir           string        // the app's releases, for devices to update themselves (see release.go); empty: none
}

// NewAPI serves store.
func NewAPI(store *Store, c Config) *API { return newAPI(store, c, time.Now) }

// newAPI takes the clock of the relay's rooms and of the install links, which tests turn forward.
func newAPI(store *Store, c Config, now func() time.Time) *API {
	store.clock = now // the sessions' too: a session is used, and ends, by the same clock
	limit := newLimiter(c.SignInsPerMinute, time.Minute, now)
	if c.AI.PerHour <= 0 {
		c.AI.PerHour = 30
	}
	a := &API{
		store:    store,
		config:   c,
		limit:    limit,
		failures: newLimiter(failuresPerHour, time.Hour, now),
		daily:    newLimiter(failuresPerDay, 24*time.Hour, now),
		live:     newHub(),
		aiLimit:  newLimiter(c.AI.PerHour, time.Hour, time.Now),
		aiClient: &http.Client{Timeout: aiTimeout},
		relay:    newRelay(now),
		releases: newReleases(c.AppDir),
		links:    newLinks(now),
		clock:    now,
	}
	if c.AI.PerHourTotal > 0 {
		a.aiTotal = newLimiter(c.AI.PerHourTotal, time.Hour, time.Now)
	}
	go a.relay.run()
	return a
}

func (a *API) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("POST /v1/accounts", a.signUp)
	mux.HandleFunc("POST /v1/sessions", a.signIn)
	mux.HandleFunc("DELETE /v1/sessions/current", a.authed(a.signOut))
	mux.HandleFunc("GET /v1/devices", a.authed(a.devices))
	mux.HandleFunc("DELETE /v1/devices/{id}", a.authed(a.signOutDevice))
	mux.HandleFunc("GET /v1/items", a.authed(a.items))
	mux.HandleFunc("PUT /v1/items", a.authed(a.putItems))
	mux.HandleFunc("PUT /v1/account/password", a.authed(a.setPassword))
	mux.HandleFunc("PUT /v1/account/recovery", a.authed(a.setRecovery))
	mux.HandleFunc("DELETE /v1/account", a.authed(a.deleteAccount))
	mux.HandleFunc("GET /v1/live", a.authedBy(liveToken, a.liveSocket))
	mux.HandleFunc("GET /v1/ai", a.authed(a.aiInfo))
	mux.HandleFunc("POST /v1/ai/chat", a.authed(a.aiChat))
	mux.HandleFunc("GET /v1/app", a.authed(a.appRelease))
	mux.HandleFunc("GET /v1/app/{file}", a.authed(a.appFile))
	mux.HandleFunc("POST /v1/app/link", a.authed(a.appLink))
	for _, prefix := range []string{"/i/", "/I/"} { // typed with caps lock on, too
		mux.HandleFunc("GET "+prefix+"{code}", a.installLinks)
		mux.HandleFunc("GET "+prefix+"{code}/{$}", installSlash)
		mux.HandleFunc("GET "+prefix+"{code}/{abi}", a.installFile)
	}
	mux.HandleFunc("GET /trailer", trailer)
	mux.HandleFunc("POST /v1/relay", a.relayOpen)
	mux.HandleFunc("POST /v1/relay/{room}/{to}", a.relayPost)
	mux.HandleFunc("GET /v1/relay/{room}/{to}", a.relayPoll)
	mux.HandleFunc("DELETE /v1/relay/{room}", a.relayClose)
	mux.HandleFunc("GET /companion", companion)
	return mux
}

// Close ends the live sockets, which a server shutdown does not track, and the relay's rooms, so
// their long-polls do not hold it up.
func (a *API) Close() {
	a.live.closeAll()
	a.relay.close()
}

// Requests

type credentials struct {
	Email        string `json:"email"`
	AuthKey      string `json:"authKey"`
	RecoveryKey  string `json:"recoveryKey"` // signing in with it in place of the password
	Device       string `json:"device"`
	Invite       string `json:"invite"`       // signing up on a server that asks for a code
	PasswordKeys string `json:"passwordKeys"` // signing up: the account's keys, wrapped with the password
	RecoveryKeys string `json:"recoveryKeys"` // and with the recovery key
}

func (a *API) signUp(w http.ResponseWriter, r *http.Request) {
	var c credentials
	if !readJSON(w, r, &c, smallBody) {
		return
	}
	email, key, device := cleanEmail(c.Email), decodeKey(c.AuthKey), cleanDevice(c.Device)
	recovery, passwordKeys, recoveryKeys := decodeKey(c.RecoveryKey), cleanWrapped(c.PasswordKeys), cleanWrapped(c.RecoveryKeys)
	if email == "" || key == nil || recovery == nil || passwordKeys == "" || recoveryKeys == "" {
		fail(w, http.StatusBadRequest, "invalid")
		return
	}
	if a.limit.tooMany("ip:"+a.clientKey(r), "email:"+email) {
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	code := a.config.SignupCode
	if code != "" && subtle.ConstantTimeCompare([]byte(strings.TrimSpace(c.Invite)), []byte(code)) != 1 {
		fail(w, http.StatusForbidden, "invite")
		return
	}
	// Closed to new accounts, or out of room: "full" is what the apps already say as "takes no more"
	if code == "" && a.config.NoSignups {
		fail(w, http.StatusForbidden, "full")
		return
	}
	if full, err := a.dataFull(r.Context()); !ok(w, err) {
		return
	} else if full {
		fail(w, http.StatusForbidden, "full")
		return
	}
	if a.config.MaxAccounts > 0 {
		n, err := a.store.AccountCount(r.Context())
		if !ok(w, err) {
			return
		}
		if n >= a.config.MaxAccounts {
			fail(w, http.StatusForbidden, "full")
			return
		}
	}
	salt := randomBytes(16)
	id, created, err := a.store.CreateAccount(r.Context(), email, Account{
		AuthHash:     hashKey(key, salt),
		AuthSalt:     salt,
		RecoveryHash: hashKey(recovery, salt),
		PasswordKeys: passwordKeys,
		RecoveryKeys: recoveryKeys,
	})
	if !ok(w, err) {
		return
	}
	if !created {
		fail(w, http.StatusConflict, "exists")
		return
	}
	token, err := a.newSession(r, id, device)
	if !ok(w, err) {
		return
	}
	rev, err := a.store.Revision(r.Context(), id)
	if !ok(w, err) {
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"token": token, "rev": rev.Rev, "epoch": rev.Epoch})
}

// signIn takes the auth key of the password or, for a forgotten one, of the recovery key, and
// answers with the account's keys as wrapped with that same secret.
func (a *API) signIn(w http.ResponseWriter, r *http.Request) {
	var c credentials
	if !readJSON(w, r, &c, smallBody) {
		return
	}
	email, key, device := cleanEmail(c.Email), decodeKey(c.AuthKey), cleanDevice(c.Device)
	recovery := c.AuthKey == ""
	if recovery {
		key = decodeKey(c.RecoveryKey)
	}
	if email == "" || key == nil {
		fail(w, http.StatusBadRequest, "invalid")
		return
	}
	// Every attempt counts for the address; for the account only those that fail, and only from
	// about where they come: someone who knows an email cannot keep its owner out, trying from
	// elsewhere, and has at most a hundred guesses a day at it from one network, not thousands
	failed := "email:" + email + "|" + wideNetwork(a.clientIP(r))
	if a.limit.tooMany("ip:"+a.clientKey(r)) || a.limit.over(failed) || a.failures.over(failed) || a.daily.over(failed) {
		w.Header().Set("Retry-After", "60")
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	account, err := a.store.AccountByEmail(r.Context(), email)
	if !ok(w, err) {
		return
	}
	// The same work whether the account exists or not, so timing does not tell
	salt, want, keys := randomBytes(16), []byte(nil), ""
	if account != nil {
		salt, want, keys = account.AuthSalt, account.AuthHash, account.PasswordKeys
		if recovery {
			want, keys = account.RecoveryHash, account.RecoveryKeys
		}
	}
	if !hmac.Equal(hashKey(key, salt), want) || len(want) == 0 {
		a.limit.tooMany(failed)
		a.failures.tooMany(failed)
		a.daily.tooMany(failed)
		fail(w, http.StatusUnauthorized, "credentials")
		return
	}
	token, err := a.newSession(r, account.ID, device)
	if !ok(w, err) {
		return
	}
	rev, err := a.store.Revision(r.Context(), account.ID)
	if !ok(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"token": token, "rev": rev.Rev, "epoch": rev.Epoch, "keys": keys})
}

// setPassword replaces the password: what proves it, and the account's keys wrapped with it. It
// takes the auth key of the current password or of the recovery key, since a session alone must
// not hand the account over (a phone left unlocked), and signs every other device out.
func (a *API) setPassword(w http.ResponseWriter, r *http.Request, au auth) {
	var body struct {
		Proof        string `json:"proof"`
		AuthKey      string `json:"authKey"`
		PasswordKeys string `json:"passwordKeys"`
	}
	if !readJSON(w, r, &body, smallBody) {
		return
	}
	key, keys := decodeKey(body.AuthKey), cleanWrapped(body.PasswordKeys)
	if key == nil || keys == "" {
		fail(w, http.StatusBadRequest, "invalid")
		return
	}
	account := a.proven(w, r, au, body.Proof)
	if account == nil {
		return
	}
	if !ok(w, a.store.SetPassword(r.Context(), au.accountID, hashKey(key, account.AuthSalt), keys, au.tokenHash)) {
		return
	}
	a.live.closeOthers(au.accountID, au.session)
	w.WriteHeader(http.StatusNoContent)
}

// setRecovery replaces the recovery key, with the same proof as setPassword. The one before stops working.
func (a *API) setRecovery(w http.ResponseWriter, r *http.Request, au auth) {
	var body struct {
		Proof        string `json:"proof"`
		RecoveryKey  string `json:"recoveryKey"`
		RecoveryKeys string `json:"recoveryKeys"`
	}
	if !readJSON(w, r, &body, smallBody) {
		return
	}
	key, keys := decodeKey(body.RecoveryKey), cleanWrapped(body.RecoveryKeys)
	if key == nil || keys == "" {
		fail(w, http.StatusBadRequest, "invalid")
		return
	}
	account := a.proven(w, r, au, body.Proof)
	if account == nil {
		return
	}
	if !ok(w, a.store.SetRecovery(r.Context(), au.accountID, hashKey(key, account.AuthSalt), keys)) {
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// proven returns the account when proof is the auth key of its password or of its recovery key,
// and answers itself (nil) when it is not. Tries count against the sign-in limit.
func (a *API) proven(w http.ResponseWriter, r *http.Request, au auth, proof string) *Account {
	key := decodeKey(proof)
	if key == nil {
		fail(w, http.StatusBadRequest, "invalid")
		return nil
	}
	if a.limit.tooMany("ip:"+a.clientKey(r), "account:"+strconv.FormatInt(au.accountID, 10)) {
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return nil
	}
	account, err := a.store.Account(r.Context(), au.accountID)
	if !ok(w, err) {
		return nil
	}
	if account == nil {
		fail(w, http.StatusUnauthorized, "auth")
		return nil
	}
	hash := hashKey(key, account.AuthSalt)
	if !hmac.Equal(hash, account.AuthHash) && !hmac.Equal(hash, account.RecoveryHash) {
		fail(w, http.StatusForbidden, "credentials")
		return nil
	}
	return account
}

func (a *API) signOut(w http.ResponseWriter, r *http.Request, au auth) {
	if _, err := a.store.DeleteSession(r.Context(), au.accountID, au.tokenHash); !ok(w, err) {
		return
	}
	a.live.close(au.accountID, au.session)
	w.WriteHeader(http.StatusNoContent)
}

// signOutDevice ends another session of the account (a lost phone, a TV given away). It keeps
// what it already has, but gets nothing new.
func (a *API) signOutDevice(w http.ResponseWriter, r *http.Request, au auth) {
	id := r.PathValue("id")
	hash, err := base64.RawURLEncoding.DecodeString(id)
	if err != nil || len(hash) != sha256.Size {
		fail(w, http.StatusNotFound, "not_found")
		return
	}
	found, err := a.store.DeleteSession(r.Context(), au.accountID, hash)
	if !ok(w, err) {
		return
	}
	if !found {
		fail(w, http.StatusNotFound, "not_found")
		return
	}
	a.live.close(au.accountID, id)
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) devices(w http.ResponseWriter, r *http.Request, au auth) {
	sessions, err := a.store.Sessions(r.Context(), au.accountID)
	if !ok(w, err) {
		return
	}
	list := make([]map[string]any, 0, len(sessions))
	for _, s := range sessions {
		id := base64.RawURLEncoding.EncodeToString(s.TokenHash)
		list = append(list, map[string]any{
			"id": id, "device": s.Device, "created": stamp(s.Created), "seen": stamp(s.Seen), "current": id == au.session,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": list})
}

func (a *API) items(w http.ResponseWriter, r *http.Request, au auth) {
	since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
	rev, items, err := a.store.Changes(r.Context(), au.accountID, since)
	if !ok(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"rev": rev.Rev, "epoch": rev.Epoch, "items": items})
}

func (a *API) putItems(w http.ResponseWriter, r *http.Request, au auth) {
	var body struct {
		Base  *int64 `json:"base"` // the revision the device last saw; writes only if still current
		Items []struct {
			ID      string  `json:"id"`
			Payload *string `json:"payload"`
			Deleted bool    `json:"deleted"`
		} `json:"items"`
	}
	if !readJSON(w, r, &body, MaxBodyBytes) {
		return
	}
	base := int64(-1)
	if body.Base != nil {
		base = *body.Base
	}
	if len(body.Items) == 0 || len(body.Items) > MaxBatch || (body.Base != nil && base < 0) {
		fail(w, http.StatusBadRequest, "invalid")
		return
	}
	writes := make([]ItemWrite, 0, len(body.Items))
	for _, it := range body.Items {
		// What the apps send: ids and sealed payloads in base64. Anything else would only be a way
		// past the quota (a NUL ends what SQLite measures)
		idOK := itemID.MatchString(it.ID)
		payloadOK := it.Deleted || (it.Payload != nil && len(*it.Payload) <= MaxItemBytes && isBase64(*it.Payload))
		if !idOK || !payloadOK {
			fail(w, http.StatusBadRequest, "invalid")
			return
		}
		if it.Deleted {
			it.Payload = nil
		}
		writes = append(writes, ItemWrite{ID: it.ID, Payload: it.Payload})
	}
	// The whole database past its cap: deletions only, which make room. "quota" is what the apps
	// already say as "ask whoever runs the server for more space"
	if adds := slices.ContainsFunc(writes, func(w ItemWrite) bool { return w.Payload != nil }); adds {
		if full, err := a.dataFull(r.Context()); !ok(w, err) {
			return
		} else if full {
			fail(w, http.StatusRequestEntityTooLarge, "quota")
			return
		}
	}
	rev, err := a.store.Put(r.Context(), au.accountID, base, a.config.QuotaBytes, writes)
	if errors.Is(err, ErrStale) {
		fail(w, http.StatusConflict, "stale")
		return
	}
	if errors.Is(err, ErrQuota) {
		fail(w, http.StatusRequestEntityTooLarge, "quota")
		return
	}
	if !ok(w, err) {
		return
	}
	a.live.notify(au.accountID, au.session, rev)
	writeJSON(w, http.StatusOK, map[string]any{"rev": rev})
}

func (a *API) deleteAccount(w http.ResponseWriter, r *http.Request, au auth) {
	var body struct {
		Proof string `json:"proof"`
	}
	if !readJSON(w, r, &body, smallBody) || a.proven(w, r, au, body.Proof) == nil {
		return
	}
	if !ok(w, a.store.DeleteAccount(r.Context(), au.accountID)) {
		return
	}
	a.live.close(au.accountID, "")
	w.WriteHeader(http.StatusNoContent)
}

// Authentication

type auth struct {
	accountID int64
	tokenHash []byte
	session   string // identifies the session among the account's live sockets
}

func (a *API) authed(h func(http.ResponseWriter, *http.Request, auth)) http.HandlerFunc {
	return a.authedBy(headerToken, h)
}

// headerToken is the session token of the Authorization header. Only there: tokens in URLs end up
// in proxy and browser logs.
func headerToken(r *http.Request) string {
	token, found := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !found {
		return ""
	}
	return token
}

// liveToken also takes the token from the live socket's subprotocols ("bearer.<token>"): a
// browser's WebSocket cannot send an Authorization header, so the Samsung TV app sends it there,
// still a header and out of addresses.
func liveToken(r *http.Request) string {
	if token := headerToken(r); token != "" {
		return token
	}
	for _, h := range r.Header.Values("Sec-WebSocket-Protocol") {
		for _, p := range strings.Split(h, ",") {
			if token, found := strings.CutPrefix(strings.TrimSpace(p), "bearer."); found {
				return token
			}
		}
	}
	return ""
}

func (a *API) authedBy(tokenOf func(*http.Request) string, h func(http.ResponseWriter, *http.Request, auth)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := tokenOf(r)
		if token == "" {
			fail(w, http.StatusUnauthorized, "auth")
			return
		}
		sum := sha256.Sum256([]byte(token))
		session, err := a.store.SessionByToken(r.Context(), sum[:], a.idleSince())
		if !ok(w, err) {
			return
		}
		if session == nil {
			fail(w, http.StatusUnauthorized, "auth")
			return
		}
		h(w, r, auth{accountID: session.AccountID, tokenHash: sum[:], session: base64.RawURLEncoding.EncodeToString(sum[:])})
	}
}

func (a *API) newSession(r *http.Request, accountID int64, device string) (string, error) {
	// Each new one also clears out the sessions nobody used for too long
	if err := a.store.ExpireSessions(r.Context(), a.idleSince()); err != nil {
		return "", err
	}
	token := base64.RawURLEncoding.EncodeToString(randomBytes(32))
	sum := sha256.Sum256([]byte(token))
	return token, a.store.CreateSession(r.Context(), sum[:], accountID, device)
}

// idleSince is how recently a session must have been used to still count; the zero time when
// sessions never end.
func (a *API) idleSince() time.Time {
	if a.config.SessionIdle <= 0 {
		return time.Time{}
	}
	return a.clock().Add(-a.config.SessionIdle)
}

func (a *API) clientIP(r *http.Request) string {
	// Behind a reverse proxy every request comes from the proxy: the client's address is the last
	// one it adds to X-Forwarded-For
	if a.config.TrustProxy {
		// The last address is the one our proxy added; earlier ones come from the client and can be
		// forged. Every line of the header: a proxy may add its own on a line apart (HAProxy), and the
		// first line alone would be the client's. One that is no address is not taken
		if xff := strings.Join(r.Header.Values("X-Forwarded-For"), ","); xff != "" {
			parts := strings.Split(xff, ",")
			last := strings.TrimSpace(parts[len(parts)-1])
			if ip, err := netip.ParseAddr(last); err == nil {
				return ip.String()
			}
			if ap, err := netip.ParseAddrPort(last); err == nil {
				return ap.Addr().String()
			}
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// Devices already stretch the password with Argon2id before deriving the auth key, so a salted
// HMAC is enough here: a leaked table still costs an Argon2id run per guess, and signing in stays
// cheap for the server.
func hashKey(key, salt []byte) []byte {
	mac := hmac.New(sha256.New, salt)
	mac.Write(key)
	return mac.Sum(nil)
}

// Helpers

var emailPattern = regexp.MustCompile(`^[^@\s]+@[^@\s]+\.[^@\s]+$`)

func cleanEmail(s string) string {
	e := strings.ToLower(strings.TrimSpace(s))
	if len(e) > 254 || !emailPattern.MatchString(e) {
		return ""
	}
	return e
}

func decodeKey(s string) []byte {
	key, err := base64.StdEncoding.DecodeString(s)
	if err != nil || len(key) != 32 {
		return nil
	}
	return key
}

// cleanWrapped returns a wrapped key as sent, or "" when it is not one: base64, and small.
func cleanWrapped(s string) string {
	raw, err := base64.StdEncoding.DecodeString(s)
	if err != nil || len(raw) < 16 || len(raw) > 1024 {
		return ""
	}
	return s
}

func cleanDevice(s string) string {
	d := strings.TrimSpace(s)
	if d == "" || !utf8.ValidString(d) {
		return "Device"
	}
	if r := []rune(d); len(r) > 80 {
		return string(r[:80])
	}
	return d
}

func randomBytes(n int) []byte {
	b := make([]byte, n)
	rand.Read(b)
	return b
}

func stamp(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000Z07:00") }

var itemID = regexp.MustCompile(`^[A-Za-z0-9_=-]{1,128}$`)

// isBase64 reports whether s is standard base64, as sealed payloads are.
func isBase64(s string) bool {
	_, err := base64.StdEncoding.DecodeString(s)
	return err == nil
}

// clientKey is what the limits count a client by: its network (see network), as an IPv6 host may
// take a new address for each request.
func (a *API) clientKey(r *http.Request) string { return network(a.clientIP(r)) }

// wideNetwork is about where a client is: an IPv4 /16, an IPv6 /32.
func wideNetwork(address string) string {
	ip, err := netip.ParseAddr(address)
	if err != nil {
		return address
	}
	bits := 32
	if ip = ip.Unmap(); ip.Is4() {
		bits = 16
	}
	prefix, _ := ip.Prefix(bits)
	return prefix.String()
}

// readJSON decodes the body, of [limit] bytes at most, into v, answering 400 or 413 itself when it
// cannot.
func readJSON(w http.ResponseWriter, r *http.Request, v any, limit int64) bool {
	// Stops reading as soon as a body goes over the limit, whatever Content-Length claimed
	err := json.NewDecoder(http.MaxBytesReader(w, r.Body, limit)).Decode(v)
	var tooLarge *http.MaxBytesError
	switch {
	case errors.As(err, &tooLarge):
		fail(w, http.StatusRequestEntityTooLarge, "too_large")
	case err != nil:
		fail(w, http.StatusBadRequest, "invalid")
	}
	return err == nil
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(body)
}

// dataFull says whether the database has reached the owner's cap (MAX_DATA_MB).
func (a *API) dataFull(ctx context.Context) (bool, error) {
	if a.config.MaxDataBytes <= 0 {
		return false, nil
	}
	size, err := a.store.Size(ctx)
	return size >= a.config.MaxDataBytes, err
}

func fail(w http.ResponseWriter, status int, code string) {
	writeJSON(w, status, map[string]string{"error": code})
}

// ok answers 500 for an unexpected error (logged without request data) and reports whether there was none.
func ok(w http.ResponseWriter, err error) bool {
	if err != nil {
		log.Printf("error: %v", err)
		fail(w, http.StatusInternalServerError, "server")
	}
	return err == nil
}
