package syncserver

import (
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"sync"
	"time"
	"unicode/utf8"
)

// The relay ("phone bridge") lets the companion page on a phone reach a device that cannot listen
// on a port of its own: the Samsung TV app. The TV opens a room here and puts its id in the QR,
// next to the session key; then each side posts messages for the other and long-polls for its own.
// Every message is sealed with that key (ChaCha20-Poly1305, app/assets/companion/seal.js), which
// never reaches this server: it carries what it cannot read. There is no account: the room's id is
// what lets a phone in, so it is as random as a session token. Rooms live in memory only.

const (
	relayRooms        = 500              // at the same time
	relayKept         = 64               // messages kept per direction
	relayMessageBytes = 8 << 20          // a backup, sealed twice, fits
	relayRoomBytes    = 16 << 20         // all a room keeps; the oldest messages go first
	relayBytes        = 256 << 20        // all the rooms keep together; past it, posts wait
	relayIdle         = 15 * time.Minute // a room ends this long after its last use
	relayWait         = 25 * time.Second // a long-poll answers after this when nothing comes
	relayPerMinute    = 20               // rooms opened per client network
	relayAnswerBytes  = 1 << 20          // of messages in one answer to a poll, past the first
	relayPolls        = 4                // polls waiting on one side of a room at the same time
	relayWriteWait    = time.Minute      // to send an answer to a client that reads slowly
	relayUnread       = 2 * time.Minute  // a room the TV never read from ends this soon
	relayLife         = 12 * time.Hour   // no room lasts longer: the TV opens another
	relayReading      = 32               // posts whose body is being read at the same time

	// What one client network may have of it at a time (see clientKey): no one can take it all.
	// A home's TVs and phones are one network: a few rooms, a few polls.
	relayNetRooms   = 8        // rooms it opened and that still live
	relayNetBytes   = 64 << 20 // of the messages those rooms keep
	relayNetPolls   = 32       // polls waiting
	relayNetReading = 8        // posts being read
)

// The two directions of a room
var relayTo = map[string]int{"tv": 0, "phone": 1}

type relay struct {
	mu       sync.Mutex
	rooms    map[string]*room
	now      func() time.Time
	wait     time.Duration // how long a poll waits for messages; read under mu
	maxRooms int
	maxBytes int // of the messages kept in all the rooms
	netRooms int // rooms one network may keep (relayNetRooms; tests set fewer)
	netBytes int // of the messages one network's rooms may keep (relayNetBytes)
	bytes    int
	reading  int // posts whose body is being read
	nets     map[string]*netUse
	limit    *limiter
	stop     chan struct{}
	once     sync.Once
}

// What one client network has of the relay now: the rooms it opened and what they keep, its polls
// waiting and its posts being read.
type netUse struct{ rooms, bytes, polls, reading int }

type room struct {
	secret []byte // closes it
	net    string // the network that opened it: what it keeps counts against that network
	polls  [2]int // waiting on each side
	opened time.Time
	seen   time.Time    // the TV's last use: a room the TV left ends relayIdle later
	polled [2]time.Time // each side's last poll: whether the other is still there
	bytes  int          // of all the messages kept
	order  int64        // counts messages in both directions, to drop the oldest first
	boxes  [2]mailbox
	wake   chan struct{} // closed, and replaced, when a message comes or the room ends
}

const tvSide, phoneSide = 0, 1

// expired reports whether the room is over: the TV left it a while ago, never read from it, or it
// lived as long as one may.
func (rm *room) expired(now time.Time) bool {
	return now.Sub(rm.seen) >= relayIdle || now.Sub(rm.opened) >= relayLife ||
		rm.polled[tvSide].IsZero() && now.Sub(rm.opened) >= relayUnread
}

type mailbox struct {
	last     int64 // the seq of the latest message posted
	messages []relayMessage
}

type relayMessage struct {
	Seq   int64  `json:"seq"`
	Body  string `json:"body"`
	order int64
}

func newRelay(now func() time.Time) *relay {
	return &relay{
		rooms:    map[string]*room{},
		now:      now,
		wait:     relayWait,
		maxRooms: relayRooms,
		maxBytes: relayBytes,
		netRooms: relayNetRooms,
		netBytes: relayNetBytes,
		nets:     map[string]*netUse{},
		limit:    newLimiter(relayPerMinute, time.Minute, now),
		stop:     make(chan struct{}),
	}
}

// use is what [net] has of the relay (mu held); tidy forgets it once it has nothing.
func (rl *relay) use(net string) *netUse {
	u := rl.nets[net]
	if u == nil {
		u = &netUse{}
		rl.nets[net] = u
	}
	return u
}

func (rl *relay) tidy(net string) {
	if u := rl.nets[net]; u != nil && *u == (netUse{}) {
		delete(rl.nets, net)
	}
}

// run sweeps out expired rooms every minute until close.
func (rl *relay) run() {
	tick := time.NewTicker(time.Minute)
	defer tick.Stop()
	for {
		select {
		case <-tick.C:
			rl.sweep()
		case <-rl.stop:
			return
		}
	}
}

// close ends every room, so long-polls answer at once rather than hold up a shutdown.
func (rl *relay) close() {
	rl.once.Do(func() { close(rl.stop) })
	rl.mu.Lock()
	defer rl.mu.Unlock()
	for id, rm := range rl.rooms {
		rl.end(id, rm)
	}
}

func (rl *relay) sweep() {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	rl.sweepLocked()
}

func (rl *relay) sweepLocked() {
	now := rl.now()
	for id, rm := range rl.rooms {
		if rm.expired(now) {
			rl.end(id, rm)
		}
	}
}

// end removes a room and wakes whoever waits on it (mu held).
func (rl *relay) end(id string, rm *room) {
	delete(rl.rooms, id)
	rl.bytes -= rm.bytes
	u := rl.use(rm.net)
	u.rooms--
	u.bytes -= rm.bytes
	rl.tidy(rm.net)
	close(rm.wake)
}

// live returns the room, nil when there is none or it expired (mu held). Only what the TV does
// ([byTV]) keeps it going: a phone left on the page alone does not, so with the TV gone the room
// ends, and the phone hears it.
func (rl *relay) live(id string, byTV bool) *room {
	rm := rl.rooms[id]
	if rm == nil {
		return nil
	}
	now := rl.now()
	if rm.expired(now) {
		rl.end(id, rm)
		return nil
	}
	if byTV {
		rm.seen = now
	}
	return rm
}

var (
	errNoRoom    = errors.New("no such room")
	errRelayFull = errors.New("the relay is full")
	errNetFull   = errors.New("this network has as much of the relay as it may")
)

// open makes a room for a client of [net]: errRelayFull when there are too many already,
// errNetFull when that network has as many as it may.
func (rl *relay) open(net string) (id, secret string, err error) {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	if len(rl.rooms) >= rl.maxRooms || rl.use(net).rooms >= rl.netRooms {
		rl.sweepLocked()
	}
	u := rl.use(net)
	switch {
	case len(rl.rooms) >= rl.maxRooms:
		rl.tidy(net)
		return "", "", errRelayFull
	case u.rooms >= rl.netRooms:
		return "", "", errNetFull
	}
	id = base64.RawURLEncoding.EncodeToString(randomBytes(16))
	s := randomBytes(16)
	now := rl.now()
	rl.rooms[id] = &room{secret: s, net: net, opened: now, seen: now, wake: make(chan struct{})}
	u.rooms++
	return id, base64.RawURLEncoding.EncodeToString(s), nil
}

// post adds a message for one side and returns its seq: errNoRoom when the room is gone,
// errRelayFull when all the rooms together keep too much already, errNetFull when the rooms of the
// network that opened this one do.
func (rl *relay) post(id string, to int, body string) (int64, error) {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	rm := rl.live(id, to == phoneSide) // the TV saying something to the phone
	if rm == nil {
		return 0, errNoRoom
	}
	if rl.bytes+len(body) > rl.maxBytes {
		return 0, errRelayFull
	}
	u := rl.use(rm.net)
	if u.bytes+len(body) > rl.netBytes {
		return 0, errNetFull
	}
	box := &rm.boxes[to]
	box.last++
	rm.order++
	box.messages = append(box.messages, relayMessage{Seq: box.last, Body: body, order: rm.order})
	dropped := -len(body)
	if len(box.messages) > relayKept {
		dropped += box.drop()
	}
	for rm.bytes-dropped > relayRoomBytes {
		oldest := &rm.boxes[0]
		if other := &rm.boxes[1]; len(oldest.messages) == 0 ||
			(len(other.messages) > 0 && other.messages[0].order < oldest.messages[0].order) {
			oldest = other
		}
		dropped += oldest.drop()
	}
	rm.bytes -= dropped
	rl.bytes -= dropped
	u.bytes -= dropped
	close(rm.wake)
	rm.wake = make(chan struct{})
	return box.last, nil
}

// drop forgets the oldest message and returns its size. Shifting, rather than reslicing, lets go
// of its body at once.
func (b *mailbox) drop() int {
	size := len(b.messages[0].Body)
	copy(b.messages, b.messages[1:])
	b.messages[len(b.messages)-1] = relayMessage{}
	b.messages = b.messages[:len(b.messages)-1]
	return size
}

// after copies the messages with a seq above n, up to relayAnswerBytes of them past the first: the
// box changes once mu is released. What is left comes in the next poll, after the last given.
func (b *mailbox) after(n int64) []relayMessage {
	for i, m := range b.messages {
		if m.Seq > n {
			end, size := i+1, len(m.Body)
			for end < len(b.messages) && size+len(b.messages[end].Body) <= relayAnswerBytes {
				size += len(b.messages[end].Body)
				end++
			}
			return append([]relayMessage(nil), b.messages[i:end]...)
		}
	}
	return []relayMessage{}
}

// exists reports whether there is a room id, without counting it as a use.
func (rl *relay) exists(id string) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	rm := rl.rooms[id]
	return rm != nil && !rm.expired(rl.now())
}

// startReading takes one of the posts whose body may be read at the same time, for a client of [net],
// and gives it back with done: 0, or the status to refuse it with (503 for the relay's, 429 for
// that network's).
func (rl *relay) startReading(net string) (done func(), refused int) {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	u := rl.use(net)
	switch {
	case rl.reading >= relayReading:
		rl.tidy(net)
		return nil, http.StatusServiceUnavailable
	case u.reading >= relayNetReading:
		return nil, http.StatusTooManyRequests
	}
	rl.reading++
	u.reading++
	return func() {
		rl.mu.Lock()
		defer rl.mu.Unlock()
		rl.reading--
		rl.use(net).reading--
		rl.tidy(net)
	}, 0
}

// waiting takes one of the polls a side of a room may have at once, and one of those a client of
// [net] may have waiting, and gives them back with done; false when either are all taken (or the
// room is gone, then poll says so).
func (rl *relay) waiting(id string, to int, net string) (done func(), ok bool) {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	rm := rl.rooms[id]
	if rm == nil {
		return func() {}, true
	}
	u := rl.use(net)
	if rm.polls[to] >= relayPolls || u.polls >= relayNetPolls {
		rl.tidy(net)
		return nil, false
	}
	rm.polls[to]++
	u.polls++
	return func() {
		rl.mu.Lock()
		defer rl.mu.Unlock()
		rm.polls[to]--
		rl.use(net).polls--
		rl.tidy(net)
	}, true
}

// poll answers with one side's messages after seq n, waiting for some up to rl.wait; false when
// the room is gone, or ends while waiting. [peer] is how many seconds ago the other side last
// read (0 while it waits for messages now, -1 when it never did): whether it is still there.
func (rl *relay) poll(ctx context.Context, id string, to int, n int64) (list []relayMessage, peer int, found bool) {
	rl.mu.Lock()
	wait := rl.wait
	rl.mu.Unlock()
	timer := time.NewTimer(wait)
	defer timer.Stop()
	for done := false; ; {
		rl.mu.Lock()
		rm := rl.live(id, to == tvSide) // the TV reading what is for it
		if rm == nil {
			rl.mu.Unlock()
			return nil, 0, false
		}
		now := rl.now()
		rm.polled[to] = now
		list, wake := rm.boxes[to].after(n), rm.wake
		other := 1 - to
		switch {
		case rm.polls[other] > 0:
			peer = 0
		case rm.polled[other].IsZero():
			peer = -1
		default:
			peer = int(now.Sub(rm.polled[other]) / time.Second)
		}
		rl.mu.Unlock()
		if len(list) > 0 || done {
			return list, peer, true
		}
		select {
		case <-wake: // a message, perhaps for the other side, or the room ended
		case <-timer.C:
			done = true
		case <-ctx.Done():
			done = true
		}
	}
}

// remove closes a room for whoever has its secret: found reports whether there was one.
func (rl *relay) remove(id, secret string) (found, allowed bool) {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	rm := rl.live(id, false)
	if rm == nil {
		return false, false
	}
	given, err := base64.RawURLEncoding.DecodeString(secret)
	if err != nil || subtle.ConstantTimeCompare(given, rm.secret) != 1 {
		return true, false
	}
	rl.end(id, rm)
	return true, true
}

// Requests

func (a *API) relayOpen(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	net := a.clientKey(r)
	if a.relay.limit.tooMany("relay:" + net) {
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	id, secret, err := a.relay.open(net)
	switch err {
	case errRelayFull:
		fail(w, http.StatusServiceUnavailable, "busy")
		return
	case errNetFull:
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"room": id, "secret": secret})
}

func (a *API) relayPost(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	to, known := relayTo[r.PathValue("to")]
	if !known {
		fail(w, http.StatusBadRequest, "to")
		return
	}
	// Neither for a room that is not there nor past the size it says it is: nothing read for those
	if r.ContentLength > relayMessageBytes {
		fail(w, http.StatusRequestEntityTooLarge, "too_large")
		return
	}
	if !a.relay.exists(r.PathValue("room")) {
		fail(w, http.StatusNotFound, "room")
		return
	}
	// So many bodies read at once, and so many from one network: no one holds the memory of all
	done, refused := a.relay.startReading(a.clientKey(r))
	if refused != 0 {
		code := "rate_limited"
		if refused == http.StatusServiceUnavailable {
			code = "busy"
		}
		fail(w, refused, code)
		return
	}
	defer done()
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, relayMessageBytes))
	var tooLarge *http.MaxBytesError
	switch {
	case errors.As(err, &tooLarge):
		fail(w, http.StatusRequestEntityTooLarge, "too_large")
		return
	case err != nil || len(body) == 0 || !utf8.Valid(body) || hasControl(body):
		// Sealed messages are base64; control characters would take six bytes each in an answer
		fail(w, http.StatusBadRequest, "invalid")
		return
	}
	seq, err := a.relay.post(r.PathValue("room"), to, string(body))
	switch err {
	case errNoRoom:
		fail(w, http.StatusNotFound, "room")
		return
	case errRelayFull:
		fail(w, http.StatusServiceUnavailable, "busy")
		return
	case errNetFull:
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	writeJSON(w, http.StatusOK, map[string]int64{"seq": seq})
}

func (a *API) relayPoll(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	to, known := relayTo[r.PathValue("to")]
	if !known {
		fail(w, http.StatusBadRequest, "to")
		return
	}
	n := int64(0)
	if q := r.URL.Query().Get("after"); q != "" {
		var err error
		if n, err = strconv.ParseInt(q, 10, 64); err != nil || n < 0 {
			fail(w, http.StatusBadRequest, "invalid")
			return
		}
	}
	done, free := a.relay.waiting(r.PathValue("room"), to, a.clientKey(r))
	if !free {
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	defer done()
	list, peer, found := a.relay.poll(r.Context(), r.PathValue("room"), to, n)
	if !found {
		fail(w, http.StatusNotFound, "room")
		return
	}
	if len(list) > 0 {
		n = list[len(list)-1].Seq
	}
	// A client that does not read its answer lets go of it after a while
	http.NewResponseController(w).SetWriteDeadline(time.Now().Add(relayWriteWait))
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false) // < and > as they are, not six bytes each
	// peer: whether the other side is still there (the phone says "connected" by it)
	enc.Encode(map[string]any{"messages": list, "next": n, "peer": peer})
}

func hasControl(b []byte) bool {
	for _, c := range b {
		if c < 0x20 || c == 0x7f {
			return true
		}
	}
	return false
}

func (a *API) relayClose(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	found, allowed := a.relay.remove(r.PathValue("room"), r.Header.Get("X-Relay-Secret"))
	switch {
	case !found:
		fail(w, http.StatusNotFound, "room")
	case !allowed:
		fail(w, http.StatusForbidden, "secret")
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}
