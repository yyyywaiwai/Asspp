package assets

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
)

type Bundle struct {
	CommerceKit, CommerceCore, CoreFP, CoreFPICXS, StoreAgent []byte
}

func VerifyStoreAgent(data []byte) error {
	digest := sha256.Sum256(data)
	if len(data) != 2580176 || hex.EncodeToString(digest[:]) != "70ce036f9dbcbc04db9511ebd08de0dd3cbc35ccc9d44b089c90170cb5453c59" {
		return errors.New("invalid pinned StoreAgent image")
	}
	return nil
}
