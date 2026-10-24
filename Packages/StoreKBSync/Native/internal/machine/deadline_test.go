package machine

import (
	"context"
	"testing"
	"time"
)

func TestGuestDeadline(t *testing.T) {
	duration, err := guestTimeout(context.Background())
	if err != nil || duration != sapGuestTimeout {
		t.Fatal("missing per-call bound")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	duration, err = guestTimeout(ctx)
	if err != nil || duration <= 0 || duration > time.Second {
		t.Fatal("ignored overall deadline")
	}
	cancel()
	if _, err := guestTimeout(ctx); err == nil {
		t.Fatal("ignored cancellation")
	}
}
