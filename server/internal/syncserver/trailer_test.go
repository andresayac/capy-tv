package syncserver

import (
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestTheTrailerPageEmbedsTheVideoAskedFor(t *testing.T) {
	srv := start(t, false)

	res, err := http.Get(srv.url + "/trailer?v=dQw4w9WgXcQ")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != 200 || !strings.HasPrefix(res.Header.Get("Content-Type"), "text/html") {
		t.Fatalf("got %d %s", res.StatusCode, res.Header.Get("Content-Type"))
	}
	page := string(body)
	for _, want := range []string{`videoId:"dQw4w9WgXcQ"`, "start: 6 ,end: 33 ", "postMessage"} {
		if !strings.Contains(page, want) {
			t.Errorf("the page lacks %s", want)
		}
	}
}

func TestTheTrailerPageTakesNothingButAVideoID(t *testing.T) {
	srv := start(t, false)

	for _, q := range []string{"", "?v=", "?v=abc", `?v="+alert(1)+"`, "?v=a/b/c/d/e/f"} {
		res, err := http.Get(srv.url + "/trailer" + q)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		if res.StatusCode != http.StatusNotFound {
			t.Errorf("/trailer%s: got %d, want 404", q, res.StatusCode)
		}
	}
}
