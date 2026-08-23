package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
)

func TestExtractPCM16MonoWAV(t *testing.T) {
	wav := make([]byte, 44+4)
	copy(wav[0:4], "RIFF")
	copy(wav[8:12], "WAVE")
	copy(wav[12:16], "fmt ")
	putLE32(wav[16:20], 16)
	putLE16(wav[20:22], 1)
	putLE16(wav[22:24], 1)
	putLE32(wav[24:28], 16000)
	putLE32(wav[28:32], 32000)
	putLE16(wav[32:34], 2)
	putLE16(wav[34:36], 16)
	copy(wav[36:40], "data")
	putLE32(wav[40:44], 4)
	wav[44] = 1
	wav[45] = 2
	wav[46] = 3
	wav[47] = 4

	pcm, rate, err := extractPCM16MonoWAV(wav)
	if err != nil {
		t.Fatalf("extractPCM16MonoWAV returned error: %v", err)
	}
	if rate != 16000 {
		t.Fatalf("sample rate = %d, want 16000", rate)
	}
	if string(pcm) != string(wav[44:]) {
		t.Fatalf("PCM = %v, want %v", pcm, wav[44:])
	}
}

func TestTranscribeStreamingUsesCodexProtocol(t *testing.T) {
	pcm := make([]byte, streamChunkBytes+3)
	for i := range pcm {
		pcm[i] = byte(i)
	}

	var start map[string]any
	var received []byte
	var upgrader = websocket.Upgrader{
		CheckOrigin:  func(*http.Request) bool { return true },
		Subprotocols: []string{"chatgpt-dictation", "openai-bearer.token", "codex-desktop"},
	}
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/stream":
			protocols := r.Header.Get("Sec-WebSocket-Protocol")
			for _, want := range []string{"chatgpt-dictation", "openai-bearer.token", "codex-desktop"} {
				if !strings.Contains(protocols, want) {
					t.Errorf("websocket protocols = %q, missing %q", protocols, want)
				}
			}
			conn, err := upgrader.Upgrade(w, r, nil)
			if err != nil {
				t.Errorf("upgrade: %v", err)
				return
			}
			defer conn.Close()

			_, message, err := conn.ReadMessage()
			if err != nil {
				t.Errorf("read session.start: %v", err)
				return
			}
			if err := json.Unmarshal(message, &start); err != nil {
				t.Errorf("decode session.start: %v", err)
				return
			}
			_ = conn.WriteJSON(map[string]any{
				"type": "session.started",
				"session": map[string]any{
					"status": "active",
				},
			})

			for {
				_, message, err = conn.ReadMessage()
				if err != nil {
					t.Errorf("read audio/session.close: %v", err)
					return
				}
				var event struct {
					Type  string `json:"type"`
					Audio string `json:"audio"`
				}
				if err := json.Unmarshal(message, &event); err != nil {
					t.Errorf("decode client event: %v", err)
					return
				}
				switch event.Type {
				case "audio.append":
					chunk, err := base64.StdEncoding.DecodeString(event.Audio)
					if err != nil {
						t.Errorf("decode audio: %v", err)
						return
					}
					received = append(received, chunk...)
				case "session.close":
					_ = conn.WriteJSON(map[string]any{
						"type":         "transcript.final",
						"utterance_id": "u1",
						"text":         "hello world",
					})
					_ = conn.WriteJSON(map[string]any{
						"type": "session.updated",
						"session": map[string]any{
							"status": "closed",
						},
					})
					return
				}
			}
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	oldWebsocketURL := streamWebsocketURL
	oldClient := httpClient
	streamWebsocketURL = "ws" + strings.TrimPrefix(server.URL, "http") + "/stream"
	httpClient = server.Client()
	t.Cleanup(func() {
		streamWebsocketURL = oldWebsocketURL
		httpClient = oldClient
	})

	text, err := transcribeStreaming(context.Background(), pcm, 16000, "token", "account")
	if err != nil {
		t.Fatalf("transcribeStreaming returned error: %v", err)
	}
	if text != "hello world" {
		t.Fatalf("text = %q, want hello world", text)
	}
	if string(received) != string(pcm) {
		t.Fatalf("received PCM differs: got %d bytes, want %d", len(received), len(pcm))
	}

	config, ok := start["config"].(map[string]any)
	if !ok {
		t.Fatalf("session.start config missing: %#v", start)
	}
	if config["input_audio_format"] != "pcm16" || config["provider_mode"] != "streaming_sse" || config["transcript_delivery_mode"] != "final_only" {
		t.Fatalf("unexpected session.start config: %#v", config)
	}
}

func putLE16(b []byte, v uint16) {
	b[0] = byte(v)
	b[1] = byte(v >> 8)
}

func putLE32(b []byte, v uint32) {
	b[0] = byte(v)
	b[1] = byte(v >> 8)
	b[2] = byte(v >> 16)
	b[3] = byte(v >> 24)
}
