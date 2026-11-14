package syncserver

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// hub keeps the open sockets of every account, to tell its other devices when something changed.
type hub struct {
	mu        sync.Mutex
	byAccount map[int64]map[*listener]struct{}
}

type listener struct {
	session string
	send    chan []byte
	done    chan struct{}
	once    sync.Once
}

func (l *listener) stop() { l.once.Do(func() { close(l.done) }) }

func newHub() *hub { return &hub{byAccount: map[int64]map[*listener]struct{}{}} }

func (h *hub) add(account int64, l *listener) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.byAccount[account] == nil {
		h.byAccount[account] = map[*listener]struct{}{}
	}
	h.byAccount[account][l] = struct{}{}
}

func (h *hub) remove(account int64, l *listener) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.byAccount[account], l)
	if len(h.byAccount[account]) == 0 {
		delete(h.byAccount, account)
	}
}

type liveMessage struct {
	Type string `json:"type"`
	Rev  int64  `json:"rev"`
}

// notify tells the account's devices, except the session that made the change, to come for it.
func (h *hub) notify(account int64, except string, rev int64) {
	msg, _ := json.Marshal(liveMessage{Type: "changed", Rev: rev})
	h.mu.Lock()
	defer h.mu.Unlock()
	for l := range h.byAccount[account] {
		if l.session == except {
			continue
		}
		select {
		case l.send <- msg:
		default: // a device this far behind catches up on the next message or when it reconnects
		}
	}
}

// close ends the sockets of one session, or of every session of the account when session is "".
func (h *hub) close(account int64, session string) {
	h.closeWhere(account, func(s string) bool { return session == "" || s == session })
}

// closeOthers ends the sockets of every session of the account but one.
func (h *hub) closeOthers(account int64, session string) {
	h.closeWhere(account, func(s string) bool { return s != session })
}

func (h *hub) closeWhere(account int64, match func(session string) bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for l := range h.byAccount[account] {
		if match(l.session) {
			l.stop()
		}
	}
}

func (h *hub) closeAll() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, listeners := range h.byAccount {
		for l := range listeners {
			l.stop()
		}
	}
}

// The live socket's subprotocol, for clients that name one.
const liveProtocol = "capy-sync"

// liveSocket sends {"type":"hello","rev":n} once, then {"type":"changed","rev":n} whenever another
// device of the account writes. Devices only listen; changes go through PUT /v1/items.
func (a *API) liveSocket(w http.ResponseWriter, r *http.Request, au auth) {
	rev, err := a.store.Revision(r.Context(), au.accountID)
	if !ok(w, err) {
		return
	}
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// Picked when the device offers it, as the TV app does next to its token (never echoed)
		Subprotocols: []string{liveProtocol},
		// Browsers send their page's origin, and the TV app's page has none on the web. The token, not
		// a cookie, is what lets a device in, so another site's page could not use this socket anyway.
		InsecureSkipVerify: true,
	})
	if err != nil {
		return // Accept has answered
	}
	defer conn.CloseNow()
	l := &listener{session: au.session, send: make(chan []byte, 8), done: make(chan struct{})}
	a.live.add(au.accountID, l)
	defer a.live.remove(au.accountID, l)

	ctx := conn.CloseRead(context.Background()) // answers pings and notices when the device leaves
	hello, _ := json.Marshal(liveMessage{Type: "hello", Rev: rev.Rev})
	if write(ctx, conn, hello) != nil {
		return
	}
	ping := time.NewTicker(30 * time.Second) // keeps proxies from dropping a quiet connection
	defer ping.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-l.done:
			conn.Close(websocket.StatusPolicyViolation, "signed out")
			return
		case msg := <-l.send:
			if write(ctx, conn, msg) != nil {
				return
			}
		case <-ping.C:
			pctx, cancel := context.WithTimeout(ctx, 10*time.Second)
			err := conn.Ping(pctx)
			cancel()
			if err != nil {
				conn.Close(websocket.StatusGoingAway, "no answer")
				return
			}
		}
	}
}

func write(ctx context.Context, conn *websocket.Conn, msg []byte) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	return conn.Write(ctx, websocket.MessageText, msg)
}
