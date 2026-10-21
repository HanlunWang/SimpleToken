// Package proc runs child processes with a timeout and a clean environment. Every spawn (tokscale, the claude
// CLI) goes through it.
package proc

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"os/user"
	"syscall"
	"time"
)

// Output is what a finished child produced. The exit code is not judged here: tokscale may exit non-zero on empty
// data, so callers decide.
type Output struct {
	Stdout   []byte
	Stderr   []byte
	ExitCode int
}

// ErrTimeout is returned when the child ran past its timeout (it is terminated, then killed).
var ErrTimeout = errors.New("timed out")

// CleanEnv is a minimal environment. Required for every spawned CLI: an inherited CLAUDE_CODE_* or ANTHROPIC_*
// variable turns a child `claude` into an API-billed session.
func CleanEnv() []string {
	home, _ := os.UserHomeDir()
	name := os.Getenv("USER")
	if u, err := user.Current(); err == nil {
		name = u.Username
	}
	return []string{
		"HOME=" + home,
		"USER=" + name,
		"PATH=" + home + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
		"TERM=xterm-256color",
		"LANG=en_US.UTF-8",
	}
}

// Run executes bin with args in the home directory and a clean environment, and waits for it. On timeout the
// process group gets SIGTERM, then SIGKILL two seconds later.
func Run(ctx context.Context, bin string, args []string, timeout time.Duration) (Output, error) {
	return RunEnv(ctx, bin, args, CleanEnv(), timeout)
}

// RunEnv is Run with an explicit environment.
func RunEnv(ctx context.Context, bin string, args, env []string, timeout time.Duration) (Output, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Env = env
	cmd.Dir, _ = os.UserHomeDir()
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM) }
	cmd.WaitDelay = 2 * time.Second
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	res := Output{Stdout: out.Bytes(), Stderr: errb.Bytes()}
	if cmd.ProcessState != nil {
		res.ExitCode = cmd.ProcessState.ExitCode()
	}
	if ctx.Err() == context.DeadlineExceeded {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		return res, ErrTimeout
	}
	var exitErr *exec.ExitError
	if err != nil && !errors.As(err, &exitErr) {
		return res, err
	}
	return res, nil
}
