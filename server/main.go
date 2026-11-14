// Capy TV sync server.
//
//	PORT          default 8080 (0 picks a free one, printed at startup)
//	HOST          the address to listen on, default all of them ("127.0.0.1": this machine only, for tests)
//	DATA          SQLite file, default data/sync.db (":memory:" keeps nothing, for tests)
//	TRUST_PROXY=1 when it is only reachable through a reverse proxy (client address from X-Forwarded-For;
//	              "true" works too): then HOST=127.0.0.1, or a firewall, so no one reaches it directly
//	SIGNIN_LIMIT  sign-up and sign-in attempts per minute, per address and per email; default 10
//	MAX_ACCOUNTS  no more accounts than this are created (0, the default: no limit)
//	SIGNUP_CODE   when set, creating an account needs this code (an invitation): a private server.
//	              With none, no new accounts, unless SIGNUP_OPEN=1: anyone who reaches it may make one
//	MAX_DATA_MB   the whole database's cap, default 2048; past it, no new accounts nor more data
//	              (what is there stays, deletions go on). 0 is no limit
//	QUOTA_MB      space per account, default 50; 0 is no limit
//	SESSION_DAYS  devices unused for this many days are signed out, default 180; 0 is never
//	AI_MODEL      a language model for the devices' recommendations (none when unset), through any
//	              service with the OpenAI chat API: AI_BASE_URL (default https://ollama.com/v1) and
//	              AI_API_KEY. AI_PER_HOUR requests per account and hour, default 30; AI_PER_HOUR_TOTAL
//	              from all accounts together, default 300 (0: none); AI_MAX_TOKENS the longest
//	              answer asked for, default 4000
//	APP_DIR       the app's releases for the devices to update themselves (the APKs and app.json
//	              of the app's tool/build_apk.sh), default "app" beside DATA
//
// "server healthcheck" asks a running server on PORT whether it is up (exit code 0 or 1), for containers.
// "server backup FILE" writes a consistent copy of DATA to FILE, also while the server runs.
// Run it behind HTTPS (Caddy, Traefik, nginx...): see README.md.
package main

import (
	"bufio"
	"context"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"iptv-player/server/internal/syncserver"
)

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	port := env("PORT", "8080")
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(healthcheck(port))
	}

	path := env("DATA", "data/sync.db")
	if len(os.Args) > 1 && os.Args[1] == "backup" {
		if len(os.Args) != 3 {
			log.Fatal("usage: server backup FILE")
		}
		accounts, err := syncserver.Backup(path, os.Args[2])
		if err != nil {
			log.Fatal(err)
		}
		if st, err := os.Stat(os.Args[2]); err == nil {
			log.Printf("backup of %s in %s: %d accounts, %d bytes", path, os.Args[2], accounts, st.Size())
		}
		return
	}
	if path != ":memory:" {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			log.Fatal(err)
		}
	}
	store, err := syncserver.OpenStore(path)
	if err != nil {
		log.Fatal(err)
	}
	number := func(name, fallback string, min int) int {
		n, err := strconv.Atoi(env(name, fallback))
		if err != nil || n < min {
			log.Fatalf("%s must be a whole number, %d or more", name, min)
		}
		return n
	}
	appDir := os.Getenv("APP_DIR")
	if appDir == "" && path != ":memory:" {
		appDir = filepath.Join(filepath.Dir(path), "app")
	}
	// "1", or "true" and the like: not ignored for being written another way
	truthy := func(name string) bool {
		return map[string]bool{"1": true, "true": true, "yes": true, "on": true}[strings.ToLower(os.Getenv(name))]
	}
	trustProxy := truthy("TRUST_PROXY")
	code := strings.TrimSpace(os.Getenv("SIGNUP_CODE"))
	open := truthy("SIGNUP_OPEN")
	api := syncserver.NewAPI(store, syncserver.Config{
		TrustProxy:       trustProxy,
		SignInsPerMinute: number("SIGNIN_LIMIT", "10", 1),
		SignupCode:       code,
		NoSignups:        code == "" && !open,
		MaxDataBytes:     int64(number("MAX_DATA_MB", "2048", 0)) << 20,
		MaxAccounts:      number("MAX_ACCOUNTS", "0", 0),
		QuotaBytes:       int64(number("QUOTA_MB", "50", 0)) << 20,
		SessionIdle:      time.Duration(number("SESSION_DAYS", "180", 0)) * 24 * time.Hour,
		AI: syncserver.AIConfig{
			BaseURL:      env("AI_BASE_URL", "https://ollama.com/v1"),
			Model:        os.Getenv("AI_MODEL"),
			APIKey:       os.Getenv("AI_API_KEY"),
			PerHour:      number("AI_PER_HOUR", "30", 1),
			PerHourTotal: number("AI_PER_HOUR_TOTAL", "300", 0),
			MaxTokens:    number("AI_MAX_TOKENS", "4000", 0),
		},
		AppDir: appDir,
	})
	if model := os.Getenv("AI_MODEL"); model != "" {
		log.Printf("recommendations with %s: titles devices send for them are forwarded to it, never stored", model)
	}
	switch {
	case code != "":
		log.Print("new accounts with the invitation code (SIGNUP_CODE) only")
	case open:
		log.Print("anyone who reaches this server can create an account (SIGNUP_OPEN): set SIGNUP_CODE to make it private")
	default:
		log.Print("no new accounts: set SIGNUP_CODE (an invitation code) for people to create them, or SIGNUP_OPEN=1 for anyone")
	}
	if trustProxy {
		log.Print("client addresses from X-Forwarded-For: it must be reachable through the reverse proxy only (HOST=127.0.0.1)")
	} else if v := os.Getenv("TRUST_PROXY"); v != "" {
		log.Printf("TRUST_PROXY=%q is not on: client addresses are the connections' own", v)
	}
	server := &http.Server{
		Handler:           logRequests(api.Handler()),
		ReadHeaderTimeout: 10 * time.Second,
		// A body sent a byte at a time, or an answer never read, lets go after these. Writing takes
		// longer than a recommendation may (aiTimeout); APKs and the long-lived routes set their own
		ReadTimeout:    2 * time.Minute,
		WriteTimeout:   3 * time.Minute,
		IdleTimeout:    2 * time.Minute,
		MaxHeaderBytes: 32 << 10,
	}
	server.RegisterOnShutdown(api.Close)

	listener, err := net.Listen("tcp", net.JoinHostPort(os.Getenv("HOST"), port))
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("Capy TV sync server on :%d, data in %s", listener.Addr().(*net.TCPAddr).Port, path)

	// Containers stop with SIGTERM: finish what is in flight, then close the database cleanly
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	done := make(chan struct{})
	go func() {
		defer close(done)
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		server.Shutdown(shutdown)
	}()
	if err := server.Serve(listener); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
	<-done // Serve returns as Shutdown starts: the requests still in flight need the database
	store.Close()
}

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func healthcheck(port string) int {
	client := http.Client{Timeout: 3 * time.Second}
	res, err := client.Get("http://127.0.0.1:" + port + "/healthz")
	if err != nil {
		return 1
	}
	res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}

// logRequests logs method, path and status only: never bodies, tokens or query strings.
func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(sw, r)
		log.Printf("%s %s %d %s", r.Method, logPath(r.URL.Path), sw.status, time.Since(start).Round(time.Millisecond))
	})
}

// abis are Android's processor names, the files of an install link.
var abis = map[string]bool{
	"arm64-v8a": true, "armeabi-v7a": true, "armeabi": true, "x86": true, "x86_64": true, "riscv64": true, "universal": true,
}

// logPath leaves relay rooms and install codes out: knowing one is what lets a phone in, or a
// device take the app, as a token does. Also from a path the server redirects to its clean form,
// or takes in capitals.
func logPath(raw string) string {
	clean := strings.ToLower(path.Clean(raw))
	if rest, found := strings.CutPrefix(clean, "/i/"); found {
		_, abi, more := strings.Cut(rest, "/")
		switch {
		case !more:
			return "/i/{code}"
		case abis[abi]:
			return "/i/{code}/" + abi
		default:
			return "/i/{code}/..."
		}
	}
	rest, found := strings.CutPrefix(clean, "/v1/relay/")
	if !found {
		return raw
	}
	if _, to, more := strings.Cut(rest, "/"); more {
		return "/v1/relay/{room}/" + to
	}
	return "/v1/relay/{room}"
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(status int) {
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

// Hijack lets WebSockets through the logging wrapper.
func (w *statusWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	w.status = http.StatusSwitchingProtocols
	return http.NewResponseController(w.ResponseWriter).Hijack()
}

func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }
