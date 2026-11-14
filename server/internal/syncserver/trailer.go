package syncserver

import (
	"html/template"
	"net/http"
	"regexp"
)

// The page a trailer plays in, for apps whose pages have no web address: the Samsung TV app runs
// from file://, and YouTube's player refuses to play ("player configuration error") in a page
// without one. Served from here, the player's page has this server's address. It is YouTube's own
// player (its terms allow no other), muted, without controls, playing [start, end) seconds, and it
// tells the page that frames it what it is doing (postMessage {trailer: state}). Muted, YouTube
// turns its captions on by itself: they go as it plays. Nothing is stored or asked of the account:
// anyone may load it.

var youtubeID = regexp.MustCompile(`^[\w-]{6,20}$`)

var trailerPage = template.Must(template.New("trailer").Parse(`<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
html,body{margin:0;height:100%;overflow:hidden;background:transparent}
#p{position:absolute;top:50%;left:50%;width:100vw;height:56.25vw;min-height:100vh;min-width:177.78vh;transform:translate(-50%,-50%);pointer-events:none}
</style></head>
<body><div id="p"></div>
<script>
function send(m){if(window.parent!==window)window.parent.postMessage({trailer:String(m)},'*')}
function onYouTubeIframeAPIReady(){
  new YT.Player('p',{
    videoId:{{.ID}},
    host:'https://www.youtube-nocookie.com',
    playerVars:{autoplay:1,mute:1,controls:0,disablekb:1,fs:0,iv_load_policy:3,playsinline:1,rel:0,start:{{.Start}},end:{{.End}},origin:location.origin},
    events:{
      onReady:function(e){e.target.mute();setTimeout(function(){var s=e.target.getPlayerState();if(s===-1||s===5)e.target.playVideo()},1500)},
      onStateChange:function(e){if(e.data===1){e.target.unloadModule('captions');e.target.unloadModule('cc')}send(e.data)},
      onError:function(e){send('error '+e.data)}
    }
  });
}
</script>
<script src="https://www.youtube.com/iframe_api" onerror="send('error')"></script>
</body></html>
`))

// The stretch played, as in the Flutter app's TrailerBackdrop: from just before the studio logos
// end, as the app shows it only once YouTube's overlay is gone (4 s in), and short.
const trailerStart, trailerLength = 6, 27

func trailer(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("v")
	if !youtubeID.MatchString(id) {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	// The same page for everyone: browsers and proxies may keep it, but not rewrite it
	w.Header().Set("Cache-Control", "public, max-age=86400, no-transform")
	trailerPage.Execute(w, struct {
		ID         string
		Start, End int
	}{id, trailerStart, trailerStart + trailerLength})
}
