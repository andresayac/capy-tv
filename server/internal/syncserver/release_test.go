package syncserver

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

// releaseServer serves a folder with the files given, by name.
func releaseServer(t *testing.T, files map[string]string) (*testServer, string) {
	dir := t.TempDir()
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return startWith(t, Config{SignInsPerMinute: 10, AppDir: dir}), dir
}

const manifest = `{"version": "0.2.0", "build": 412, "notes": "Pause live",
	"files": {"arm64-v8a": "CapyTV-64bit.apk", "armeabi-v7a": "CapyTV-32bit.apk"}}`

func sum(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

// get is a GET with a token and maybe a range, answering the status and the body.
func (s *testServer) get(path, token, ranges string) (int, string) {
	s.Helper()
	req, _ := http.NewRequest("GET", s.url+path, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if ranges != "" {
		req.Header.Set("Range", ranges)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		s.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	return res.StatusCode, string(body)
}

func TestSignedInDevicesFindTheReleaseAndDownloadTheirFile(t *testing.T) {
	s, _ := releaseServer(t, map[string]string{
		"app.json": manifest, "CapyTV-64bit.apk": "sixty-four", "CapyTV-32bit.apk": "thirty-two",
	})
	token := s.signUp("a@example.com")

	status, body := s.call("GET", "/v1/app", nil, token)
	expect(t, "status", status, 200)
	expect(t, "version", body["version"], any("0.2.0"))
	expect(t, "build", body["build"], any(412.0))
	expect(t, "notes", body["notes"], any("Pause live"))
	file := body["files"].(map[string]any)["arm64-v8a"].(map[string]any)
	expect(t, "name", file["name"], any("CapyTV-64bit.apk"))
	expect(t, "size", file["size"], any(10.0))
	expect(t, "sha256", file["sha256"], any(sum("sixty-four")))

	status, apk := s.get("/v1/app/CapyTV-64bit.apk", token, "")
	expect(t, "download", status, 200)
	expect(t, "content", apk, "sixty-four")
	// A download that was cut goes on from where it was
	status, rest := s.get("/v1/app/CapyTV-64bit.apk", token, "bytes=6-")
	expect(t, "range", status, http.StatusPartialContent)
	expect(t, "rest", rest, "four")

	// Signed in only: the APKs carry the owner's keys
	status, _ = s.call("GET", "/v1/app", nil, "")
	expect(t, "release without a session", status, 401)
	status, _ = s.get("/v1/app/CapyTV-64bit.apk", "", "")
	expect(t, "file without a session", status, 401)

	// Nor kept by a cache in front, which would hand it to anyone
	req, _ := http.NewRequest("HEAD", s.url+"/v1/app/CapyTV-64bit.apk", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	expect(t, "never cached", res.Header.Get("Cache-Control"), "private, no-store")
}

func TestANewFileInTheFolderIsHashedAgain(t *testing.T) {
	s, dir := releaseServer(t, map[string]string{"app.json": manifest, "CapyTV-64bit.apk": "first"})
	token := s.signUp("a@example.com")
	sha := func() any {
		_, body := s.call("GET", "/v1/app", nil, token)
		return body["files"].(map[string]any)["arm64-v8a"].(map[string]any)["sha256"]
	}
	expect(t, "first", sha(), any(sum("first")))
	if err := os.WriteFile(filepath.Join(dir, "CapyTV-64bit.apk"), []byte("the second"), 0o644); err != nil {
		t.Fatal(err)
	}
	expect(t, "replaced", sha(), any(sum("the second")))
}

func TestNoReleaseAndNothingOutsideIt(t *testing.T) {
	// No folder, an empty one, one without the manifest's files
	none := startWith(t, Config{SignInsPerMinute: 10})
	status, body := none.call("GET", "/v1/app", nil, none.signUp("a@example.com"))
	expect(t, "no folder", status, 404)
	expect(t, "code", body["error"], any("no_app"))
	empty, _ := releaseServer(t, map[string]string{})
	status, _ = empty.call("GET", "/v1/app", nil, empty.signUp("a@example.com"))
	expect(t, "empty folder", status, 404)
	copying, _ := releaseServer(t, map[string]string{"app.json": manifest})
	status, _ = copying.call("GET", "/v1/app", nil, copying.signUp("a@example.com"))
	expect(t, "files not there yet", status, 404)

	// Half there: only the file that is
	s, _ := releaseServer(t, map[string]string{
		"app.json": manifest, "CapyTV-32bit.apk": "thirty-two", "other.apk": "not in the release",
	})
	token := s.signUp("a@example.com")
	status, body = s.call("GET", "/v1/app", nil, token)
	expect(t, "half there", status, 200)
	files := body["files"].(map[string]any)
	expect(t, "files", len(files), 1)
	expect(t, "the 32-bit one", files["armeabi-v7a"] != nil, true)

	for _, path := range []string{
		"/v1/app/CapyTV-64bit.apk", // named, not there
		"/v1/app/other.apk",        // there, not in the release
		"/v1/app/app.json",
		"/v1/app/..%2Fapp.json",
		"/v1/app/%2E%2E%2F%2E%2E%2Fgo.mod",
	} {
		status, _ := s.get(path, token, "")
		expect(t, path, status, 404)
	}
}

func TestAManifestThatNamesSomethingElseIsTheOwnersMistake(t *testing.T) {
	s, _ := releaseServer(t, map[string]string{"app.json": `{"build": 3, "files": {"arm64-v8a": "../sync.db"}}`})
	status, _ := s.call("GET", "/v1/app", nil, s.signUp("a@example.com"))
	expect(t, "status", status, 500)
	s, _ = releaseServer(t, map[string]string{"app.json": `{"version": "1", "files": {}}`})
	status, _ = s.call("GET", "/v1/app", nil, s.signUp("a@example.com"))
	expect(t, "no build number", status, 500)
}

func TestTheWindowsInstallerIsHandedOutAsTheAPKsAre(t *testing.T) {
	s, _ := releaseServer(t, map[string]string{
		"app.json":         `{"version": "0.2.0", "build": 412, "files": {"arm64-v8a": "CapyTV-64bit.apk", "windows-x64": "CapyTV-Setup.exe"}}`,
		"CapyTV-64bit.apk": "sixty-four",
		"CapyTV-Setup.exe": "installer",
	})
	token := s.signUp("a@example.com")
	status, body := s.call("GET", "/v1/app", nil, token)
	expect(t, "status", status, 200)
	files := body["files"].(map[string]any)
	expect(t, "the installer's digest", files["windows-x64"].(map[string]any)["sha256"], any(sum("installer")))
	req, _ := http.NewRequest("GET", s.url+"/v1/app/CapyTV-Setup.exe", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	got, _ := io.ReadAll(res.Body)
	expect(t, "the installer", string(got), "installer")
	expect(t, "said to be a program", res.Header.Get("Content-Type"), "application/vnd.microsoft.portable-executable")
}
