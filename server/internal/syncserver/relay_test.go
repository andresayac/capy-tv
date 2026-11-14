package syncserver

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// clock is the relay's time in tests, turned forward by hand.
type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *clock) add(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

type relayServer struct {
	*testServer
	clock *clock
}

// startRelay is a server whose relay runs on a test clock and answers long-polls after wait.
// setWait changes how long polls wait, as the relay reads it: under its lock, polls being answered
// meanwhile
func (s *relayServer) setWait(d time.Duration) {
	s.api.relay.mu.Lock()
	s.api.relay.wait = d
	s.api.relay.mu.Unlock()
}

func startRelay(t *testing.T, wait time.Duration, c Config, setup ...func(*relay)) *relayServer {
	store, err := OpenStore(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	clk := &clock{t: time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)}
	api := newAPI(store, c, clk.now)
	api.relay.wait = wait
	for _, f := range setup {
		f(api.relay)
	}
	server := httptest.NewServer(api.Handler())
	t.Cleanup(func() {
		api.Close()
		server.Close()
		store.Close()
	})
	return &relayServer{testServer: &testServer{T: t, api: api, url: server.URL}, clock: clk}
}

func (s *relayServer) open(headers ...string) (string, string) {
	s.Helper()
	status, body := s.call("POST", "/v1/relay", nil, "", headers...)
	if status != 201 {
		s.Fatalf("open: %d %v", status, body)
	}
	return body["room"].(string), body["secret"].(string)
}

// post sends a message as the devices do: the raw text.
func (s *relayServer) post(room, to, text string) (int, int64) {
	s.Helper()
	res, err := http.Post(s.url+"/v1/relay/"+room+"/"+to, "text/plain", strings.NewReader(text))
	if err != nil {
		s.Fatal(err)
	}
	defer res.Body.Close()
	var body struct{ Seq int64 }
	json.NewDecoder(res.Body).Decode(&body)
	return res.StatusCode, body.Seq
}

type polled struct {
	status   int
	messages []relayMessage
	next     int64
	peer     int // seconds since the other side read; -1 when it never did
}

// bodies is what came, as "seq:body" pairs.
func (p polled) bodies() string {
	var out []string
	for _, m := range p.messages {
		out = append(out, fmt.Sprintf("%d:%s", m.Seq, m.Body))
	}
	return strings.Join(out, " ")
}

func (s *relayServer) poll(room, to string, after int64) polled {
	s.Helper()
	res, err := http.Get(fmt.Sprintf("%s/v1/relay/%s/%s?after=%d", s.url, room, to, after))
	if err != nil {
		s.Fatal(err)
	}
	defer res.Body.Close()
	var body struct {
		Messages []relayMessage
		Next     int64
		Peer     int
	}
	json.NewDecoder(res.Body).Decode(&body)
	return polled{res.StatusCode, body.Messages, body.Next, body.Peer}
}

func (s *relayServer) rooms() int {
	s.api.relay.mu.Lock()
	defer s.api.relay.mu.Unlock()
	return len(s.api.relay.rooms)
}

func TestRelayCarriesMessagesBothWaysInOrder(t *testing.T) {
	s := startRelay(t, 50*time.Millisecond, Config{})
	room, secret := s.open()
	expect(t, "room: 128 bits in base64url", len(room), 22)
	expect(t, "secret: 128 bits in base64url", len(secret), 22)
	expect(t, "room and secret differ", room != secret, true)

	for i, text := range []string{"a", "b", "c"} {
		status, seq := s.post(room, "tv", text)
		expect(t, "post to the TV", status, 200)
		expect(t, "seq", seq, int64(i+1))
	}
	_, seq := s.post(room, "phone", "x")
	expect(t, "each direction counts from 1", seq, int64(1))

	all := s.poll(room, "tv", 0)
	expect(t, "poll", all.status, 200)
	expect(t, "everything for the TV", all.bodies(), "1:a 2:b 3:c")
	expect(t, "next is the last seq", all.next, int64(3))
	expect(t, "after=1", s.poll(room, "tv", 1).bodies(), "2:b 3:c")
	expect(t, "a second reader gets the same: reads take nothing away", s.poll(room, "tv", 0).bodies(), "1:a 2:b 3:c")
	expect(t, "for the phone", s.poll(room, "phone", 0).bodies(), "1:x")

	none := s.poll(room, "tv", 3)
	expect(t, "nothing new, after the wait", none.status, 200)
	expect(t, "no messages", len(none.messages), 0)
	expect(t, "next stays", none.next, int64(3))
	res, _ := http.Get(s.url + "/v1/relay/" + room + "/tv?after=3")
	var raw map[string]any
	json.NewDecoder(res.Body).Decode(&raw)
	res.Body.Close()
	expect(t, "an empty list, not null", fmt.Sprint(raw["messages"]), "[]")
	expect(t, "never cached", res.Header.Get("Cache-Control"), "no-store")
}

func TestRelayLongPollAnswersAsSoonAsAMessageComes(t *testing.T) {
	s := startRelay(t, 10*time.Second, Config{})
	room, _ := s.open()
	s.post(room, "phone", "old")

	got := make(chan polled, 2)
	for range 2 { // two phones on the same room
		go func() { got <- s.poll(room, "phone", 1) }()
	}
	time.Sleep(100 * time.Millisecond)
	s.post(room, "tv", "for the other side: no answer yet")
	select {
	case p := <-got:
		t.Fatalf("answered with a message for the other side: %v", p)
	case <-time.After(100 * time.Millisecond):
	}
	sent := time.Now()
	s.post(room, "phone", "new")
	for range 2 {
		select {
		case p := <-got:
			expect(t, "woken with the new message", p.bodies(), "2:new")
			expect(t, "next", p.next, int64(2))
		case <-time.After(3 * time.Second):
			t.Fatal("the long-poll did not wake up")
		}
	}
	if took := time.Since(sent); took > time.Second {
		t.Errorf("took %s", took)
	}
}

func TestRelayRoomsEndAQuarterOfAnHourAfterTheTVLeft(t *testing.T) {
	s := startRelay(t, 10*time.Millisecond, Config{})
	room, _ := s.open()
	expect(t, "the TV reads", s.poll(room, "tv", 0).status, 200)
	s.clock.add(14 * time.Minute)
	status, _ := s.post(room, "phone", "the TV says something")
	expect(t, "the TV's use within 15 minutes", status, 200)
	s.clock.add(14 * time.Minute)
	expect(t, "a poll of the TV's is a use too", s.poll(room, "tv", 0).status, 200)
	s.clock.add(14 * time.Minute)
	status, _ = s.post(room, "tv", "the phone, still on the page")
	expect(t, "a phone may use it meanwhile", status, 200)
	expect(t, "and read", s.poll(room, "phone", 0).status, 200)
	s.clock.add(2 * time.Minute)
	status, _ = s.post(room, "tv", "the TV switched off")
	expect(t, "15 minutes since the TV: what the phone does keeps nothing going", status, 404)
	expect(t, "the phone hears it is gone", s.poll(room, "phone", 0).status, 404)

	// One the TV never read from (opened, and left) goes in two minutes
	unread, _ := s.open()
	status, _ = s.post(unread, "tv", "x")
	expect(t, "there at first", status, 200)
	s.clock.add(2 * time.Minute)
	status, _ = s.post(unread, "tv", "x")
	expect(t, "never read by the TV", status, 404)

	// And none, however used, lasts over 12 hours: the TV opens another
	long, _ := s.open()
	for range 12 * 6 {
		expect(t, "used all along", s.poll(long, "tv", 0).status, 200)
		s.clock.add(10 * time.Minute)
	}
	expect(t, "12 hours on", s.poll(long, "tv", 0).status, 404)

	// A long-poll waiting on a room the sweep ends answers 404 at once
	s.setWait(10 * time.Second)
	other, _ := s.open()
	got := make(chan polled, 1)
	go func() { got <- s.poll(other, "phone", 0) }()
	time.Sleep(100 * time.Millisecond)
	s.clock.add(16 * time.Minute)
	s.api.relay.sweep()
	select {
	case p := <-got:
		expect(t, "the waiting poll", p.status, 404)
	case <-time.After(3 * time.Second):
		t.Fatal("the long-poll did not end with its room")
	}
	expect(t, "rooms left", s.rooms(), 0)
}

func TestRelayKeepsTheLatestMessagesOnly(t *testing.T) {
	s := startRelay(t, 50*time.Millisecond, Config{})
	room, _ := s.open()
	for i := range 70 {
		s.post(room, "tv", fmt.Sprint(i+1))
	}
	kept := s.poll(room, "tv", 0)
	expect(t, "64 per direction", len(kept.messages), 64)
	expect(t, "the oldest went", kept.messages[0].Seq, int64(7))
	expect(t, "next", kept.next, int64(70))

	// 16 MiB a room, both directions together: the oldest goes first, whichever side it was for
	other, _ := s.open()
	big := func(c string) string { return strings.Repeat(c, 6<<20) }
	s.post(other, "tv", big("a"))
	s.post(other, "phone", big("b"))
	status, seq := s.post(other, "tv", big("c"))
	expect(t, "posted", status, 200)
	expect(t, "seq", seq, int64(2))
	tv, phone := s.poll(other, "tv", 0), s.poll(other, "phone", 0)
	expect(t, "for the TV, the first went", len(tv.messages), 1)
	expect(t, "for the TV, the new one stays", tv.messages[0].Seq, int64(2))
	expect(t, "for the phone, it stays", len(phone.messages), 1)

	status, _ = s.post(other, "tv", strings.Repeat("d", 8<<20))
	expect(t, "8 MiB is allowed", status, 200)
	status, _ = s.post(other, "tv", strings.Repeat("d", 8<<20+1))
	expect(t, "more is not", status, 413)
	status, _ = s.post(other, "tv", "")
	expect(t, "nor nothing", status, 400)
	status, _ = s.post(other, "tv", "\xff\xfe")
	expect(t, "nor what is not text", status, 400)
}

func TestRelayKeepsSoMuchInAll(t *testing.T) {
	s := startRelay(t, 50*time.Millisecond, Config{}, func(rl *relay) { rl.maxBytes = 10 })
	first, secret := s.open()
	second, _ := s.open()
	status, _ := s.post(first, "tv", "123456")
	expect(t, "posted", status, 200)
	status, _ = s.post(second, "phone", "12345")
	expect(t, "past it, posts wait", status, 503)
	status, _ = s.post(second, "phone", "1234")
	expect(t, "up to it, they go", status, 200)

	// A room that ends gives back what it kept
	s.call("DELETE", "/v1/relay/"+first, nil, "", "X-Relay-Secret", secret)
	status, _ = s.post(second, "phone", "123456")
	expect(t, "after the room ended", status, 200)
}

func TestRelayHasRoomForSoManyAtATime(t *testing.T) {
	s := startRelay(t, time.Second, Config{}, func(rl *relay) { rl.maxRooms = 3 })
	for range 3 {
		s.open()
	}
	status, body := s.call("POST", "/v1/relay", nil, "")
	expect(t, "all rooms taken", status, 503)
	expect(t, "error", body["error"], any("busy"))
	s.clock.add(15 * time.Minute)
	s.open() // the expired ones make room
	expect(t, "rooms", s.rooms(), 1)
}

func TestRelayRoomsAreLimitedPerAddress(t *testing.T) {
	s := startRelay(t, time.Second, Config{TrustProxy: true})
	// Opened and closed again: 20 a minute from one network
	for range 20 {
		room, secret := s.open("X-Forwarded-For", "203.0.113.1")
		status, _ := s.call("DELETE", "/v1/relay/"+room, nil, "", "X-Relay-Secret", secret)
		expect(t, "closed", status, 204)
	}
	status, body := s.call("POST", "/v1/relay", nil, "", "X-Forwarded-For", "203.0.113.1")
	expect(t, "21st in a minute", status, 429)
	expect(t, "error", body["error"], any("rate_limited"))
	s.open("X-Forwarded-For", "203.0.113.1, 198.51.100.7") // the address the proxy saw counts
	s.clock.add(time.Minute + time.Second)
	s.open("X-Forwarded-For", "203.0.113.1")
}

func TestRelayLetsOneNetworkKeepSoManyRoomsAndSoMuch(t *testing.T) {
	s := startRelay(t, 10*time.Millisecond, Config{TrustProxy: true}, func(rl *relay) { rl.netBytes = 10 })
	var rooms []string
	for range relayNetRooms {
		room, _ := s.open("X-Forwarded-For", "203.0.113.1")
		rooms = append(rooms, room)
	}
	status, body := s.call("POST", "/v1/relay", nil, "", "X-Forwarded-For", "203.0.113.1")
	expect(t, "one more from the same address", status, 429)
	expect(t, "error", body["error"], any("rate_limited"))
	s.open("X-Forwarded-For", "198.51.100.7") // another network still has its own

	// What its rooms keep, together
	status, _ = s.post(rooms[0], "tv", "123456")
	expect(t, "within what it may keep", status, 200)
	status, _ = s.post(rooms[1], "tv", "123456")
	expect(t, "past it, in another of its rooms", status, 429)

	// Its rooms gone (never read by a TV), it may open again
	s.clock.add(relayUnread)
	s.open("X-Forwarded-For", "203.0.113.1")
	s.api.relay.mu.Lock()
	defer s.api.relay.mu.Unlock()
	expect(t, "what the network keeps went with its rooms", s.api.relay.nets[network("203.0.113.1")].bytes, 0)
}

func TestRelayLetsOneNetworkReadAndWaitSoMuchAtOnce(t *testing.T) {
	rl := newRelay(time.Now)
	var done []func()
	for range relayNetReading {
		d, refused := rl.startReading("a")
		expect(t, "reading", refused, 0)
		done = append(done, d)
	}
	_, refused := rl.startReading("a")
	expect(t, "one network past what it may", refused, http.StatusTooManyRequests)
	for i := range relayReading - relayNetReading {
		d, refused := rl.startReading(fmt.Sprint("net", i))
		expect(t, "other networks", refused, 0)
		done = append(done, d)
	}
	_, refused = rl.startReading("b")
	expect(t, "the relay past what it may", refused, http.StatusServiceUnavailable)
	for _, d := range done {
		d()
	}
	expect(t, "all given back", len(rl.nets), 0)

	// Polls: so many waiting from one network, over all its rooms
	id, _, _ := rl.open("a")
	var polls []func()
	for range relayNetPolls {
		other, _, _ := rl.open(fmt.Sprint("o", len(polls)))
		d, ok := rl.waiting(other, tvSide, "a")
		expect(t, "a poll", ok, true)
		polls = append(polls, d)
	}
	_, ok := rl.waiting(id, tvSide, "a")
	expect(t, "past what one network may have waiting", ok, false)
	for _, d := range polls {
		d()
	}
	_, ok = rl.waiting(id, tvSide, "a")
	expect(t, "given back", ok, true)
}

func TestRelaySaysWhetherTheOtherSideIsStillThere(t *testing.T) {
	s := startRelay(t, 10*time.Millisecond, Config{})
	room, _ := s.open()
	expect(t, "the TV has not read yet", s.poll(room, "phone", 0).peer, -1)
	s.poll(room, "tv", 0)
	s.clock.add(20 * time.Second)
	expect(t, "the TV read 20 seconds ago", s.poll(room, "phone", 0).peer, 20)
	s.clock.add(80 * time.Second)
	expect(t, "the TV has not read for 100 seconds: switched off", s.poll(room, "phone", 0).peer, 100)

	// While the TV waits for messages, it is there now
	s.setWait(5 * time.Second)
	got := make(chan polled, 1)
	go func() { got <- s.poll(room, "tv", 0) }()
	time.Sleep(100 * time.Millisecond)
	s.setWait(10 * time.Millisecond)
	expect(t, "the TV waiting", s.poll(room, "phone", 0).peer, 0)
	s.post(room, "tv", "wake")
	<-got
}

func TestRelayRoomsCloseWithTheirSecretOnly(t *testing.T) {
	s := startRelay(t, 10*time.Second, Config{})
	room, secret := s.open()
	_, other := s.open()

	got := make(chan polled, 1)
	go func() { got <- s.poll(room, "phone", 0) }()
	time.Sleep(100 * time.Millisecond)

	for _, given := range []string{"", other, "not base64!", secret + "x"} {
		status, body := s.call("DELETE", "/v1/relay/"+room, nil, "", "X-Relay-Secret", given)
		expect(t, "without its secret", status, 403)
		expect(t, "error", body["error"], any("secret"))
	}
	status, _ := s.call("DELETE", "/v1/relay/"+room, nil, "", "X-Relay-Secret", secret)
	expect(t, "with it", status, 204)
	select {
	case p := <-got:
		expect(t, "a poll waiting on it", p.status, 404)
	case <-time.After(3 * time.Second):
		t.Fatal("the long-poll did not end with its room")
	}
	status, body := s.call("DELETE", "/v1/relay/"+room, nil, "", "X-Relay-Secret", secret)
	expect(t, "closed already", status, 404)
	expect(t, "error", body["error"], any("room"))
	status, _ = s.post(room, "tv", "hello?")
	expect(t, "posting to it", status, 404)
}

func TestRelayAnswersForUnknownRoomsAndDirections(t *testing.T) {
	s := startRelay(t, 50*time.Millisecond, Config{})
	room, _ := s.open()
	unknown := strings.Repeat("A", 22)

	status, _ := s.post(unknown, "tv", "x")
	expect(t, "post to an unknown room", status, 404)
	expect(t, "poll an unknown room", s.poll(unknown, "phone", 0).status, 404)
	status, body := s.call("DELETE", "/v1/relay/"+unknown, nil, "", "X-Relay-Secret", "x")
	expect(t, "close an unknown room", status, 404)
	expect(t, "error", body["error"], any("room"))

	status, _ = s.post(room, "radio", "x")
	expect(t, "post to another direction", status, 400)
	expect(t, "poll another direction", s.poll(room, "radio", 0).status, 400)
	for _, after := range []string{"-1", "x", "1.5"} {
		status, _ := s.call("GET", "/v1/relay/"+room+"/tv?after="+after, nil, "")
		expect(t, "after="+after, status, 400)
	}
	status, _ = s.call("GET", "/v1/relay/"+room+"/tv", nil, "")
	expect(t, "without after: from the start", status, 200)
}

func TestShutdownEndsTheRelaysLongPolls(t *testing.T) {
	s := startRelay(t, 10*time.Second, Config{})
	room, _ := s.open()
	got := make(chan polled, 1)
	go func() { got <- s.poll(room, "tv", 0) }()
	time.Sleep(100 * time.Millisecond)
	s.api.Close()
	select {
	case p := <-got:
		expect(t, "rooms live in memory only: gone", p.status, 404)
	case <-time.After(3 * time.Second):
		t.Fatal("the long-poll held the shutdown up")
	}
}

func TestRelayAnswersInPiecesAndRefusesWhatWouldGrowInOne(t *testing.T) {
	s := startRelay(t, 50*time.Millisecond, Config{})
	room, _ := s.open()
	// Each answer holds 1 MiB past its first message; the rest comes in the next, after "next"
	for range 3 {
		s.post(room, "tv", strings.Repeat("a", 700<<10))
	}
	first := s.poll(room, "tv", 0)
	expect(t, "first answer", len(first.messages), 1)
	rest := s.poll(room, "tv", first.next)
	expect(t, "second answer", len(rest.messages), 1)
	expect(t, "it goes on from there", rest.messages[0].Seq, int64(2))

	// < and > travel as they are; control characters, six bytes each in JSON, not at all
	status, _ := s.post(room, "phone", strings.Repeat("<", 1<<10))
	expect(t, "angle brackets", status, 200)
	status, _ = s.post(room, "phone", "a\x01b")
	expect(t, "a control character", status, 400)

	// A room that is not there is said before its message is read
	status, _ = s.post("no-such-room", "tv", "hello")
	expect(t, "no room", status, 404)
}

func TestRelayLetsAFewPollsWaitOnASideAtOnce(t *testing.T) {
	s := startRelay(t, 2*time.Second, Config{})
	room, _ := s.open()
	results := make(chan int, relayPolls)
	for range relayPolls {
		go func() { results <- s.poll(room, "tv", 0).status }()
	}
	time.Sleep(300 * time.Millisecond) // all of them waiting
	expect(t, "one more", s.poll(room, "tv", 0).status, 429)
	expect(t, "the other side", s.poll(room, "phone", 0).status, 200)
	s.post(room, "tv", "wake")
	for range relayPolls {
		expect(t, "those waiting", <-results, 200)
	}
}
