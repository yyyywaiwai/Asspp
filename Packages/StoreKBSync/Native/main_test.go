package main

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

func TestImageValidation(t *testing.T) {
	original := images
	defer func() { images = original }()
	images = append(images[:0:0], original...)
	directory := t.TempDir()
	data := []byte("synthetic image")
	digest := sha256.Sum256(data)
	for i := range images {
		images[i].size = len(data)
		images[i].digest = hex.EncodeToString(digest[:])
		if err := os.WriteFile(filepath.Join(directory, images[i].name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := loadImages(directory); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, images[0].name)
	for _, bad := range [][]byte{[]byte("short"), []byte("modified image!")} {
		if err := os.WriteFile(path, bad, 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := loadImages(directory); err == nil {
			t.Fatal("accepted modified image")
		}
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if _, err := loadImages(directory); err == nil {
		t.Fatal("accepted missing image")
	}
}
