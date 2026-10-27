package resona

import (
	"context"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	tg "github.com/amarnathcjd/gogram/telegram"
)

type fakeNativeTelegram struct {
	content []byte
	writes  atomic.Int32
	closed  atomic.Bool
	block   bool
}

func (f *fakeNativeTelegram) Download(ctx context.Context, _ localTelegramFile, out *os.File) error {
	f.writes.Add(1)
	if f.block {
		<-ctx.Done()
		return ctx.Err()
	}
	_, err := out.Write(f.content)
	return err
}
func (f *fakeNativeTelegram) Send(int64, string) error { return nil }
func (f *fakeNativeTelegram) Close()                   { f.closed.Store(true) }

func nativeMessage(size int64) *tg.NewMessage {
	return &tg.NewMessage{ID: 20, Message: &tg.MessageObj{
		ID: 20, FromID: &tg.PeerUser{UserID: 42}, PeerID: &tg.PeerUser{UserID: 42}, Message: "专辑：Album",
		Media: &tg.MessageMediaDocument{Document: &tg.DocumentObj{
			ID: 123, AccessHash: 321, FileReference: []byte("private reference"), DcID: 2, Size: size, MimeType: "audio/mpeg",
			Attributes: []tg.DocumentAttribute{&tg.DocumentAttributeFilename{FileName: "song.mp3"},
				&tg.DocumentAttributeAudio{Title: "Song", Performer: "Artist"}},
		}},
	}}
}

func nativeFixture(t *testing.T) (*Server, *localBotAPI, *fakeNativeTelegram) {
	t.Helper()
	s := testServer(t)
	if err := s.store.update(func(st *libraryState) error {
		st.Plugins.Music = MusicSaverSettings{Token: testBotToken, APIURL: "local", Whitelist: "42"}
		st.Plugins.Telegram = TelegramSettings{APIID: 123, APIHash: strings.Repeat("a", 32), Port: 8081}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	fake := &fakeNativeTelegram{content: []byte("audio content")}
	s.plugins.connectLocal = func(context.Context, TelegramSettings, string, string, func(*tg.NewMessage) error) (localTelegramTransport, error) {
		return fake, nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	api := &localBotAPI{plugins: s.plugins, config: s.store.pluginSettings().Telegram, ctx: ctx, wake: make(chan struct{}, 1)}
	return s, api, fake
}

func TestNativeTelegramQueueDownloadsAndRecovery(t *testing.T) {
	s, api, fake := nativeFixture(t)
	server := httptest.NewServer(api)
	defer server.Close()
	ctx := context.Background()
	var updates []localTelegramUpdate
	// Invalid tokens and unsupported methods never initialize the MTProto connection.
	for _, path := range []string{"/botwrong/getUpdates", "/bot" + testBotToken + "/deleteMessage"} {
		w := httptest.NewRecorder()
		api.ServeHTTP(w, httptest.NewRequest("POST", path, strings.NewReader(`{}`)))
		if w.Code < 400 || api.client != nil {
			t.Fatal("invalid request initialized a Telegram connection")
		}
	}
	if err := s.plugins.telegram(ctx, server.URL, testBotToken, "getUpdates", map[string]int{"timeout": 0}, &updates); err != nil || len(updates) != 0 {
		t.Fatalf("empty polling: %+v %v", updates, err)
	}
	message := nativeMessage(int64(len(fake.content)))
	if err := api.accept(message); err != nil {
		t.Fatal(err)
	}
	// Duplicate deliveries and non-whitelisted senders must not grow the queue.
	_ = api.accept(message)
	rejected := nativeMessage(int64(len(fake.content)))
	rejected.Message.PeerID = &tg.PeerUser{UserID: 7}
	_ = api.accept(rejected)
	if err := s.plugins.telegram(ctx, server.URL, testBotToken, "getUpdates", map[string]int{"limit": 10}, &updates); err != nil || len(updates) != 1 {
		t.Fatalf("queue delivery: %+v %v", updates, err)
	}
	if updates[0].Files != nil || updates[0].Message.Audio.Title != "Song" {
		t.Fatal("private file metadata leaked or audio tags lost")
	}
	// Pending messages survive a service restart before offset acknowledgement.
	reloaded := &localBotAPI{plugins: s.plugins, config: api.config, ctx: api.ctx, wake: make(chan struct{}, 1)}
	if err := reloaded.connect(testBotToken); err != nil || len(reloaded.state.Updates) != 1 {
		t.Fatalf("pending queue lost: %v", err)
	}
	var file telegramFile
	for i := 0; i < 2; i++ {
		err := s.plugins.telegram(ctx, server.URL, testBotToken, "getFile", map[string]string{"file_id": "123"}, &file)
		if err != nil {
			t.Fatal(err)
		}
	}
	if fake.writes.Load() != 1 {
		t.Fatal("completed cached download not reused")
	}
	data, err := os.ReadFile(file.Path)
	if err != nil || string(data) != string(fake.content) || !within(filepath.Join(s.plugins.localDir(), "files"), file.Path) {
		t.Fatal("invalid cached file")
	}
	if info, _ := os.Stat(api.path); info.Mode().Perm() != 0600 {
		t.Fatal("private file references have unsafe permissions")
	}
	if err := s.plugins.telegram(ctx, server.URL, testBotToken, "getUpdates",
		map[string]int64{"offset": updates[0].ID + 1, "timeout": 0}, &updates); err != nil || len(updates) != 0 {
		t.Fatal("acknowledged messages not removed")
	}
	if err := s.plugins.telegram(ctx, server.URL, testBotToken, "getFile", map[string]string{"file_id": "../../outside"}, &file); err == nil {
		t.Fatal("unknown file accepted")
	}
}

func TestNativeTelegramCancellationAndIncompleteDownload(t *testing.T) {
	_, api, fake := nativeFixture(t)
	if err := api.connect(testBotToken); err != nil {
		t.Fatal(err)
	}
	_ = api.accept(nativeMessage(int64(len(fake.content) + 1)))
	if _, err := api.download(context.Background(), "123"); err == nil {
		t.Fatal("incomplete native download published")
	}
	fake.block = true
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := api.download(ctx, "123"); !errors.Is(err, context.Canceled) {
		t.Fatalf("download cancellation: %v", err)
	}
	entries, _ := os.ReadDir(filepath.Join(api.plugins.localDir(), "files"))
	if len(entries) != 0 {
		t.Fatal("failed native download left a partial cache file")
	}
	if _, err := api.poll(ctx, 1, 10, 25); !errors.Is(err, context.Canceled) {
		t.Fatal("long polling did not cancel")
	}
}

func TestNativeTelegramFileBoundariesAndLyrics(t *testing.T) {
	if localMessage(nativeMessage((2<<30)+1)) != nil || localMessage(nativeMessage(0)) != nil {
		t.Fatal("invalid audio size accepted")
	}
	message := nativeMessage(maxLyricsSize + 1)
	doc := message.Message.Media.(*tg.MessageMediaDocument).Document.(*tg.DocumentObj)
	doc.Attributes = []tg.DocumentAttribute{&tg.DocumentAttributeFilename{FileName: "Song-Artist.lrc"}}
	if localMessage(message) != nil {
		t.Fatal("oversized lyrics accepted")
	}
	doc.Size = 30
	if result := localMessage(message); result == nil || result.Message.Document.Name != "Song-Artist.lrc" {
		t.Fatal("lyric document not converted")
	}
	doc.Attributes = []tg.DocumentAttribute{&tg.DocumentAttributeAudio{Voice: true}}
	if result := localMessage(message); result == nil || result.Message.Voice == nil {
		t.Fatal("voice note not converted")
	}
	doc.Thumbs = []tg.PhotoSize{&tg.PhotoSizeObj{Type: "m", Size: 200}}
	result := localMessage(message)
	if result.Message.Voice.Thumbnail == nil || len(result.Files) != 2 {
		t.Fatal("cover reference missing")
	}
	out, err := os.CreateTemp(t.TempDir(), "bounded")
	if err != nil {
		t.Fatal(err)
	}
	defer out.Close()
	writer := boundedTelegramWriter{file: out, limit: 8}
	for _, offset := range []int64{-1, 7, 9, 1 << 62} {
		if _, err := writer.WriteAt([]byte("12"), offset); err == nil {
			t.Fatal("out-of-bounds file chunk accepted")
		}
	}
	if _, err := writer.WriteAt([]byte("12"), 6); err != nil {
		t.Fatal(err)
	}
}

func TestNativeTelegramLongPollingWake(t *testing.T) {
	_, api, fake := nativeFixture(t)
	if err := api.connect(testBotToken); err != nil {
		t.Fatal(err)
	}
	done := make(chan []localTelegramUpdate, 1)
	go func() {
		items, _ := api.poll(api.ctx, 0, 10, 25)
		done <- items
	}()
	if err := api.accept(nativeMessage(int64(len(fake.content)))); err != nil {
		t.Fatal(err)
	}
	select {
	case items := <-done:
		if len(items) != 1 {
			t.Fatal("poll returned no message")
		}
	case <-time.After(time.Second):
		t.Fatal("incoming music did not wake long polling")
	}
}
