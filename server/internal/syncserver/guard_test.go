package syncserver

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// listen opens the live socket of the session [token] and reads its hello.
func (s *testServer) listen(token string) (*websocket.Conn, context.Context) {
	s.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	s.Cleanup(cancel)
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(s.url, "http")+"/v1/live",
		&websocket.DialOptions{HTTPHeader: http.Header{"Authorization": {"Bearer " + token}}})
	if err != nil {
		s.Fatal(err)
	}
	s.Cleanup(func() { conn.CloseNow() })
	if _, _, err := conn.Read(ctx); err != nil {
		s.Fatal(err)
	}
	return conn, ctx
}

// cut says whether the socket ends as a session that no longer counts.
func cut(ctx context.Context, conn *websocket.Conn) bool {
	for {
		_, _, err := conn.Read(ctx)
		if err != nil {
			return websocket.CloseStatus(err) == websocket.StatusPolicyViolation
		}
	}
}

func (s *testServer) signIn(email, device string) string {
	s.Helper()
	status, body := s.call("POST", "/v1/sessions", map[string]string{"email": email, "authKey": key, "device": device}, "")
	if status != 200 {
		s.Fatalf("sign in: %d %v", status, body)
	}
	return body["token"].(string)
}

func TestTheOtherDevicesSocketsEndWithTheirSessions(t *testing.T) {
	s := start(t, false)
	phone := s.signUp("ana@example.com")

	// A new password: the others are out, the one that changed it is not
	tv := s.signIn("ana@example.com", "TV")
	tvSocket, ctx := s.listen(tv)
	phoneSocket, _ := s.listen(phone)
	status, _ := s.call("PUT", "/v1/account/password", map[string]string{"proof": key, "authKey": key, "passwordKeys": passwordKeys}, phone)
	expect(t, "new password", status, 204)
	expect(t, "the TV's socket after a new password", cut(ctx, tvSocket), true)
	quiet, stop := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer stop()
	if _, _, err := phoneSocket.Read(quiet); websocket.CloseStatus(err) == websocket.StatusPolicyViolation {
		t.Error("the device that changed the password lost its socket")
	}

	// A device signed out from another one
	tv = s.signIn("ana@example.com", "TV")
	tvSocket, ctx = s.listen(tv)
	_, list := s.call("GET", "/v1/devices", nil, phone)
	var tvID string
	for _, d := range list["devices"].([]any) {
		if d := d.(map[string]any); d["device"] == "TV" {
			tvID = d["id"].(string)
		}
	}
	status, _ = s.call("DELETE", "/v1/devices/"+tvID, nil, phone)
	expect(t, "sign the TV out", status, 204)
	expect(t, "the TV's socket once signed out from the phone", cut(ctx, tvSocket), true)

	// The account deleted: every socket
	tv = s.signIn("ana@example.com", "TV")
	tvSocket, ctx = s.listen(tv)
	status, _ = s.call("DELETE", "/v1/account", map[string]string{"proof": key}, phone)
	expect(t, "delete the account", status, 204)
	expect(t, "the TV's socket once the account is gone", cut(ctx, tvSocket), true)
}

func TestTheWriterHearsNothingOfItsOwnWrite(t *testing.T) {
	s := start(t, false)
	phone := s.signUp("ana@example.com")
	socket, _ := s.listen(phone)
	s.call("PUT", "/v1/items", items(item("a", "cA==")), phone)
	quiet, stop := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer stop()
	if _, data, err := socket.Read(quiet); err == nil {
		t.Errorf("the writer heard its own write: %s", data)
	}
}

func TestOneEmailIsGuessedAtTenTimesAMinuteFromAnywhereNear(t *testing.T) {
	// Behind a proxy: addresses from X-Forwarded-For, each a new one, all in one network
	s := start(t, true)
	s.signUp("ana@example.com")
	status := 0
	for i := 1; i <= 11; i++ {
		status, _ = s.call("POST", "/v1/sessions", map[string]string{"email": "ana@example.com", "authKey": otherKey}, "",
			"X-Forwarded-For", fmt.Sprintf("198.51.%d.%d", 100, i))
	}
	expect(t, "eleventh wrong guess from another address nearby", status, 429)

	// Without trusting a proxy, what it says of the address is not believed
	s = start(t, false)
	for i := 1; i <= 11; i++ {
		status, _ = s.call("POST", "/v1/sessions", map[string]string{"email": fmt.Sprintf("u%d@example.com", i), "authKey": key}, "",
			"X-Forwarded-For", fmt.Sprintf("203.0.%d.1", i))
	}
	expect(t, "eleventh attempt, the header saying another address each time", status, 429)
}

func TestAProofIsGuessedAtTenTimesAMinute(t *testing.T) {
	s := start(t, false)
	phone := s.signUp("ana@example.com")
	status := 0
	for i := 0; i < 11; i++ {
		status, _ = s.call("PUT", "/v1/account/password", map[string]string{"proof": otherKey, "authKey": key, "passwordKeys": passwordKeys}, phone)
	}
	expect(t, "eleventh wrong proof", status, 429)
}

func TestTheLimiterForgetsOldKeysAndHasACeiling(t *testing.T) {
	clk := &clock{t: time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)}
	l := newLimiter(10, time.Minute, clk.now)
	for i := 0; i <= 10000; i++ {
		l.tooMany(fmt.Sprintf("old%d", i))
	}
	clk.add(2 * time.Minute)
	l.tooMany("new")
	expect(t, "keys left after the sweep", len(l.hits), 1)

	// Full: a key not seen yet waits; one known goes on being counted
	for i := len(l.hits); i < maxKeys; i++ {
		l.hits[fmt.Sprintf("k%d", i)] = []time.Time{clk.now()}
	}
	expect(t, "a new key when full", l.tooMany("stranger"), true)
	expect(t, "a known key when full", l.tooMany("new"), false)

	// Over the first key's limit, the next ones are not counted
	m := newLimiter(1, time.Minute, clk.now)
	m.tooMany("ip")
	expect(t, "second from the address", m.tooMany("ip", "account"), true)
	_, counted := m.hits["account"]
	expect(t, "the account counted for it", counted, false)
}

func TestUsingADeviceKeepsItsSession(t *testing.T) {
	store, err := OpenStore(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	clk := &clock{t: time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)}
	api := newAPI(store, Config{SignInsPerMinute: 10, QuotaBytes: 4 << 20, SessionIdle: 180 * 24 * time.Hour}, clk.now)
	server := httptest.NewServer(api.Handler())
	t.Cleanup(func() {
		api.Close()
		server.Close()
		store.Close()
	})
	s := &testServer{T: t, api: api, url: server.URL}
	phone := s.signUp("ana@example.com")
	seen := func() string {
		_, list := s.call("GET", "/v1/devices", nil, phone)
		return fmt.Sprint(list["devices"].([]any)[0].(map[string]any)["seen"])
	}

	clk.add(100 * 24 * time.Hour)
	before := seen()
	clk.add(100 * 24 * time.Hour) // 200 days since it was made, 100 since it was used
	status, _ := s.call("GET", "/v1/items", nil, phone)
	expect(t, "used within the 180 days", status, 200)
	if seen() == before {
		t.Error("using it did not note when it was seen")
	}
	clk.add(181 * 24 * time.Hour)
	status, _ = s.call("GET", "/v1/items", nil, phone)
	expect(t, "unused for 181 days", status, 401)
}

// startOnClock is a server on a test clock.
func startOnClock(t *testing.T, c Config) (*testServer, *clock) {
	store, err := OpenStore(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	clk := &clock{t: time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)}
	api := newAPI(store, c, clk.now)
	server := httptest.NewServer(api.Handler())
	t.Cleanup(func() {
		api.Close()
		server.Close()
		store.Close()
	})
	return &testServer{T: t, api: api, url: server.URL}, clk
}

func TestOneEmailIsGuessedAtAHundredTimesADayFromOneNetwork(t *testing.T) {
	s, clk := startOnClock(t, Config{SignInsPerMinute: 10, TrustProxy: true})
	s.signUp("ana@example.com")
	signIn := func(k, from string) int {
		status, _ := s.call("POST", "/v1/sessions", map[string]string{"email": "ana@example.com", "authKey": k}, "",
			"X-Forwarded-For", from)
		return status
	}
	for i := range failuresPerDay {
		if i%25 == 0 {
			clk.add(time.Hour + time.Second) // within what an hour allows
		} else if i%9 == 0 {
			clk.add(time.Minute + time.Second) // and a minute
		}
		expect(t, fmt.Sprint("wrong guess ", i+1), signIn(otherKey, fmt.Sprintf("198.51.100.%d", i+1)), 401)
	}
	clk.add(2 * time.Hour)
	expect(t, "one more within the day, however spread", signIn(otherKey, "198.51.7.7"), 429)
	expect(t, "the right key from that network too", signIn(key, "198.51.7.8"), 429)
	expect(t, "the owner, elsewhere", signIn(key, "203.0.113.9"), 200)
	clk.add(24 * time.Hour)
	expect(t, "a day later", signIn(key, "198.51.7.8"), 200)
}

func TestSigningInClearsOutTheSessionsGoneStale(t *testing.T) {
	s, clk := startOnClock(t, Config{SignInsPerMinute: 10, SessionIdle: 180 * 24 * time.Hour})
	s.signUp("ana@example.com")
	sessions := func() (n int) {
		s.api.store.db.QueryRow(`SELECT COUNT(*) FROM sessions`).Scan(&n)
		return
	}
	expect(t, "the first device's", sessions(), 1)
	clk.add(181 * 24 * time.Hour)
	status, _ := s.call("POST", "/v1/sessions", map[string]string{"email": "ana@example.com", "authKey": key}, "")
	expect(t, "signed in again", status, 200)
	expect(t, "the stale one gone from the database, not only refused", sessions(), 1)
}

func TestNoMoreAccountsThanTheOwnerAllows(t *testing.T) {
	s := startWith(t, Config{SignInsPerMinute: 10, QuotaBytes: 4 << 20, MaxAccounts: 1})
	s.signUp("ana@example.com")
	status, body := s.call("POST", "/v1/accounts", newAccount("bea@example.com"), "")
	expect(t, "the second account", fmt.Sprint(status, " ", body["error"]), "403 full")
}
