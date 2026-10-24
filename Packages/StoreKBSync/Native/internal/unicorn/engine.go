// Adapted from majd/ipatool 3411d57f451f (MIT); see LICENSE.ipatool.
package unicorn

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"sync"
	"time"
	"unsafe"

	"github.com/ebitengine/purego"
)

const queryTimeout = 4

const (
	archX86 = 4
	mode64  = 8
	protAll = 7

	RegRAX = 35
	RegRCX = 38
	RegRDI = 39
	RegRDX = 40
	RegRIP = 41
	RegRSI = 43
	RegRSP = 44
	RegR8  = 106
	RegR9  = 107
)

var (
	errTimeout      = errors.New("unicorn emulation timed out")
	errEngineClosed = errors.New("unicorn engine is closed")
)

type api struct {
	version  func(*uint32, *uint32) uint32
	open     func(int32, int32, *uintptr) int32
	close    func(uintptr) int32
	query    func(uintptr, int32, *uint64) int32
	ctl      func(uintptr, uint32, uint32) int32
	strerror func(int32) string
	memMap   func(uintptr, uint64, uint64, uint32) int32
	memUnmap func(uintptr, uint64, uint64) int32
	memRead  func(uintptr, uint64, unsafe.Pointer, uint64) int32
	memWrite func(uintptr, uint64, unsafe.Pointer, uint64) int32
	regRead  func(uintptr, int32, unsafe.Pointer) int32
	regWrite func(uintptr, int32, unsafe.Pointer) int32
	emuStart func(uintptr, uint64, uint64, uint64, uint64) int32
	emuStop  func(uintptr) int32
	hookAdd  func(uintptr, *uintptr, int32, uintptr, uintptr, uint64, uint64) int32
	hookDel  func(uintptr, uintptr) int32
}

type Engine struct {
	api       api
	handle    uintptr
	library   library
	hooks     hookState
	stateMu   sync.Mutex
	active    sync.WaitGroup
	closing   bool
	closeDone chan struct{}
	closeErr  error
}

func New(ctx context.Context) (*Engine, error) {
	return newEngine(ctx, openLibrary)
}

func newEngine(ctx context.Context, loadLibrary func(context.Context) (library, error)) (*Engine, error) {
	if ctx == nil {
		return nil, errors.New("unicorn context is nil")
	}

	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("create Unicorn engine: %w", err)
	}

	library, err := loadLibrary(ctx)
	if err != nil {
		return nil, fmt.Errorf("load Unicorn: %w", err)
	}

	if err := ctx.Err(); err != nil {
		if library.handle != 0 && library.close != nil {
			_ = library.close()
		}

		return nil, fmt.Errorf("create Unicorn engine: %w", err)
	}

	engine := &Engine{
		library:   library,
		closeDone: make(chan struct{}),
	}
	engine.register(library.handle)

	var major, minor uint32

	engine.api.version(&major, &minor)

	if major != 2 || minor != 1 {
		_ = library.close()

		return nil, fmt.Errorf("unsupported Unicorn API version %d.%d", major, minor)
	}

	if err := engine.err(engine.api.open(archX86, mode64, &engine.handle)); err != nil {
		_ = library.close()

		return nil, fmt.Errorf("create x86-64 emulator: %w", err)
	}

	if err := configureEngine(engine); err != nil {
		_ = engine.api.close(engine.handle)
		_ = library.close()

		return nil, err
	}

	runtime.SetFinalizer(engine, func(engine *Engine) {
		_ = engine.Close()
	})

	return engine, nil
}

func (e *Engine) register(_ uintptr) {
	purego.RegisterFunc(&e.api.version, apiAddresses[0])
	purego.RegisterFunc(&e.api.open, apiAddresses[1])
	purego.RegisterFunc(&e.api.close, apiAddresses[2])
	purego.RegisterFunc(&e.api.query, apiAddresses[3])
	purego.RegisterFunc(&e.api.ctl, apiAddresses[4])
	purego.RegisterFunc(&e.api.strerror, apiAddresses[5])
	purego.RegisterFunc(&e.api.memMap, apiAddresses[6])
	purego.RegisterFunc(&e.api.memUnmap, apiAddresses[7])
	purego.RegisterFunc(&e.api.memRead, apiAddresses[8])
	purego.RegisterFunc(&e.api.memWrite, apiAddresses[9])
	purego.RegisterFunc(&e.api.regRead, apiAddresses[10])
	purego.RegisterFunc(&e.api.regWrite, apiAddresses[11])
	purego.RegisterFunc(&e.api.emuStart, apiAddresses[12])
	purego.RegisterFunc(&e.api.emuStop, apiAddresses[13])
	purego.RegisterFunc(&e.api.hookAdd, apiAddresses[14])
	purego.RegisterFunc(&e.api.hookDel, apiAddresses[15])
}

func (e *Engine) MemMap(address, size uint64) error {
	handle, done, err := e.beginOperation()
	if err != nil {
		return err
	}

	defer done()

	return e.err(e.api.memMap(handle, address, size, protAll))
}

func (e *Engine) MemUnmap(address, size uint64) error {
	handle, done, err := e.beginOperation()
	if err != nil {
		return err
	}

	defer done()

	return e.err(e.api.memUnmap(handle, address, size))
}

func (e *Engine) MemRead(address, size uint64) ([]byte, error) {
	handle, done, err := e.beginOperation()
	if err != nil {
		return nil, err
	}
	defer done()

	data := make([]byte, size)
	if len(data) == 0 {
		return data, nil
	}

	err = e.err(e.api.memRead(handle, address, unsafe.Pointer(&data[0]), size))

	return data, err
}

func (e *Engine) MemReadInto(data []byte, address uint64) error {
	handle, done, err := e.beginOperation()
	if err != nil {
		return err
	}
	defer done()

	if len(data) == 0 {
		return nil
	}

	return e.err(e.api.memRead(handle, address, unsafe.Pointer(&data[0]), uint64(len(data))))
}

func (e *Engine) MemWrite(address uint64, data []byte) error {
	handle, done, err := e.beginOperation()
	if err != nil {
		return err
	}
	defer done()

	if len(data) == 0 {
		return nil
	}

	return e.err(e.api.memWrite(handle, address, unsafe.Pointer(&data[0]), uint64(len(data))))
}

func (e *Engine) RegRead(register int) (uint64, error) {
	handle, done, err := e.beginOperation()
	if err != nil {
		return 0, err
	}
	defer done()

	var value uint64
	err = e.err(e.api.regRead(handle, int32(register), unsafe.Pointer(&value)))

	return value, err
}

func (e *Engine) RegWrite(register int, value uint64) error {
	handle, done, err := e.beginOperation()
	if err != nil {
		return err
	}

	defer done()

	return e.err(e.api.regWrite(handle, int32(register), unsafe.Pointer(&value)))
}

func (e *Engine) Start(begin, end uint64) error {
	handle, done, err := e.beginOperation()
	if err != nil {
		return err
	}

	defer done()

	return e.err(e.api.emuStart(handle, begin, end, 0, 0))
}

func (e *Engine) StartBounded(begin, end uint64, timeout time.Duration, instructionLimit uint64) error {
	if timeout <= 0 {
		return errors.New("unicorn timeout must be positive")
	}

	microseconds := uint64(timeout / time.Microsecond)
	if microseconds == 0 {
		microseconds = 1
	}

	handle, done, err := e.beginOperation()
	if err != nil {
		return err
	}

	defer done()

	if err := e.err(e.api.emuStart(handle, begin, end, microseconds, instructionLimit)); err != nil {
		return err
	}

	var timedOut uint64
	if err := e.err(e.api.query(handle, queryTimeout, &timedOut)); err != nil {
		return fmt.Errorf("query Unicorn timeout: %w", err)
	}

	if timedOut != 0 {
		return fmt.Errorf("%w after %s", errTimeout, timeout)
	}

	return nil
}

func (e *Engine) Stop() error {
	handle, done, err := e.beginOperation()
	if err != nil {
		return err
	}

	defer done()

	return e.err(e.api.emuStop(handle))
}

func (e *Engine) Close() error {
	if e == nil {
		return nil
	}

	e.stateMu.Lock()
	if e.closing {
		done := e.closeDone
		e.stateMu.Unlock()
		<-done
		e.stateMu.Lock()
		err := e.closeErr
		e.stateMu.Unlock()

		return err
	}

	e.closing = true
	e.stateMu.Unlock()

	runtime.SetFinalizer(e, nil)
	e.active.Wait()
	e.clearCodeHooks()

	e.stateMu.Lock()
	handle := e.handle
	loadedLibrary := e.library
	e.handle = 0
	e.library = library{}
	e.stateMu.Unlock()

	var errs []error

	if handle != 0 {
		if err := e.err(e.api.close(handle)); err != nil {
			errs = append(errs, err)
		}
	}

	if loadedLibrary.handle != 0 {
		if err := loadedLibrary.close(); err != nil {
			errs = append(errs, err)
		}
	}

	closeErr := errors.Join(errs...)

	e.stateMu.Lock()
	e.closeErr = closeErr
	close(e.closeDone)
	e.stateMu.Unlock()

	return closeErr
}

func (e *Engine) beginOperation() (uintptr, func(), error) {
	if e == nil {
		return 0, nil, errEngineClosed
	}

	e.stateMu.Lock()
	defer e.stateMu.Unlock()

	if e.closing || e.handle == 0 {
		return 0, nil, errEngineClosed
	}

	e.active.Add(1)

	return e.handle, e.active.Done, nil
}

func (e *Engine) err(code int32) error {
	if code == 0 {
		return nil
	}

	message := "unknown error"
	if description := e.api.strerror(code); description != "" {
		message = description
	}

	return fmt.Errorf("unicorn error %d: %s", code, message)
}
