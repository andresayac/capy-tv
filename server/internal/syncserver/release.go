package syncserver

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// The app's releases, so the accounts' devices can update themselves. Config.AppDir holds the
// APKs that the app's tool/build_apk.sh makes and the app.json it writes beside them:
//
//	{"version": "0.1.0", "build": 412, "notes": "...",
//	 "files": {"arm64-v8a": "CapyTV-64bit.apk", "armeabi-v7a": "CapyTV-32bit.apk"}}
//
// one file per processor, by Android's ABI names ("universal" for one for all), and the Windows
// installer of the app's tool/build_windows.sh as "windows-x64" (CapyTV-Setup.exe). A device asks
// GET /v1/app and, when the build there is newer than its own, offers it, then downloads its file
// from GET /v1/app/{file}. Both for signed-in devices only: the APKs carry what the owner built
// into them (the TMDB key); a device without a session gets them through a temporary install
// link (link.go). The folder is read on each request, so a new release needs no restart.

const releaseManifest = "app.json"

type release struct {
	Version string                 `json:"version"`
	Build   int                    `json:"build"`
	Notes   string                 `json:"notes,omitempty"`
	Files   map[string]releaseFile `json:"files"` // by ABI
}

type releaseFile struct {
	Name   string `json:"name"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"` // hex; the device checks what it downloaded against it
}

func (r *release) has(name string) bool {
	for _, f := range r.Files {
		if f.Name == name {
			return true
		}
	}
	return false
}

// releases reads the folder, hashing each file once for as long as it stays the same.
type releases struct {
	dir    string
	mu     sync.Mutex
	hashes map[string]fileHash // by name
}

type fileHash struct {
	size int64
	mod  time.Time
	sum  string
}

func newReleases(dir string) *releases { return &releases{dir: dir, hashes: map[string]fileHash{}} }

// current is the release in the folder, or nil when there is none. Files the manifest names but
// the folder lacks (still being copied) are left out.
func (r *releases) current() (*release, error) {
	if r.dir == "" {
		return nil, nil
	}
	root, err := os.OpenRoot(r.dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer root.Close()
	raw, err := root.ReadFile(releaseManifest)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var m struct {
		Version string            `json:"version"`
		Build   int               `json:"build"`
		Notes   string            `json:"notes"`
		Files   map[string]string `json:"files"`
	}
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("%s: %w", releaseManifest, err)
	}
	if m.Build <= 0 {
		return nil, fmt.Errorf("%s: no build number", releaseManifest)
	}
	rel := &release{Version: m.Version, Build: m.Build, Notes: m.Notes, Files: map[string]releaseFile{}}
	for abi, name := range m.Files {
		if !releaseName(name) {
			return nil, fmt.Errorf("%s: %q is not an APK in the folder", releaseManifest, name)
		}
		file, err := r.describe(root, name)
		if errors.Is(err, fs.ErrNotExist) {
			log.Printf("app: %s names %s, which is not there", releaseManifest, name)
			continue
		}
		if err != nil {
			return nil, err
		}
		rel.Files[abi] = file
	}
	if len(rel.Files) == 0 {
		return nil, nil
	}
	return rel, nil
}

// releaseName is an APK, or the Windows installer, right in the folder.
func releaseName(name string) bool {
	return (strings.HasSuffix(name, ".apk") || strings.HasSuffix(name, ".exe")) &&
		!strings.ContainsAny(name, `/\`) && !strings.HasPrefix(name, ".")
}

func (r *releases) describe(root *os.Root, name string) (releaseFile, error) {
	st, err := root.Stat(name)
	if err != nil {
		return releaseFile{}, err
	}
	if !st.Mode().IsRegular() {
		return releaseFile{}, fs.ErrNotExist
	}
	r.mu.Lock()
	known, found := r.hashes[name]
	r.mu.Unlock()
	if !found || known.size != st.Size() || !known.mod.Equal(st.ModTime()) {
		f, err := root.Open(name)
		if err != nil {
			return releaseFile{}, err
		}
		defer f.Close()
		h := sha256.New()
		if _, err := io.Copy(h, f); err != nil {
			return releaseFile{}, err
		}
		known = fileHash{size: st.Size(), mod: st.ModTime(), sum: hex.EncodeToString(h.Sum(nil))}
		r.mu.Lock()
		r.hashes[name] = known
		r.mu.Unlock()
	}
	return releaseFile{Name: name, Size: known.size, SHA256: known.sum}, nil
}

// appRelease answers the release the server has: {version, build, notes?, files: {abi: {name,
// size, sha256}}} · 404 no_app.
func (a *API) appRelease(w http.ResponseWriter, _ *http.Request, _ auth) {
	rel, err := a.releases.current()
	if !ok(w, err) {
		return
	}
	if rel == nil {
		fail(w, http.StatusNotFound, "no_app")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, rel)
}

// appFile serves one of the release's files. Ranges let a device go on with a download it lost.
func (a *API) appFile(w http.ResponseWriter, r *http.Request, _ auth) {
	rel, err := a.releases.current()
	if !ok(w, err) {
		return
	}
	name := r.PathValue("file")
	if rel == nil || !rel.has(name) || !a.sendFile(w, r, name) {
		fail(w, http.StatusNotFound, "no_file")
	}
}

// sendFile serves the release's file name and reports whether it answered: not when the file is
// not there.
func (a *API) sendFile(w http.ResponseWriter, r *http.Request, name string) bool {
	f, err := os.OpenInRoot(a.releases.dir, name)
	if errors.Is(err, fs.ErrNotExist) {
		return false
	}
	if !ok(w, err) {
		return true
	}
	defer f.Close()
	st, err := f.Stat()
	if !ok(w, err) {
		return true
	}
	kind := "application/vnd.android.package-archive"
	if strings.HasSuffix(name, ".exe") {
		kind = "application/vnd.microsoft.portable-executable"
	}
	w.Header().Set("Content-Type", kind)
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	// The files carry the owner's keys: a CDN in front (Cloudflare caches .apk by default) must
	// not keep one and hand it to anyone without a session
	w.Header().Set("Cache-Control", "private, no-store")
	// Tens of MB on a slow line take longer than the server's WriteTimeout
	http.NewResponseController(w).SetWriteDeadline(time.Now().Add(30 * time.Minute))
	http.ServeContent(w, r, name, st.ModTime(), f)
	return true
}
