// voxtype-codex-proxy: local OpenAI-compatible /v1/audio/transcriptions shim that
// forwards audio to the ChatGPT (Codex) transcribe backend using the ChatGPT OAuth
// token from ~/.codex/auth.json.
//
// Why a proxy: Cloudflare in front of chatgpt.com rejects non-browser User-Agents
// (Voxtype's reqwest client => 403). Voxtype can't set a custom UA, so we terminate
// its request locally and re-issue with a real browser UA + the bearer token. The
// token is read fresh from auth.json per request, so Codex token refreshes are
// picked up automatically.
//
// Static build:  CGO_ENABLED=0 go build -ldflags "-s -w" -o voxtype-codex-proxy .
// Listens on 127.0.0.1:8377 (override with VOXTYPE_PROXY_HOST/PORT).
package main

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"math"
	"mime"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	upstream  = "https://chatgpt.com/backend-api/transcribe"
	browserUA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " +
		"(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func authPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".codex", "auth.json")
}

// loadAuth reads the access token + account id fresh on every request.
func loadAuth() (token, accountID string, err error) {
	b, err := os.ReadFile(authPath())
	if err != nil {
		return "", "", err
	}
	var a struct {
		Tokens struct {
			AccessToken string `json:"access_token"`
			AccountID   string `json:"account_id"`
		} `json:"tokens"`
	}
	if err := json.Unmarshal(b, &a); err != nil {
		return "", "", err
	}
	return a.Tokens.AccessToken, a.Tokens.AccountID, nil
}

var httpClient = &http.Client{Timeout: 120 * time.Second}

// normalizePCM16WAV lifts a quiet/inconsistent mono PCM16 WAV to a target speech
// loudness (RMS ~ -18 dBFS) so Whisper gets a consistent level. It only boosts
// (never attenuates), caps the gain so near-silence/noise isn't blown up, and
// guards the peak against clipping. On any parse problem it returns the input
// untouched — never break the pipeline for the sake of a tweak.
func normalizePCM16WAV(b []byte) []byte {
	if os.Getenv("VOXTYPE_PROXY_NO_NORMALIZE") != "" {
		return b
	}
	if len(b) < 44 || string(b[0:4]) != "RIFF" || string(b[8:12]) != "WAVE" {
		return b
	}
	// Find the "data" chunk (skip fmt/LIST/etc).
	off := 12
	dataStart, dataLen := -1, 0
	for off+8 <= len(b) {
		id := string(b[off : off+4])
		sz := int(b[off+4]) | int(b[off+5])<<8 | int(b[off+6])<<16 | int(b[off+7])<<24
		body := off + 8
		if id == "data" {
			dataStart = body
			dataLen = sz
			break
		}
		off = body + sz + (sz & 1) // chunks are word-aligned
	}
	if dataStart < 0 || dataLen <= 0 || dataStart+dataLen > len(b) {
		return b
	}
	n := dataLen / 2
	if n == 0 {
		return b
	}
	get := func(i int) int16 { return int16(uint16(b[dataStart+2*i]) | uint16(b[dataStart+2*i+1])<<8) }

	var sumSq float64
	peak := 0
	for i := 0; i < n; i++ {
		s := int(get(i))
		if s < 0 {
			s = -s
		}
		if s > peak {
			peak = s
		}
		v := float64(int(get(i)))
		sumSq += v * v
	}
	if peak == 0 {
		return b
	}
	rms := math.Sqrt(sumSq / float64(n))
	if rms < 1 {
		return b
	}
	const targetRMS = 4129.0 // ~ -18 dBFS for 16-bit
	const maxGain = 8.0       // ~ +18 dB ceiling so noise floor isn't amplified
	const peakCeil = 32440.0  // ~ -0.1 dBFS
	gain := targetRMS / rms
	if gain <= 1.0 {
		return b // already loud enough; leave it
	}
	if gain > maxGain {
		gain = maxGain
	}
	if float64(peak)*gain > peakCeil {
		gain = peakCeil / float64(peak)
	}
	if gain <= 1.0 {
		return b
	}
	for i := 0; i < n; i++ {
		v := float64(get(i)) * gain
		if v > 32767 {
			v = 32767
		} else if v < -32768 {
			v = -32768
		}
		s := int16(v)
		b[dataStart+2*i] = byte(uint16(s))
		b[dataStart+2*i+1] = byte(uint16(s) >> 8)
	}
	return b
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func handle(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		writeJSON(w, 200, map[string]string{"status": "ok", "upstream": upstream})
		return
	}
	if r.Method != http.MethodPost || !strings.Contains(r.URL.Path, "audio/transcriptions") {
		writeJSON(w, 404, map[string]string{"error": "unknown path"})
		return
	}

	// Parse the inbound multipart to pull the file part (+ optional language).
	_, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil {
		writeJSON(w, 400, map[string]string{"error": "bad content-type: " + err.Error()})
		return
	}
	mr := multipart.NewReader(r.Body, params["boundary"])

	var fileName, fileCT string
	var fileBytes []byte
	var language string
	for {
		p, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			writeJSON(w, 400, map[string]string{"error": "multipart: " + err.Error()})
			return
		}
		switch p.FormName() {
		case "file":
			fileName = p.FileName()
			if fileName == "" {
				fileName = "audio.wav"
			}
			fileCT = p.Header.Get("Content-Type")
			fileBytes, _ = io.ReadAll(p)
		case "language":
			b, _ := io.ReadAll(p)
			language = strings.TrimSpace(string(b))
		}
		_ = p.Close()
	}
	if len(fileBytes) == 0 {
		writeJSON(w, 400, map[string]string{"error": "no file part"})
		return
	}

	// Lift quiet/inconsistent capture (e.g. Bluetooth HFP mic) to a steady level.
	if strings.Contains(fileCT, "wav") || strings.HasSuffix(strings.ToLower(fileName), ".wav") {
		fileBytes = normalizePCM16WAV(fileBytes)
	}

	// Debug: dump the exact audio we forward upstream (set VOXTYPE_PROXY_DEBUG_DIR).
	if dir := os.Getenv("VOXTYPE_PROXY_DEBUG_DIR"); dir != "" {
		ext := filepath.Ext(fileName)
		if ext == "" {
			ext = ".bin"
		}
		dst := filepath.Join(dir, "voxtype-last"+ext)
		_ = os.WriteFile(dst, fileBytes, 0o600)
		log.Printf("[proxy] recv file=%s ct=%s bytes=%d lang=%q -> %s",
			fileName, fileCT, len(fileBytes), language, dst)
	}

	token, accountID, err := loadAuth()
	if err != nil {
		writeJSON(w, 502, map[string]string{"error": "auth.json: " + err.Error()})
		return
	}

	// Rebuild a fresh multipart body for the upstream request.
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	fw, _ := createFilePart(mw, fileName, fileCT)
	_, _ = fw.Write(fileBytes)
	if language != "" && !strings.EqualFold(language, "auto") {
		_ = mw.WriteField("language", language)
	}
	_ = mw.Close()

	req, _ := http.NewRequest(http.MethodPost, upstream, &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("User-Agent", browserUA)
	if accountID != "" {
		req.Header.Set("chatgpt-account-id", accountID)
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		writeJSON(w, 502, map[string]string{"error": "upstream: " + err.Error()})
		return
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)

	// Pass body straight through; Voxtype expects {"text": "..."}.
	if ct := resp.Header.Get("Content-Type"); ct != "" {
		w.Header().Set("Content-Type", ct)
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(out)
}

// createFilePart writes a file part while preserving the original Content-Type
// (multipart.CreateFormFile hardcodes application/octet-stream).
func createFilePart(mw *multipart.Writer, name, ct string) (io.Writer, error) {
	h := make(map[string][]string)
	h["Content-Disposition"] = []string{
		`form-data; name="file"; filename="` + name + `"`,
	}
	if ct == "" {
		ct = "application/octet-stream"
	}
	h["Content-Type"] = []string{ct}
	return mw.CreatePart(h)
}

func main() {
	addr := env("VOXTYPE_PROXY_HOST", "127.0.0.1") + ":" + env("VOXTYPE_PROXY_PORT", "8377")
	if t := os.Getenv("VOXTYPE_PROXY_TIMEOUT"); t != "" {
		if secs, err := strconv.Atoi(t); err == nil {
			httpClient.Timeout = time.Duration(secs) * time.Second
		}
	}
	http.HandleFunc("/", handle)
	log.Printf("[proxy] listening on http://%s -> %s", addr, upstream)
	log.Fatal(http.ListenAndServe(addr, nil))
}
