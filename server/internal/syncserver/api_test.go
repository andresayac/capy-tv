package syncserver

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func fill(b byte, n int) string { return base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{b}, n)) }

var (
	key         = fill(7, 32)
	otherKey    = fill(9, 32)
	recoveryKey = fill(3, 32)
	// The account's keys as devices wrap them, with the password and with the recovery key: opaque here
	passwordKeys = fill(5, 76)
	recoveryKeys = fill(6, 76)
)

// newAccount is what a device sends to create an account.
func newAccount(email string) map[string]string {
	return map[string]string{
		"email": email, "authKey": key, "device": "Phone",
		"recoveryKey": recoveryKey, "passwordKeys": passwordKeys, "recoveryKeys": recoveryKeys,
	}
}

type testServer struct {
	*testing.T
	api *API
	url string
}

func start(t *testing.T, trustProxy bool) *testServer {
	return startWith(t, Config{TrustProxy: trustProxy, SignInsPerMinute: 10, QuotaBytes: 4 << 20})
}

func startWith(t *testing.T, c Config) *testServer {
	store, err := OpenStore(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	api := NewAPI(store, c)
	server := httptest.NewServer(api.Handler())
	t.Cleanup(func() {
		api.Close()
		server.Close()
		store.Close()
	})
	return &testServer{T: t, api: api, url: server.URL}
}

// call returns the status and the decoded JSON body (nil when empty).
func (s *testServer) call(method, path string, body any, token string, headers ...string) (int, map[string]any) {
	s.Helper()
	var reader *bytes.Reader
	if body == nil {
		reader = bytes.NewReader(nil)
	} else {
		raw, _ := json.Marshal(body)
		reader = bytes.NewReader(raw)
	}
	req, _ := http.NewRequest(method, s.url+path, reader)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for i := 0; i+1 < len(headers); i += 2 {
		req.Header.Set(headers[i], headers[i+1])
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		s.Fatal(err)
	}
	defer res.Body.Close()
	var j map[string]any
	json.NewDecoder(res.Body).Decode(&j)
	return res.StatusCode, j
}

func (s *testServer) signUp(email string) string {
	s.Helper()
	status, body := s.call("POST", "/v1/accounts", newAccount(email), "")
	if status != 201 {
		s.Fatalf("sign up: %d %v", status, body)
	}
	return body["token"].(string)
}

func expect[T comparable](t *testing.T, what string, got, want T) {
	t.Helper()
	if got != want {
		t.Errorf("%s: got %v, want %v", what, got, want)
	}
}

func item(id, payload string) map[string]any { return map[string]any{"id": id, "payload": payload} }

func items(list ...map[string]any) map[string]any { return map[string]any{"items": list} }

func TestAccountsSignUpOnceSignInWithTheSameKeyOnly(t *testing.T) {
	s := start(t, false)
	s.signUp("Ana@Example.com ")
	dup, _ := s.call("POST", "/v1/accounts", newAccount("ana@example.com"), "")
	expect(t, "emails are compared trimmed and in lowercase", dup, 409)
	status, session := s.call("POST", "/v1/sessions", map[string]string{"email": "ana@example.com", "authKey": key, "device": "TV"}, "")
	expect(t, "sign in", status, 200)
	token := session["token"].(string)
	expect(t, "token length >= 40", len(token) >= 40, true)
	wrong, _ := s.call("POST", "/v1/sessions", map[string]string{"email": "ana@example.com", "authKey": otherKey}, "")
	expect(t, "wrong key", wrong, 401)
	nobody, _ := s.call("POST", "/v1/sessions", map[string]string{"email": "bob@example.com", "authKey": key}, "")
	expect(t, "unknown email gets the same answer as a wrong key", nobody, 401)
	bad, _ := s.call("POST", "/v1/accounts", newAccount("not-an-email"), "")
	expect(t, "bad email", bad, 400)
	for field, value := range map[string]string{"authKey": "c2hvcnQ=", "recoveryKey": "", "passwordKeys": "", "recoveryKeys": "bm8ga2V5cw=="} {
		body := newAccount("c@example.com")
		body[field] = value
		status, _ := s.call("POST", "/v1/accounts", body, "")
		expect(t, "without a good "+field, status, 400)
	}
	status, list := s.call("GET", "/v1/devices", nil, token)
	expect(t, "devices", status, 200)
	var names []string
	for _, d := range list["devices"].([]any) {
		names = append(names, d.(map[string]any)["device"].(string))
	}
	slices.Sort(names)
	expect(t, "device names", strings.Join(names, ","), "Phone,TV")
}

func TestSigningInHandsBackTheKeysWrappedWithTheSameSecret(t *testing.T) {
	s := start(t, false)
	s.signUp("ana@example.com")
	signIn := func(field, value string) (int, map[string]any) {
		return s.call("POST", "/v1/sessions", map[string]string{"email": "ana@example.com", field: value, "device": "TV"}, "")
	}
	status, withPassword := signIn("authKey", key)
	expect(t, "with the password", status, 200)
	expect(t, "keys wrapped with the password", withPassword["keys"], any(passwordKeys))
	status, withRecovery := signIn("recoveryKey", recoveryKey)
	expect(t, "with the recovery key", status, 200)
	expect(t, "keys wrapped with the recovery key", withRecovery["keys"], any(recoveryKeys))
	wrong, answer := signIn("recoveryKey", otherKey)
	expect(t, "another recovery key", wrong, 401)
	expect(t, "nothing handed out", answer["keys"], nil)
	swapped, _ := signIn("authKey", recoveryKey)
	expect(t, "the recovery key is not a password", swapped, 401)
}

func TestChangingThePasswordTakesProofAndSignsTheOtherDevicesOut(t *testing.T) {
	s := start(t, false)
	phone := s.signUp("ana@example.com")
	_, session := s.call("POST", "/v1/sessions", map[string]string{"email": "ana@example.com", "authKey": key, "device": "TV"}, "")
	tv := session["token"].(string)
	newKeys := fill(8, 76)
	change := func(proof string) (int, map[string]any) {
		return s.call("PUT", "/v1/account/password", map[string]string{"proof": proof, "authKey": otherKey, "passwordKeys": newKeys}, phone)
	}
	status, answer := change(otherKey)
	expect(t, "not without the current password", status, 403)
	expect(t, "error", answer["error"], any("credentials"))
	status, _ = change("")
	expect(t, "nor without any", status, 400)
	status, _ = s.call("PUT", "/v1/account/password", map[string]string{"proof": key, "authKey": otherKey}, phone)
	expect(t, "nor without the keys wrapped with the new one", status, 400)
	status, _ = change(key)
	expect(t, "changed", status, 204)
	gone, _ := s.call("GET", "/v1/items?since=0", nil, tv)
	expect(t, "the TV is signed out", gone, 401)
	kept, _ := s.call("GET", "/v1/items?since=0", nil, phone)
	expect(t, "the phone that changed it is not", kept, 200)
	old, _ := s.call("POST", "/v1/sessions", map[string]string{"email": "ana@example.com", "authKey": key}, "")
	expect(t, "the old password", old, 401)
	status, signedIn := s.call("POST", "/v1/sessions", map[string]string{"email": "ana@example.com", "authKey": otherKey}, "")
	expect(t, "the new one", status, 200)
	expect(t, "with its keys", signedIn["keys"], any(newKeys))
}

func TestTheRecoveryKeySetsANewPasswordAndCanBeReplaced(t *testing.T) {
	s := start(t, false)
	s.signUp("ana@example.com")
	_, session := s.call("POST", "/v1/sessions", map[string]string{"email": "ana@example.com", "recoveryKey": recoveryKey}, "")
	token := session["token"].(string)
	status, _ := s.call("PUT", "/v1/account/password", map[string]string{"proof": recoveryKey, "authKey": otherKey, "passwordKeys": fill(8, 76)}, token)
	expect(t, "a forgotten password, replaced", status, 204)
	status, _ = s.call("POST", "/v1/sessions", map[string]string{"email": "ana@example.com", "authKey": otherKey}, "")
	expect(t, "the new password works", status, 200)

	newRecovery, newRecoveryKeys := fill(4, 32), fill(2, 76)
	status, _ = s.call("PUT", "/v1/account/recovery", map[string]string{"proof": recoveryKey, "recoveryKey": newRecovery}, token)
	expect(t, "not without the keys wrapped with it", status, 400)
	status, _ = s.call("PUT", "/v1/account/recovery", map[string]string{"proof": key, "recoveryKey": newRecovery, "recoveryKeys": newRecoveryKeys}, token)
	expect(t, "not with the old password", status, 403)
	status, _ = s.call("PUT", "/v1/account/recovery", map[string]string{"proof": otherKey, "recoveryKey": newRecovery, "recoveryKeys": newRecoveryKeys}, token)
	expect(t, "a new recovery key", status, 204)
	old, _ := s.call("POST", "/v1/sessions", map[string]string{"email": "ana@example.com", "recoveryKey": recoveryKey}, "")
	expect(t, "the old one stops working", old, 401)
	status, signedIn := s.call("POST", "/v1/sessions", map[string]string{"email": "ana@example.com", "recoveryKey": newRecovery}, "")
	expect(t, "the new one works", status, 200)
	expect(t, "with its keys", signedIn["keys"], any(newRecoveryKeys))
	other := s.signUp("bob@example.com")
	status, _ = s.call("PUT", "/v1/account/password", map[string]string{"proof": otherKey, "authKey": key, "passwordKeys": fill(8, 76)}, other)
	expect(t, "another account's password proves nothing here", status, 403)
}

func TestADatabaseFromAnEarlierVersionOpens(t *testing.T) {
	path := t.TempDir() + "/sync.db"
	db, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`CREATE TABLE accounts (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, auth_hash BLOB NOT NULL,
		auth_salt BLOB NOT NULL, rev INTEGER NOT NULL DEFAULT 0, created INTEGER NOT NULL);
		INSERT INTO accounts (email, auth_hash, auth_salt, created) VALUES ('ana@example.com', x'01', x'02', 1)`)
	db.Close()
	if err != nil {
		t.Fatal(err)
	}
	for range 2 { // and again, once up to date
		store, err := OpenStore(path)
		if err != nil {
			t.Fatal(err)
		}
		a, err := store.AccountByEmail(context.Background(), "ana@example.com")
		store.Close()
		expect(t, "error", err, nil)
		expect(t, "no recovery key yet", len(a.RecoveryHash), 0)
		expect(t, "nor keys", a.PasswordKeys, "")
	}
}

func TestItemsWhatChangedSinceARevisionDeletionsIncluded(t *testing.T) {
	s := start(t, false)
	token := s.signUp("ana@example.com")
	status, r1 := s.call("PUT", "/v1/items", items(item("a", "Y2lwaGVyLWE="), item("b", "Y2lwaGVyLWI=")), token)
	expect(t, "put", status, 200)
	expect(t, "first revision", r1["rev"], any(1.0))
	_, r2 := s.call("PUT", "/v1/items", items(map[string]any{"id": "a", "deleted": true}), token)
	expect(t, "second revision", r2["rev"], any(2.0))
	_, all := s.call("GET", "/v1/items?since=0", nil, token)
	expect(t, "rev", all["rev"], any(2.0))
	var got []string
	for _, i := range all["items"].([]any) {
		m := i.(map[string]any)
		got = append(got, fmt.Sprintf("%v/%v/%v", m["id"], m["deleted"], m["payload"]))
	}
	expect(t, "items", strings.Join(got, " "), "b/false/Y2lwaGVyLWI= a/true/<nil>")
	_, changes := s.call("GET", "/v1/items?since=1", nil, token)
	expect(t, "changes since 1", len(changes["items"].([]any)), 1)
	expect(t, "changed item", changes["items"].([]any)[0].(map[string]any)["id"], any("a"))
}

func TestWritesBasedOnAnOldRevisionAreRefused(t *testing.T) {
	s := start(t, false)
	token := s.signUp("ana@example.com")
	write := func(base any) (int, map[string]any) {
		return s.call("PUT", "/v1/items", map[string]any{"base": base, "items": []any{item("a", "eA==")}}, token)
	}
	status, r1 := write(0)
	expect(t, "based on the current revision", status, 200)
	expect(t, "rev", r1["rev"], any(1.0))
	stale, body := write(0)
	expect(t, "based on an old one", stale, 409)
	expect(t, "error", body["error"], any("stale"))
	_, all := s.call("GET", "/v1/items?since=0", nil, token)
	expect(t, "nothing written", all["rev"], any(1.0))
	negative, _ := write(-1)
	expect(t, "negative base", negative, 400)
	status, _ = s.call("PUT", "/v1/items", items(item("a", "eQ==")), token)
	expect(t, "without a base, as before", status, 200)
}

func TestTheEpochTellsARecreatedAccountApart(t *testing.T) {
	s := start(t, false)
	creds := newAccount("ana@example.com")
	_, first := s.call("POST", "/v1/accounts", creds, "")
	epoch := first["epoch"]
	expect(t, "an epoch", epoch != nil && epoch != any(0.0), true)
	_, changes := s.call("GET", "/v1/items?since=0", nil, first["token"].(string))
	expect(t, "the same in changes", changes["epoch"], epoch)
	s.call("DELETE", "/v1/account", map[string]string{"proof": key}, first["token"].(string))
	time.Sleep(5 * time.Millisecond)
	_, again := s.call("POST", "/v1/accounts", creds, "")
	expect(t, "a new account, a new epoch", again["epoch"] != epoch, true)
	_, session := s.call("POST", "/v1/sessions", creds, "")
	expect(t, "signing in says it too", session["epoch"], again["epoch"])
}

func TestNothingWithoutAValidSessionAndAccountsSeeOnlyTheirOwnItems(t *testing.T) {
	s := start(t, false)
	ana := s.signUp("ana@example.com")
	inURL, _ := s.call("GET", "/v1/items?since=0&token="+ana, nil, "")
	expect(t, "a token in the URL is not taken", inURL, 401)
	s.call("PUT", "/v1/items", items(item("x", "cA==")), ana)
	noToken, _ := s.call("GET", "/v1/items", nil, "")
	expect(t, "no token", noToken, 401)
	forged, _ := s.call("GET", "/v1/items", nil, "forged")
	expect(t, "forged token", forged, 401)
	bob := s.signUp("bob@example.com")
	_, list := s.call("GET", "/v1/items?since=0", nil, bob)
	expect(t, "bob sees nothing of ana", len(list["items"].([]any)), 0)
	out, _ := s.call("DELETE", "/v1/sessions/current", nil, ana)
	expect(t, "sign out", out, 204)
	after, _ := s.call("GET", "/v1/items", nil, ana)
	expect(t, "signed out", after, 401)
}

func TestOversizedRequestsAreCutOff(t *testing.T) {
	s := start(t, false)
	token := s.signUp("ana@example.com")
	bigItem, _ := s.call("PUT", "/v1/items", items(item("a", strings.Repeat("x", MaxItemBytes+1))), token)
	expect(t, "item over the limit", bigItem, 400)
	var many []map[string]any
	for i := range 17 {
		many = append(many, item(fmt.Sprint(i), strings.Repeat("x", MaxItemBytes)))
	}
	bigBody, _ := s.call("PUT", "/v1/items", items(many...), token)
	expect(t, "body over the limit", bigBody, 413)
}

func TestDeletingTheAccountRemovesItAndItsData(t *testing.T) {
	s := start(t, false)
	token := s.signUp("ana@example.com")
	noProof, _ := s.call("DELETE", "/v1/account", map[string]string{}, token)
	expect(t, "a session alone cannot delete it", noProof, 400)
	wrong, _ := s.call("DELETE", "/v1/account", map[string]string{"proof": otherKey}, token)
	expect(t, "nor a wrong password", wrong, 403)
	deleted, _ := s.call("DELETE", "/v1/account", map[string]string{"proof": key}, token)
	expect(t, "delete", deleted, 204)
	after, _ := s.call("GET", "/v1/items", nil, token)
	expect(t, "session gone", after, 401)
	signIn, _ := s.call("POST", "/v1/sessions", map[string]string{"email": "ana@example.com", "authKey": key}, "")
	expect(t, "account gone", signIn, 401)
	s.signUp("ana@example.com") // the email is free again
}

func TestTooManySignInAttemptsAreRefusedForAWhile(t *testing.T) {
	s := start(t, false)
	s.signUp("ana@example.com")
	for range 9 {
		s.call("POST", "/v1/sessions", map[string]string{"email": "ana@example.com", "authKey": otherKey}, "")
	}
	status, _ := s.call("POST", "/v1/sessions", map[string]string{"email": "ana@example.com", "authKey": key}, "")
	expect(t, "not even with the right key once over the limit", status, 429)
}

func TestFailedSignInsFromElsewhereDoNotKeepTheOwnerOut(t *testing.T) {
	s := start(t, true)
	s.signUp("ana@example.com")
	attempt := func(k, from string) int {
		status, _ := s.call("POST", "/v1/sessions", map[string]string{"email": "ana@example.com", "authKey": k}, "", "X-Forwarded-For", from)
		return status
	}
	for i := range 10 {
		attempt(otherKey, fmt.Sprintf("198.51.%d.1", i)) // one guess from each of ten addresses in one /16
	}
	expect(t, "the right key from that network", attempt(key, "198.51.100.7"), 429)
	expect(t, "the owner, elsewhere", attempt(key, "203.0.113.9"), 200)
}

func TestItemsAreBase64AndTheQuotaCountsTheirBytes(t *testing.T) {
	s := startWith(t, Config{SignInsPerMinute: 10, QuotaBytes: 4 << 10})
	token := s.signUp("ana@example.com")
	for _, bad := range []string{"\x00" + strings.Repeat("A", 100), "ñññ", "not base64"} {
		status, _ := s.call("PUT", "/v1/items", items(item("a", bad)), token)
		expect(t, bad, status, 400)
	}
	status, _ := s.call("PUT", "/v1/items", items(map[string]any{"id": "a b", "deleted": true}), token)
	expect(t, "an id that is no base64", status, 400)
	// Deletions count too: a few dozen use the quota up
	status = 200
	for i := 0; i < 60 && status == 200; i++ {
		status, _ = s.call("PUT", "/v1/items", items(map[string]any{"id": fmt.Sprintf("%0100d", i), "deleted": true}), token)
	}
	expect(t, "past the quota with deletions alone", status, 413)
}

func TestLimiterForgetsAfterTheWindow(t *testing.T) {
	now := time.Unix(0, 0)
	l := newLimiter(2, time.Minute, func() time.Time { return now })
	l.tooMany("k")
	l.tooMany("k")
	expect(t, "third within a minute", l.tooMany("k"), true)
	now = now.Add(61 * time.Second)
	expect(t, "a minute later", l.tooMany("k"), false)
}

func TestBehindAProxyAForgedForwardedAddressDoesNotDodgeTheLimit(t *testing.T) {
	s := start(t, true)
	status := 0
	for i := range 11 {
		status, _ = s.call("POST", "/v1/sessions",
			map[string]string{"email": fmt.Sprintf("user%d@example.com", i), "authKey": key}, "",
			"X-Forwarded-For", fmt.Sprintf("10.0.0.%d, 203.0.113.5", i))
	}
	expect(t, "eleventh attempt from the same real address", status, 429)
}

func TestBehindAProxyItsLineApartCountsAndNoAddressIsTaken(t *testing.T) {
	s := start(t, true)
	attempt := func(forwarded ...string) int {
		raw, _ := json.Marshal(map[string]string{"email": "nobody@example.com", "authKey": otherKey})
		req, _ := http.NewRequest("POST", s.url+"/v1/sessions", bytes.NewReader(raw))
		for _, f := range forwarded {
			req.Header.Add("X-Forwarded-For", f)
		}
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		return res.StatusCode
	}
	status := 0
	for i := range 11 {
		// The client's forged line first, the proxy's own on a line apart (as HAProxy adds it)
		status = attempt(fmt.Sprintf("10.0.0.%d", i), "203.0.113.5")
	}
	expect(t, "eleventh from the same real address", status, 429)

	s = start(t, true)
	for i := range 11 {
		status = attempt(fmt.Sprintf("not-an-address-%d", i))
	}
	expect(t, "what is no address is not taken for one: the connection's counts", status, 429)
}

func TestOtherDevicesHearAboutChangesAtOnce(t *testing.T) {
	s := start(t, false)
	phone := s.signUp("ana@example.com")
	_, tv := s.call("POST", "/v1/sessions", map[string]string{"email": "ana@example.com", "authKey": key, "device": "TV"}, "")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(s.url, "http")+"/v1/live",
		&websocket.DialOptions{HTTPHeader: http.Header{"Authorization": {"Bearer " + tv["token"].(string)}}})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	read := func() liveMessage {
		_, data, err := conn.Read(ctx)
		if err != nil {
			t.Fatal(err)
		}
		var m liveMessage
		json.Unmarshal(data, &m)
		return m
	}
	expect(t, "first message", read(), liveMessage{Type: "hello", Rev: 0})
	s.call("PUT", "/v1/items", items(item("a", "cA==")), phone)
	expect(t, "after the phone writes", read(), liveMessage{Type: "changed", Rev: 1})

	// Signing out ends that session's socket
	s.call("DELETE", "/v1/sessions/current", nil, tv["token"].(string))
	if _, _, err := conn.Read(ctx); websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Errorf("socket after signing out: %v", err)
	}
}

func TestABrowserListensWithItsTokenAsASubprotocol(t *testing.T) {
	s := start(t, false)
	s.signUp("ana@example.com")
	_, tv := s.call("POST", "/v1/sessions", map[string]string{"email": "ana@example.com", "authKey": key, "device": "TV"}, "")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	url := "ws" + strings.TrimPrefix(s.url, "http") + "/v1/live"

	// As the Samsung TV app does: no Authorization header, a page with no web origin
	conn, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{
		Subprotocols: []string{"capy-sync", "bearer." + tv["token"].(string)},
		HTTPHeader:   http.Header{"Origin": {"file://"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	expect(t, "subprotocol picked", conn.Subprotocol(), "capy-sync")
	_, data, err := conn.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var m liveMessage
	json.Unmarshal(data, &m)
	expect(t, "first message", m, liveMessage{Type: "hello", Rev: 0})

	_, res, err := websocket.Dial(ctx, url, &websocket.DialOptions{Subprotocols: []string{"capy-sync", "bearer.wrong"}})
	if err == nil || res == nil || res.StatusCode != 401 {
		t.Errorf("a wrong token: %v %v", err, res)
	}
	// Only the live socket takes it there
	status, _ := s.call("GET", "/v1/devices", nil, "", "Sec-WebSocket-Protocol", "bearer."+tv["token"].(string))
	expect(t, "elsewhere", status, 401)
}

func TestBackupIsACopyThatOpens(t *testing.T) {
	dir := t.TempDir()
	path, target := dir+"/sync.db", dir+"/backup.db"
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	id, _, _ := store.CreateAccount(ctx, "ana@example.com", Account{AuthHash: []byte("hash"), AuthSalt: []byte("salt"), RecoveryHash: []byte("hash")})
	payload := "cipher"
	store.Put(ctx, id, -1, 0, []ItemWrite{{ID: "a", Payload: &payload}})
	if accounts, err := Backup(path, target); err != nil || accounts != 1 { // while the server still has it open
		t.Fatal(accounts, err)
	}
	store.Close()
	restored, err := OpenStore(target)
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	rev, items, err := restored.Changes(ctx, id, 0)
	expect(t, "error", err, nil)
	expect(t, "rev", rev.Rev, 1)
	expect(t, "items", len(items), 1)
	_, err = Backup(path, target)
	expect(t, "a second backup over it", err != nil, true)
	_, err = Backup(dir+"/wrong.db", dir+"/empty.db")
	expect(t, "a path with no database", err != nil, true)
	_, err = os.Stat(dir + "/wrong.db")
	expect(t, "and none made there", os.IsNotExist(err), true)
}

func TestAPrivateServerAsksForTheInvitationCode(t *testing.T) {
	s := startWith(t, Config{SignInsPerMinute: 10, SignupCode: "family-2026"})
	body := func(invite string) map[string]string {
		b := newAccount("ana@example.com")
		b["invite"] = invite
		return b
	}
	none, answer := s.call("POST", "/v1/accounts", body(""), "")
	expect(t, "without the code", none, 403)
	expect(t, "error", answer["error"], any("invite"))
	wrong, _ := s.call("POST", "/v1/accounts", body("family-2025"), "")
	expect(t, "with another code", wrong, 403)
	right, _ := s.call("POST", "/v1/accounts", body(" family-2026 "), "")
	expect(t, "with the code", right, 201)
	signIn, _ := s.call("POST", "/v1/sessions", body(""), "")
	expect(t, "signing in needs no code", signIn, 200)
}

func TestAServerWithNoCodeTakesNoNewAccountsUnlessOpened(t *testing.T) {
	closed := startWith(t, Config{SignInsPerMinute: 10, NoSignups: true})
	status, body := closed.call("POST", "/v1/accounts", newAccount("ana@example.com"), "")
	expect(t, "closed", fmt.Sprint(status, " ", body["error"]), "403 full")
	open := startWith(t, Config{SignInsPerMinute: 10})
	open.signUp("ana@example.com")
}

func TestTheWholeDatabaseHasACap(t *testing.T) {
	s := startWith(t, Config{SignInsPerMinute: 10, QuotaBytes: 4 << 20})
	token := s.signUp("ana@example.com")
	ok, _ := s.call("PUT", "/v1/items", items(item("a", "eHl6")), token)
	expect(t, "room left", ok, 200)

	s.api.config.MaxDataBytes = 1 // the database past its cap from now on
	status, body := s.call("PUT", "/v1/items", items(item("b", "eHl6")), token)
	expect(t, "more data", fmt.Sprint(status, " ", body["error"]), "413 quota")
	status, body = s.call("POST", "/v1/accounts", newAccount("bea@example.com"), "")
	expect(t, "a new account", fmt.Sprint(status, " ", body["error"]), "403 full")
	gone, _ := s.call("PUT", "/v1/items", items(map[string]any{"id": "a", "deleted": true}), token)
	expect(t, "deleting, which makes room", gone, 200)
	size, err := s.api.store.Size(t.Context())
	expect(t, "the size can be read", err, error(nil))
	expect(t, "and is some", size > 0, true)
}

func TestAnAccountCannotGoOverItsQuota(t *testing.T) {
	s := startWith(t, Config{SignInsPerMinute: 10, QuotaBytes: 400})
	token := s.signUp("ana@example.com")
	payload := strings.Repeat("x", 160) // and about 100 bytes more for its row
	first, _ := s.call("PUT", "/v1/items", items(item("a", payload)), token)
	expect(t, "within the quota", first, 200)
	over, answer := s.call("PUT", "/v1/items", items(item("b", payload)), token)
	expect(t, "over it", over, 413)
	expect(t, "error", answer["error"], any("quota"))
	_, all := s.call("GET", "/v1/items?since=0", nil, token)
	expect(t, "nothing written", len(all["items"].([]any)), 1)
	replace, _ := s.call("PUT", "/v1/items", items(item("a", payload+"yyyy")), token)
	expect(t, "replacing an item counts it once", replace, 200)
}

func TestADeviceCanSignAnotherOneOut(t *testing.T) {
	s := start(t, false)
	phone := s.signUp("ana@example.com")
	_, session := s.call("POST", "/v1/sessions", map[string]string{"email": "ana@example.com", "authKey": key, "device": "TV"}, "")
	tv := session["token"].(string)
	_, list := s.call("GET", "/v1/devices", nil, phone)
	var tvID string
	for _, d := range list["devices"].([]any) {
		m := d.(map[string]any)
		expect(t, m["device"].(string)+" is this device", m["current"], any(m["device"] == "Phone"))
		if m["device"] == "TV" {
			tvID = m["id"].(string)
		}
	}
	other := s.signUp("bob@example.com")
	notTheirs, _ := s.call("DELETE", "/v1/devices/"+tvID, nil, other)
	expect(t, "not another account's device", notTheirs, 404)
	status, _ := s.call("DELETE", "/v1/devices/"+tvID, nil, phone)
	expect(t, "sign the TV out", status, 204)
	gone, _ := s.call("GET", "/v1/items?since=0", nil, tv)
	expect(t, "the TV gets nothing more", gone, 401)
	again, _ := s.call("DELETE", "/v1/devices/"+tvID, nil, phone)
	expect(t, "already gone", again, 404)
	bad, _ := s.call("DELETE", "/v1/devices/not-an-id", nil, phone)
	expect(t, "not an id", bad, 404)
}

func TestSessionsUnusedForTooLongEnd(t *testing.T) {
	s := startWith(t, Config{SignInsPerMinute: 10, SessionIdle: 150 * time.Millisecond})
	token := s.signUp("ana@example.com")
	used, _ := s.call("GET", "/v1/items?since=0", nil, token)
	expect(t, "in use", used, 200)
	time.Sleep(250 * time.Millisecond)
	idle, _ := s.call("GET", "/v1/items?since=0", nil, token)
	expect(t, "unused for too long", idle, 401)
}
