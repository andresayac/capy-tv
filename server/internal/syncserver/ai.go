package syncserver

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

// AIConfig is a language model the server's owner offers to the accounts' devices, for the
// recommendations each profile gets: any service with the OpenAI chat completions API. The key
// stays here, so no device has it, and only signed-in devices can use it.
//
// The titles a device sends to get recommendations go through this server in the clear, unlike
// everything else: they are forwarded to the model and never stored nor logged.
type AIConfig struct {
	BaseURL string // up to the API version, such as https://ollama.com/v1
	Model   string // empty: no AI on this server
	APIKey  string
	PerHour int // requests per account and hour; protects the owner's quota
	// PerHourTotal is requests from all accounts together in an hour; 0 is none
	PerHourTotal int
	// MaxTokens is the longest answer asked for: room for a reasoning model's thinking and the picks,
	// not for a chat
	MaxTokens int
}

const (
	maxAIBody     = 256 << 10
	maxAIMessages = 8
	aiTimeout     = 2 * time.Minute // large models in the cloud take their time
)

type aiMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// aiInfo says whether this server offers AI, and which model.
func (a *API) aiInfo(w http.ResponseWriter, _ *http.Request, _ auth) {
	if a.config.AI.Model == "" {
		fail(w, http.StatusNotFound, "no_ai")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"model": a.config.AI.Model})
}

// aiChat forwards a conversation to the model and answers with its reply: {"content": "..."}.
// The device chooses neither the model nor the service.
func (a *API) aiChat(w http.ResponseWriter, r *http.Request, au auth) {
	ai := a.config.AI
	if ai.Model == "" {
		fail(w, http.StatusNotFound, "no_ai")
		return
	}
	var body struct {
		Messages []aiMessage `json:"messages"`
		JSON     bool        `json:"json"` // asks for a JSON answer
	}
	err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxAIBody)).Decode(&body)
	var tooLarge *http.MaxBytesError
	if errors.As(err, &tooLarge) {
		fail(w, http.StatusRequestEntityTooLarge, "too_large")
		return
	}
	if err != nil || len(body.Messages) == 0 || len(body.Messages) > maxAIMessages {
		fail(w, http.StatusBadRequest, "invalid")
		return
	}
	// What the apps send: a system message at most, then one from the user. No conversation, so the
	// server's model is no general chat on the owner's quota
	roles := map[string]int{}
	for _, m := range body.Messages {
		roles[m.Role]++
		if (m.Role != "system" && m.Role != "user") || m.Content == "" {
			fail(w, http.StatusBadRequest, "invalid")
			return
		}
	}
	if roles["system"] > 1 || roles["user"] != 1 || body.Messages[len(body.Messages)-1].Role != "user" {
		fail(w, http.StatusBadRequest, "invalid")
		return
	}
	if a.aiLimit.tooMany(fmt.Sprint("account:", au.accountID)) ||
		(a.aiTotal != nil && a.aiTotal.tooMany("all")) {
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	content, status, err := a.askModel(r.Context(), body.Messages, body.JSON)
	if err != nil {
		log.Printf("ai: %v", err) // never what was asked
		code := map[int]string{http.StatusUnauthorized: "ai_key", http.StatusForbidden: "ai_key", http.StatusNotFound: "ai_model"}[status]
		if status == http.StatusTooManyRequests || status >= 500 {
			code = "ai_busy" // out of quota or down for now
		}
		if code == "" {
			code = "ai_unavailable"
		}
		fail(w, http.StatusBadGateway, code)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"content": content})
}

// askModel sends messages to the configured service. A service that does not know the JSON
// format option is asked again without it. On failure, also the service's status, if any.
func (a *API) askModel(ctx context.Context, messages []aiMessage, wantJSON bool) (string, int, error) {
	ai := a.config.AI
	ctx, cancel := context.WithTimeout(ctx, aiTimeout)
	defer cancel()
	send := func(jsonFormat, temperature bool) (*http.Response, error) {
		req := map[string]any{"model": ai.Model, "messages": messages}
		if temperature {
			req["temperature"] = 0.7
		}
		if ai.MaxTokens > 0 {
			req["max_tokens"] = ai.MaxTokens
		}
		if jsonFormat {
			req["response_format"] = map[string]string{"type": "json_object"}
		}
		payload, _ := json.Marshal(req)
		httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(ai.BaseURL, "/")+"/chat/completions", bytes.NewReader(payload))
		if err != nil {
			return nil, err
		}
		httpReq.Header.Set("Content-Type", "application/json")
		if ai.APIKey != "" {
			httpReq.Header.Set("Authorization", "Bearer "+ai.APIKey)
		}
		return a.aiClient.Do(httpReq)
	}
	res, err := send(wantJSON, true)
	if err == nil && wantJSON && res.StatusCode == http.StatusBadRequest {
		res.Body.Close()
		res, err = send(false, true)
	}
	// Models that take only their own temperature (some reasoning ones)
	if err == nil && res.StatusCode == http.StatusBadRequest {
		res.Body.Close()
		res, err = send(false, false)
	}
	if err != nil {
		return "", 0, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		io.Copy(io.Discard, io.LimitReader(res.Body, 1<<16))
		return "", res.StatusCode, fmt.Errorf("the model's service answered %d", res.StatusCode)
	}
	var answer struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 4<<20)).Decode(&answer); err != nil || len(answer.Choices) == 0 {
		return "", res.StatusCode, errors.New("the model's service gave no answer")
	}
	return answer.Choices[0].Message.Content, res.StatusCode, nil
}
