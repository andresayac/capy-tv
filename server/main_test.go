package main

import "testing"

func TestLogsLeaveRoomsAndInstallCodesOut(t *testing.T) {
	for path, want := range map[string]string{
		"/v1/items":                "/v1/items",
		"/v1/relay/abc":            "/v1/relay/{room}",
		"/v1/relay/abc/tv":         "/v1/relay/{room}/tv",
		"/i/K7Q3X":                 "/i/{code}",
		"/i/K7Q3X/armeabi-v7a":     "/i/{code}/armeabi-v7a",
		"/v1/app/CapyTV-64bit.apk": "/v1/app/CapyTV-64bit.apk",
		"/companion":               "/companion",
		// Paths the server redirects to their clean form, or takes in capitals
		"/i//K7Q3X":            "/i/{code}",
		"/i/./K7Q3X":           "/i/{code}",
		"//i/K7Q3X":            "/i/{code}",
		"/I/K7Q3X":             "/i/{code}",
		"/i/K7Q3X/":            "/i/{code}",
		"/I/K7Q3X/ARM64-V8A":   "/i/{code}/arm64-v8a",
		"/i/x/K7Q3X":           "/i/{code}/...",
		"/i/K7Q3X/universal/x": "/i/{code}/...",
		"/v1/relay//abc/tv":    "/v1/relay/{room}/tv",
		"//v1/items":           "//v1/items",
	} {
		if got := logPath(path); got != want {
			t.Errorf("%s: got %s, want %s", path, got, want)
		}
	}
}
