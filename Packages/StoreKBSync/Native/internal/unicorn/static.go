package unicorn

import (
	"context"
	"errors"
)

type library struct {
	handle uintptr
	close  func() error
}

var apiAddresses [16]uintptr

func SetAPI(addresses [16]uintptr) { apiAddresses = addresses }
func openLibrary(ctx context.Context) (library, error) {
	if err := ctx.Err(); err != nil {
		return library{}, err
	}
	for _, address := range apiAddresses {
		if address == 0 {
			return library{}, errors.New("missing static Unicorn API")
		}
	}
	return library{handle: 1, close: func() error { return nil }}, nil
}
func configureEngine(*Engine) error { return nil }
