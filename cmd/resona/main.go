package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	root "resona"
	"resona/internal/resona"
)

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		v := root.Version()
		fmt.Println(v.Version + "+" + strconv.Itoa(v.Build))
		return
	}
	if err := run(); err != nil {
		slog.Error("Resona stopped", "error", err)
		os.Exit(1)
	}
}

func run() error {
	c, err := resona.ConfigFromEnv()
	if err != nil {
		return err
	}
	for _, bin := range []string{"ffprobe", "ffmpeg"} {
		if _, err := exec.LookPath(bin); err != nil {
			return err
		}
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	app, err := resona.NewServer(ctx, c)
	if err != nil {
		return err
	}
	defer app.Close()
	server := &http.Server{
		Addr: c.Addr, Handler: app.Handler(), ErrorLog: slog.NewLogLogger(app.Logger().Handler(), slog.LevelError), ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 30 * time.Second,
		IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10,
		// Audio responses intentionally have no write deadline, allowing long playback.
	}
	app.Schedule()
	done := make(chan error, 1)
	go func() { done <- server.ListenAndServe() }()
	app.Logger().Info("Resona ready", "address", c.Addr, "version", root.Version())
	select {
	case err = <-done:
		cancel()
	case <-ctx.Done():
		shutdownCtx, stop := context.WithTimeout(context.Background(), 15*time.Second)
		err = server.Shutdown(shutdownCtx)
		stop()
	}
	cancel()
	app.Wait()
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		app.Logger().Error("Resona stopped", "error", err)
	} else {
		app.Logger().Info("Resona 已停止")
	}
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}
