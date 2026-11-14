package resona

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// Pause after a copied chunk so the parent can kill the process mid-write.
type interruptedCopyContext struct {
	context.Context
	marker string
	reads  int
}

func (c *interruptedCopyContext) Err() error {
	c.reads++
	if c.reads == 4 {
		if err := os.WriteFile(c.marker, nil, 0600); err != nil {
			panic(err)
		}
		<-time.After(time.Hour)
	}
	return c.Context.Err()
}

func TestManagedCopyCrashRecovery(t *testing.T) {
	if encoded := os.Getenv("RESONA_COPY_CRASH_CONFIG"); encoded != "" {
		var config Config
		if err := json.Unmarshal([]byte(encoded), &config); err != nil {
			t.Fatal(err)
		}
		s, err := NewServer(context.Background(), config)
		if err != nil {
			t.Fatal(err)
		}
		defer s.Close()
		root, err := os.OpenRoot("/")
		if err != nil {
			t.Fatal(err)
		}
		defer root.Close()
		from, _ := managedPath(filepath.Join(config.InboxDir, "source.bin"))
		to, _ := managedPath(filepath.Join(config.LibraryDir, "destination.bin"))
		ctx := &interruptedCopyContext{Context: context.Background(), marker: filepath.Join(config.DataDir, "copy-started")}
		// Distinct root spellings exercise cross-volume moves without a second mounted disk.
		err = s.operateFile(ctx, fileOperation{Action: os.Getenv("RESONA_COPY_CRASH_ACTION")}, root, "//", from, root, "/", to)
		t.Fatalf("copy unexpectedly finished: %v", err)
	}
	for _, action := range []string{"copy", "move", "rename"} {
		t.Run(action, func(t *testing.T) {
			config := testConfig(t)
			from := filepath.Join(config.InboxDir, "source.bin")
			to := filepath.Join(config.LibraryDir, "destination.bin")
			file, err := os.Create(from)
			if err != nil {
				t.Fatal(err)
			}
			if err := file.Truncate(1 << 20); err != nil {
				t.Fatal(err)
			}
			file.Close()
			encoded, _ := json.Marshal(config)
			child := exec.Command(os.Args[0], "-test.run=^TestManagedCopyCrashRecovery$")
			child.Env = append(os.Environ(), "RESONA_COPY_CRASH_CONFIG="+string(encoded), "RESONA_COPY_CRASH_ACTION="+action)
			if err := child.Start(); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { child.Process.Kill(); child.Wait() })
			marker := filepath.Join(config.DataDir, "copy-started")
			for deadline := time.Now().Add(10 * time.Second); ; {
				if _, err := os.Stat(marker); err == nil {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("child did not reach the interrupted copy")
				}
				time.Sleep(10 * time.Millisecond)
			}
			if err := child.Process.Kill(); err != nil {
				t.Fatal(err)
			}
			child.Wait()
			data, err := os.ReadFile(filepath.Join(config.DataDir, "file-operation.json"))
			if err != nil {
				t.Fatal(err)
			}
			var pending pendingFileOperation
			if err := json.Unmarshal(data, &pending); err != nil {
				t.Fatal(err)
			}
			stage := "/" + pending.CopyStage
			if info, err := os.Stat(stage); err != nil || info.Size() == 0 || info.Size() >= 1<<20 {
				t.Fatal("expected an incomplete hidden copy", info, err)
			}
			if _, err := os.Stat(to); !os.IsNotExist(err) {
				t.Fatal("partial copy was published", err)
			}
			reopened, err := NewServer(context.Background(), config)
			if err != nil {
				t.Fatal(err)
			}
			defer reopened.Close()
			for _, path := range []string{to, stage, reopened.fileJournal()} {
				if _, err := os.Stat(path); !os.IsNotExist(err) {
					t.Fatal("restart retained incomplete copy state", path, err)
				}
			}
			if info, err := os.Stat(from); err != nil || info.Size() != 1<<20 {
				t.Fatal("restart lost source", info, err)
			}
		})
	}
}
