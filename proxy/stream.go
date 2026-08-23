package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

const (
	defaultStreamWebsocketURL = "wss://chatgpt.com/backend-api/dictation/stream"
	streamMaxUtterance        = 30 * time.Second
	streamStartTimeout        = 10 * time.Second
	streamFinishTimeout       = 8 * time.Second
	streamChunkBytes          = 1024 * 2 // official client: 1024 mono PCM16 samples
)

// streamWebsocketURL is a variable so the protocol can be exercised against a
// local test server without touching the real ChatGPT endpoint. Codex Desktop
// resolves its internal connect-info request locally and returns this URL plus
// the three subprotocols below; it does not POST that path to ChatGPT.
var streamWebsocketURL = defaultStreamWebsocketURL

type streamConnectInfo struct {
	WebsocketURL string   `json:"websocketUrl"`
	Protocols    []string `json:"protocols"`
}

type streamEvent struct {
	Type        string `json:"type"`
	Text        string `json:"text"`
	UtteranceID string `json:"utterance_id"`
	Fatal       bool   `json:"fatal"`
	Error       *struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
	Session *struct {
		Status string `json:"status"`
	} `json:"session"`
}

// streamMode controls the compatibility transition:
//   - buffered (default): use the lowest-latency complete-file request. This
//     is the right default for Voxtype because it only hands over audio after
//     recording stops.
//   - auto: use official-style streaming when the input fits it, then fall back
//     to buffered transcription on a protocol failure.
//   - streaming: require the official-style path and return its error.
//   - buffered/off: retain the existing multipart transcription path.
func streamMode() string {
	switch strings.ToLower(strings.TrimSpace(env("CODEX_DICTATE_STREAMING", "buffered"))) {
	case "streaming", "on", "true":
		return "streaming"
	case "buffered", "off", "false", "0":
		return "buffered"
	default:
		return "auto"
	}
}

// extractPCM16MonoWAV returns the data chunk required by the streaming API.
// Voxtype's configured remote capture is 16-bit mono WAV; other formats are
// deliberately left on the buffered path rather than guessed or transcoded.
func extractPCM16MonoWAV(b []byte) ([]byte, int, error) {
	if len(b) < 12 || string(b[:4]) != "RIFF" || string(b[8:12]) != "WAVE" {
		return nil, 0, fmt.Errorf("audio is not RIFF/WAVE")
	}

	var sampleRate int
	var data []byte
	for off := 12; off+8 <= len(b); {
		chunkID := string(b[off : off+4])
		chunkSize := int(uint32(b[off+4]) | uint32(b[off+5])<<8 | uint32(b[off+6])<<16 | uint32(b[off+7])<<24)
		bodyStart := off + 8
		if chunkSize < 0 || bodyStart > len(b) || chunkSize > len(b)-bodyStart {
			return nil, 0, fmt.Errorf("invalid WAV chunk size")
		}

		switch chunkID {
		case "fmt ":
			if chunkSize < 16 {
				return nil, 0, fmt.Errorf("WAV fmt chunk is too short")
			}
			format := uint16(b[bodyStart]) | uint16(b[bodyStart+1])<<8
			channels := uint16(b[bodyStart+2]) | uint16(b[bodyStart+3])<<8
			sampleRate = int(uint32(b[bodyStart+4]) | uint32(b[bodyStart+5])<<8 | uint32(b[bodyStart+6])<<16 | uint32(b[bodyStart+7])<<24)
			bitsPerSample := uint16(b[bodyStart+14]) | uint16(b[bodyStart+15])<<8
			if format != 1 || channels != 1 || bitsPerSample != 16 || sampleRate <= 0 {
				return nil, 0, fmt.Errorf("WAV must be mono PCM16 (format=%d channels=%d bits=%d rate=%d)", format, channels, bitsPerSample, sampleRate)
			}
		case "data":
			data = b[bodyStart : bodyStart+chunkSize]
		}

		off = bodyStart + chunkSize + chunkSize%2
	}
	if sampleRate == 0 || len(data) == 0 {
		return nil, 0, fmt.Errorf("WAV has no usable fmt/data chunks")
	}
	if len(data)%2 != 0 {
		data = data[:len(data)-1]
	}
	return data, sampleRate, nil
}

func streamingAudio(b []byte, fileCT, fileName, language string) ([]byte, int, bool, error) {
	if streamMode() == "buffered" {
		return nil, 0, false, nil
	}
	if language != "" && !strings.EqualFold(language, "auto") {
		return nil, 0, false, fmt.Errorf("streaming path does not accept forced language %q", language)
	}
	if !strings.Contains(strings.ToLower(fileCT), "wav") && !strings.HasSuffix(strings.ToLower(fileName), ".wav") {
		return nil, 0, false, fmt.Errorf("streaming path requires WAV input (content-type=%q filename=%q)", fileCT, fileName)
	}
	pcm, sampleRate, err := extractPCM16MonoWAV(b)
	if err != nil {
		return nil, 0, false, err
	}
	duration := time.Duration(len(pcm)) * time.Second / time.Duration(sampleRate*2)
	if duration > streamMaxUtterance {
		return nil, 0, false, fmt.Errorf("utterance duration %s exceeds official streaming limit %s", duration.Round(time.Millisecond), streamMaxUtterance)
	}
	return pcm, sampleRate, true, nil
}

func transcribeStreaming(ctx context.Context, pcm []byte, sampleRate int, token, accountID string) (string, error) {
	info := streamConnectInfo{
		WebsocketURL: streamWebsocketURL,
		Protocols: []string{
			"chatgpt-dictation",
			"openai-bearer." + token,
			"codex-desktop",
		},
	}

	header := http.Header{}
	setChatGPTHeaders(header, token, accountID)
	header.Set("Origin", "https://chatgpt.com")

	dialer := websocket.Dialer{
		HandshakeTimeout: streamStartTimeout,
		Subprotocols:     info.Protocols,
	}
	conn, resp, err := dialer.DialContext(ctx, info.WebsocketURL, header)
	if err != nil {
		if resp != nil {
			return "", fmt.Errorf("stream websocket: %w (status %s)", err, resp.Status)
		}
		return "", fmt.Errorf("stream websocket: %w", err)
	}
	defer conn.Close()

	if err := conn.SetWriteDeadline(time.Now().Add(streamStartTimeout)); err != nil {
		return "", err
	}
	if err := conn.WriteJSON(map[string]any{
		"type": "session.start",
		"config": map[string]any{
			"input_audio_format":        "pcm16",
			"sample_rate_hz":            sampleRate,
			"num_channels":              1,
			"max_buffer_size_bytes":     4 * 1024 * 1024,
			"max_utterance_duration_ms": 30_000,
			"session_ttl_ms":            300_000,
			"provider_mode":             "streaming_sse",
			"transcript_delivery_mode":  "final_only",
			"vad": map[string]any{
				"type":                "server_vad",
				"threshold":           0.5,
				"prefix_padding_ms":   300,
				"silence_duration_ms": 500,
			},
		},
	}); err != nil {
		return "", fmt.Errorf("send session.start: %w", err)
	}

	if err := conn.SetReadDeadline(time.Now().Add(streamStartTimeout)); err != nil {
		return "", err
	}
	var event streamEvent
	if err := conn.ReadJSON(&event); err != nil {
		return "", fmt.Errorf("read session.started: %w", err)
	}
	if event.Type != "session.started" {
		return "", streamEventError(event, "expected session.started")
	}

	for off := 0; off < len(pcm); off += streamChunkBytes {
		end := off + streamChunkBytes
		if end > len(pcm) {
			end = len(pcm)
		}
		if err := conn.SetWriteDeadline(time.Now().Add(streamFinishTimeout)); err != nil {
			return "", err
		}
		if err := conn.WriteJSON(map[string]any{
			"type":  "audio.append",
			"audio": base64.StdEncoding.EncodeToString(pcm[off:end]),
		}); err != nil {
			return "", fmt.Errorf("send audio.append: %w", err)
		}
	}
	if err := conn.SetWriteDeadline(time.Now().Add(streamFinishTimeout)); err != nil {
		return "", err
	}
	if err := conn.WriteJSON(map[string]string{"type": "session.close"}); err != nil {
		return "", fmt.Errorf("send session.close: %w", err)
	}

	if err := conn.SetReadDeadline(time.Now().Add(streamFinishTimeout)); err != nil {
		return "", err
	}
	orderedIDs := make([]string, 0, 1)
	finalText := make(map[string]string)
	for {
		var event streamEvent
		if err := conn.ReadJSON(&event); err != nil {
			if websocket.IsCloseError(err, websocket.CloseNormalClosure) {
				break
			}
			return "", fmt.Errorf("read stream event: %w", err)
		}
		switch event.Type {
		case "transcript.final":
			if event.UtteranceID != "" {
				if _, ok := finalText[event.UtteranceID]; !ok {
					orderedIDs = append(orderedIDs, event.UtteranceID)
				}
				finalText[event.UtteranceID] = event.Text
			}
		case "transcript.failed":
			return "", streamEventError(event, "stream transcript failed")
		case "session.error":
			if event.Fatal || event.Error != nil {
				return "", streamEventError(event, "stream session error")
			}
		case "session.updated":
			if event.Session != nil && event.Session.Status == "closed" {
				return joinFinalText(orderedIDs, finalText), nil
			}
		}
	}
	return joinFinalText(orderedIDs, finalText), nil
}

func streamEventError(event streamEvent, prefix string) error {
	if event.Error != nil && event.Error.Message != "" {
		return fmt.Errorf("%s: %s", prefix, event.Error.Message)
	}
	return fmt.Errorf("%s (%s)", prefix, event.Type)
}

func joinFinalText(ids []string, textByID map[string]string) string {
	parts := make([]string, 0, len(ids))
	for _, id := range ids {
		if text := strings.TrimSpace(textByID[id]); text != "" {
			parts = append(parts, text)
		}
	}
	return strings.TrimSpace(strings.Join(parts, " "))
}

func setChatGPTHeaders(h http.Header, token, accountID string) {
	h.Set("Authorization", "Bearer "+token)
	h.Set("User-Agent", env("CODEX_DICTATE_BROWSER_UA", browserUA))
	h.Set("Accept-Language", "en-US,en;q=0.9")
	h.Set("Origin", "https://chatgpt.com")
	h.Set("Referer", "https://chatgpt.com/")
	h.Set("sec-ch-ua", `"Google Chrome";v="149", "Chromium";v="149", "Not_A Brand";v="24"`)
	h.Set("sec-ch-ua-mobile", "?0")
	h.Set("sec-ch-ua-platform", `"macOS"`)
	if accountID != "" {
		h.Set("chatgpt-account-id", accountID)
	}
}
