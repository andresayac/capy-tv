package syncserver

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// fakeModel is a chat completions service that answers reply and keeps what it was sent.
type fakeModel struct {
	mu       sync.Mutex
	status   int
	reply    string
	requests []map[string]any
	auth     []string
}

func (f *fakeModel) start(t *testing.T) string {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		f.requests = append(f.requests, body)
		f.auth = append(f.auth, r.Header.Get("Authorization"))
		if r.URL.Path != "/v1/chat/completions" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		if f.status != 0 {
			w.WriteHeader(f.status)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{
			"choices": []any{map[string]any{"message": map[string]string{"role": "assistant", "content": f.reply}}},
		})
	}))
	t.Cleanup(server.Close)
	return server.URL + "/v1/"
}

func (f *fakeModel) answer(status int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.status = status
}

func (f *fakeModel) sent() []map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]map[string]any(nil), f.requests...)
}

func aiServer(t *testing.T, model *fakeModel, perHour int) *testServer {
	return startWith(t, Config{
		SignInsPerMinute: 10,
		AI:               AIConfig{BaseURL: model.start(t), Model: "family-model", APIKey: "owner-key", PerHour: perHour},
	})
}

var question = map[string]any{
	"messages": []map[string]string{{"role": "system", "content": "Pick titles."}, {"role": "user", "content": "Watched: Ozark"}},
	"json":     true,
}

func TestTheServersModelAnswersSignedInDevicesWithTheOwnersKey(t *testing.T) {
	model := &fakeModel{reply: `{"picks":[]}`}
	s := aiServer(t, model, 30)
	token := s.signUp("ana@example.com")

	status, body := s.call("GET", "/v1/ai", nil, token)
	if status != http.StatusOK || body["model"] != "family-model" {
		t.Fatalf("info: %d %v", status, body)
	}
	status, body = s.call("POST", "/v1/ai/chat", question, token)
	if status != http.StatusOK || body["content"] != `{"picks":[]}` {
		t.Fatalf("chat: %d %v", status, body)
	}
	sent := model.sent()[0]
	if sent["model"] != "family-model" || model.auth[0] != "Bearer owner-key" {
		t.Fatalf("the server's model and key: %v %q", sent["model"], model.auth[0])
	}
	if format, _ := sent["response_format"].(map[string]any); format["type"] != "json_object" {
		t.Fatalf("JSON asked for: %v", sent["response_format"])
	}
	if msgs := sent["messages"].([]any); len(msgs) != 2 || !strings.Contains(msgs[1].(map[string]any)["content"].(string), "Ozark") {
		t.Fatalf("messages forwarded: %v", msgs)
	}

	// The device cannot pick another model, nor use it without a session
	s.call("POST", "/v1/ai/chat", map[string]any{"model": "expensive", "messages": question["messages"]}, token)
	if got := model.sent()[1]["model"]; got != "family-model" {
		t.Fatalf("model chosen by the device: %v", got)
	}
	if status, _ := s.call("POST", "/v1/ai/chat", question, ""); status != http.StatusUnauthorized {
		t.Fatalf("without a session: %d", status)
	}
}

func TestAServerWithoutAIDoesNotOfferIt(t *testing.T) {
	s := start(t, false)
	token := s.signUp("ana@example.com")
	if status, body := s.call("GET", "/v1/ai", nil, token); status != http.StatusNotFound || body["error"] != "no_ai" {
		t.Fatalf("info: %d %v", status, body)
	}
	if status, _ := s.call("POST", "/v1/ai/chat", question, token); status != http.StatusNotFound {
		t.Fatalf("chat: %d", status)
	}
}

func TestEachAccountHasItsAIRequestsPerHour(t *testing.T) {
	model := &fakeModel{reply: "ok"}
	s := aiServer(t, model, 2)
	ana, bea := s.signUp("ana@example.com"), s.signUp("bea@example.com")
	for i := range 2 {
		if status, _ := s.call("POST", "/v1/ai/chat", question, ana); status != http.StatusOK {
			t.Fatalf("request %d: %d", i, status)
		}
	}
	if status, body := s.call("POST", "/v1/ai/chat", question, ana); status != http.StatusTooManyRequests {
		t.Fatalf("over the limit: %d %v", status, body)
	}
	if status, _ := s.call("POST", "/v1/ai/chat", question, bea); status != http.StatusOK {
		t.Fatalf("another account: %d", status)
	}
}

func TestTheModelHasACapForAllAccountsAndForItsAnswers(t *testing.T) {
	model := &fakeModel{reply: `{"picks":[]}`}
	s := startWith(t, Config{
		SignInsPerMinute: 10,
		AI:               AIConfig{BaseURL: model.start(t), Model: "m", PerHour: 30, PerHourTotal: 2, MaxTokens: 4000},
	})
	ana, bea := s.signUp("ana@example.com"), s.signUp("bea@example.com")
	expect(t, "ana", fmt.Sprint(s.call("POST", "/v1/ai/chat", question, ana)), "200 map[content:{\"picks\":[]}]")
	status, _ := s.call("POST", "/v1/ai/chat", question, bea)
	expect(t, "bea", status, 200)
	status, _ = s.call("POST", "/v1/ai/chat", question, bea)
	expect(t, "a third from anyone, over the server's cap", status, http.StatusTooManyRequests)
	model.mu.Lock()
	defer model.mu.Unlock()
	expect(t, "max_tokens asked", fmt.Sprint(model.requests[0]["max_tokens"]), "4000")
}

func TestBadAIRequestsAndTheServicesTroubles(t *testing.T) {
	model := &fakeModel{}
	s := aiServer(t, model, 100)
	token := s.signUp("ana@example.com")
	for _, bad := range []any{
		map[string]any{"messages": []any{}},
		map[string]any{"messages": []map[string]string{{"role": "tool", "content": "x"}}},
		map[string]any{"messages": []map[string]string{{"role": "user", "content": ""}}},
		// A conversation, as a general chat would be: not what the apps ask
		map[string]any{"messages": []map[string]string{{"role": "user", "content": "a"}, {"role": "assistant", "content": "b"}, {"role": "user", "content": "c"}}},
		map[string]any{"messages": []map[string]string{{"role": "user", "content": "a"}, {"role": "user", "content": "b"}}},
		map[string]any{"messages": []map[string]string{{"role": "system", "content": "a"}}},
	} {
		if status, _ := s.call("POST", "/v1/ai/chat", bad, token); status != http.StatusBadRequest {
			t.Fatalf("%v: %d", bad, status)
		}
	}
	huge := map[string]any{"messages": []map[string]string{{"role": "user", "content": strings.Repeat("x", maxAIBody)}}}
	if status, _ := s.call("POST", "/v1/ai/chat", huge, token); status != http.StatusRequestEntityTooLarge {
		t.Fatalf("too large: %d", status)
	}
	for status, code := range map[int]string{401: "ai_key", 404: "ai_model", 500: "ai_busy", 429: "ai_busy", 418: "ai_unavailable"} {
		model.answer(status)
		if got, body := s.call("POST", "/v1/ai/chat", question, token); got != http.StatusBadGateway || body["error"] != code {
			t.Fatalf("service %d: %d %v", status, got, body)
		}
	}
	// A service that does not know the JSON option is asked again without it, then without a
	// temperature (models that take only their own)
	model.answer(http.StatusBadRequest)
	before := len(model.sent())
	s.call("POST", "/v1/ai/chat", question, token)
	sent := model.sent()
	if len(sent) != before+3 || sent[before+1]["response_format"] != nil || sent[before+2]["temperature"] != nil {
		t.Fatalf("asked again without the JSON option, then without a temperature: %v", sent[before:])
	}
}
