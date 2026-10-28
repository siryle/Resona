package resona

import (
	"bytes"
	"errors"
	"image"
	"image/jpeg"
	_ "image/png"
	"os"
	"path/filepath"
)

func cacheArtwork(path string, data []byte) error {
	config, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return err
	}
	if config.Width > 2000 || config.Height > 2000 || config.Width < 1 || config.Height < 1 {
		return errors.New("artwork dimensions exceed limit")
	}
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0750); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".remote-cover-*.jpg")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	err = jpeg.Encode(f, img, &jpeg.Options{Quality: 88})
	closeErr := f.Close()
	if err != nil || closeErr != nil {
		return errors.Join(err, closeErr)
	}
	return os.Rename(f.Name(), path)
}
