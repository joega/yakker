package radio

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

const PluginID = "io.github.joega.yakker"

// ParentGuard makes an abruptly terminated shell terminate its helper too.
// The caller must remain on this OS thread until exit.
func ParentGuard() error {
	parent := os.Getppid()
	_, _, errno := syscall.RawSyscall6(syscall.SYS_PRCTL, 1, uintptr(syscall.SIGTERM), 0, 0, 0, 0)
	if errno != 0 {
		return fmt.Errorf("set parent-death signal: %w", errno)
	}
	if os.Getppid() != parent {
		return fmt.Errorf("owning shell exited during startup")
	}
	return nil
}

func privateDirectory(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !info.IsDir() || !ok || stat.Uid != uint32(os.Getuid()) || info.Mode().Perm()&0077 != 0 {
		return fmt.Errorf("%s must be a private directory owned by you", path)
	}
	return nil
}

func acquireRuntime(base string) (string, *os.File, error) {
	if base == "" {
		base = os.Getenv("XDG_RUNTIME_DIR")
	}
	if base == "" {
		base = fmt.Sprintf("/run/user/%d", os.Getuid())
	}
	if err := privateDirectory(base); err != nil {
		return "", nil, err
	}
	dir := filepath.Join(base, PluginID)
	if err := os.Mkdir(dir, 0700); err != nil && !os.IsExist(err) {
		return "", nil, err
	}
	if err := privateDirectory(dir); err != nil {
		return "", nil, err
	}
	if len(filepath.Join(dir, "mpv.sock")) >= 104 {
		return "", nil, fmt.Errorf("radio runtime socket path is too long")
	}
	fd, err := syscall.Open(filepath.Join(dir, "owner.lock"), syscall.O_CREAT|syscall.O_RDWR|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0600)
	if err != nil {
		return "", nil, err
	}
	lock := os.NewFile(uintptr(fd), "owner.lock")
	if err = syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		return "", nil, fmt.Errorf("Yakker is already owned by another shell instance; retry shortly")
	}
	return dir, lock, nil
}
