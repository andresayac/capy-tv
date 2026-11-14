package syncserver

import (
	"sync"
	"time"
)

// limiter allows a number of attempts per key within a sliding window. Ten tries a minute per
// address and per account for signing up or in: auth keys are long, but the password behind one
// may not be.
type limiter struct {
	mu     sync.Mutex
	max    int
	window time.Duration
	now    func() time.Time
	hits   map[string][]time.Time
	swept  time.Time // the last time keys nobody used were forgotten
}

// maxKeys is as many keys as are kept: past it, a key not seen yet waits for the next sweep, so a
// flood of addresses neither fills the memory nor gets past the limit.
const maxKeys = 100000

func newLimiter(max int, window time.Duration, now func() time.Time) *limiter {
	return &limiter{max: max, window: window, now: now, hits: map[string][]time.Time{}}
}

// tooMany counts an attempt under every key and reports whether any of them is over the limit.
func (l *limiter) tooMany(keys ...string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	limited := false
	for _, key := range keys {
		if limited {
			break // the first key over its limit is enough: the next ones are not counted (nor kept)
		}
		if _, known := l.hits[key]; !known && len(l.hits) >= maxKeys {
			limited = true
			break
		}
		recent := l.recent(key, now)
		recent = append(recent, now)
		if len(recent) > l.max+1 {
			recent = recent[len(recent)-l.max-1:]
		}
		l.hits[key] = recent
		limited = limited || len(recent) > l.max
	}
	// Forget keys nobody used for a while, so the map does not grow forever; once a window at most,
	// not at every attempt
	if len(l.hits) > 10000 && now.Sub(l.swept) > l.window {
		l.swept = now
		for key, hits := range l.hits {
			if len(hits) == 0 || now.Sub(hits[len(hits)-1]) > l.window { // hits are in order
				delete(l.hits, key)
			}
		}
	}
	return limited
}

// over reports whether the key used up its attempts, without counting one: for limits on
// failures, counted with tooMany once they happen.
func (l *limiter) over(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if _, found := l.hits[key]; !found {
		return false
	}
	recent := l.recent(key, l.now())
	l.hits[key] = recent
	return len(recent) >= l.max
}

// recent filters the key's hits in place: store the result back.
func (l *limiter) recent(key string, now time.Time) []time.Time {
	kept := l.hits[key][:0]
	for _, t := range l.hits[key] {
		if now.Sub(t) <= l.window {
			kept = append(kept, t)
		}
	}
	return kept
}
