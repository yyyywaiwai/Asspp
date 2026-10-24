package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"
	"unsafe"

	"asspp.local/storekbsync/internal/assets"
	"asspp.local/storekbsync/internal/machine"
	"asspp.local/storekbsync/internal/unicorn"
)

var generation sync.Mutex

var images = []struct {
	name   string
	size   int
	digest string
}{
	{"CommerceKit", 3271840, "b84ff12c21987856c0a17b78f1ad82b73195a6dec5f3b208a17d245555a2c8a2"},
	{"CommerceCore", 207744, "c5401e57402230f3c876409d295319ddf1e61287bc882683c5d61277be7bc1f2"},
	{"CoreFP", 29014912, "f19141336be4198d0f8991bb00017c915efc7aeaece36c345f7faa1237ea6074"},
	{"CoreFP.icxs", 5288352, "473e78af86979f5bd4f6269561caf770b3d16c098d918846eeac8cdd2fe6566a"},
	{"storeagent", 2580176, "70ce036f9dbcbc04db9511ebd08de0dd3cbc35ccc9d44b089c90170cb5453c59"},
}

func loadImages(directory string) (assets.Bundle, error) {
	files := make([][]byte, len(images))
	for i, image := range images {
		file, err := os.Open(filepath.Join(directory, image.name))
		if err != nil {
			return assets.Bundle{}, errors.New("kbsync image is missing")
		}
		info, err := file.Stat()
		if err != nil || info.Size() != int64(image.size) {
			file.Close()
			return assets.Bundle{}, fmt.Errorf("invalid kbsync image size: %s", image.name)
		}
		data := make([]byte, image.size)
		n, err := io.ReadFull(file, data)
		file.Close()
		if err != nil || n != len(data) {
			return assets.Bundle{}, errors.New("kbsync image read failed")
		}
		digest := sha256.Sum256(data)
		if hex.EncodeToString(digest[:]) != image.digest {
			return assets.Bundle{}, fmt.Errorf("invalid kbsync image digest: %s", image.name)
		}
		files[i] = data
	}
	return assets.Bundle{CommerceKit: files[0], CommerceCore: files[1], CoreFP: files[2], CoreFPICXS: files[3], StoreAgent: files[4]}, nil
}

//export AssppGenerateKBSync
func AssppGenerateKBSync(directory *C.char, guid *C.char, dsid C.uint64_t, functions *C.uintptr_t, failure **C.char) (result *C.char) {
	defer func() {
		if recover() != nil {
			if failure != nil {
				*failure = C.CString("kbsync runtime failed")
			}
			result = nil
		}
	}()
	if failure == nil {
		return nil
	}
	*failure = nil
	if directory == nil || guid == nil || functions == nil || dsid == 0 {
		*failure = C.CString("invalid kbsync input")
		return nil
	}
	hardware, err := hex.DecodeString(C.GoString(guid))
	if err != nil || len(hardware) != 6 {
		*failure = C.CString("kbsync requires a six-byte device GUID")
		return nil
	}
	generation.Lock()
	defer generation.Unlock()
	var addresses [16]uintptr
	for i, value := range unsafe.Slice(functions, 16) {
		addresses[i] = uintptr(value)
	}
	unicorn.SetAPI(addresses)
	bundle, err := loadImages(C.GoString(directory))
	if err != nil {
		*failure = C.CString(err.Error())
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	blob, err := machine.GenerateKBSync(ctx, bundle, hardware, uint64(dsid))
	if err != nil {
		*failure = C.CString(err.Error())
		return nil
	}
	if len(blob) == 0 || len(blob) > 64*1024 {
		*failure = C.CString("invalid kbsync output length")
		return nil
	}
	return C.CString(base64.StdEncoding.EncodeToString(blob))
}

func main() {}
