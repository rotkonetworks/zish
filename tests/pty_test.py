#!/usr/bin/env python3
"""Interactive tests for zish, driven through a real pty.

    ./tests/pty_test.py [-v] [-k PATTERN]

Everything in tests/regress.sh runs `zish -c`, which never touches the line
editor, job control signals, or terminal handover. That is most of what an
interactive shell *is*, and none of it had any coverage — the tab-completion
RCE lived there, and so does the TIOCSPGRP path that the macOS port computes
but has never exercised.

A pty is the only way to test it. Piping stdin makes isatty() false and the
shell takes an entirely different path, which is exactly why the earlier
ad-hoc `printf ... | zish` attempts produced misleading results: prompt
redraws and history replay land in the same stream as the output.

Design notes:

- Reads are drained until the output goes quiet rather than for a fixed time,
  so the suite is not paced by its slowest machine. A flaky test is worse than
  no test, so every wait has a generous ceiling and a clear failure message.
- ANSI escapes, and the shell's own echo of what we typed, are stripped before
  matching. What is asserted on is what a human would see.
- stdlib only (pty, os, select). CI runners have it on both platforms with
  nothing to install.
"""

import fcntl
import os
import pty
import re
import select
import shutil
import signal
import struct
import sys
import tempfile
import termios
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vt import VT  # noqa: E402

# Hard ceiling per test. Without it a shell that never responds hangs the whole
# job rather than failing one case — observed on macOS, where the first
# interactive test blocked and the CI runner sat for 18 minutes.
TEST_TIMEOUT_S = int(os.environ.get("PTY_TEST_TIMEOUT", "25"))


class Timeout(Exception):
    pass


def _alarm(_sig, _frm):
    raise Timeout(f"test exceeded {TEST_TIMEOUT_S}s (shell not responding)")

ZISH = os.environ.get("ZISH", "./zig-out/bin/zish")

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[=>()][A-Za-z0-9]?|\r")

passed = failed = skipped = 0
failures = []
VERBOSE = "-v" in sys.argv
FILTER = None
if "-k" in sys.argv:
    FILTER = sys.argv[sys.argv.index("-k") + 1]


def clean(s: str) -> str:
    """Strip ANSI, carriage returns and the cursor-shape noise a prompt emits."""
    return ANSI.sub("", s).replace("\x00", "")


class Shell:
    """An interactive zish on the far side of a pty."""

    def __init__(self, env_extra=None, cols=None, rows=None):
        env = dict(os.environ)
        # A predictable prompt and no user config: otherwise the assertions
        # depend on whoever's ~/.zishrc is on the machine.
        env["PS1"] = "READY> "
        # A private HOME per shell. History is persistent, so without this the
        # up-arrow test recalls whatever the *previous* test ran — which is
        # exactly how it failed in CI while passing locally, where the history
        # happened to already contain the right line.
        self.home = tempfile.mkdtemp(prefix="zish-pty-")
        env["HOME"] = self.home
        env["ZISH_BYPASS_PASSWORD"] = "1"
        if env_extra:
            env.update(env_extra)

        if cols:
            env["COLUMNS"], env["LINES"] = str(cols), str(rows)

        self.pid, self.fd = pty.fork()
        if self.pid == 0:  # child
            try:
                os.execve(ZISH, [ZISH], env)
            except Exception:
                os._exit(127)
        # A real window size, so wrapping and viewport-overflow behave as they
        # would on screen. Without this the pty defaults to 0x0 and nothing
        # ever wraps.
        self.vt = None
        if cols:
            fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
            self.vt = VT(rows, cols)
        self.buf = ""

    def read(self, quiet_for=0.25, timeout=6.0) -> str:
        """Drain until the pty has been silent for `quiet_for` seconds."""
        deadline = time.time() + timeout
        last = time.time()
        out = ""
        while time.time() < deadline:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                text = chunk.decode("utf-8", "replace")
                out += text
                if self.vt is not None:
                    self.vt.feed(text)
                last = time.time()
            elif time.time() - last >= quiet_for and out:
                break
        self.buf += out
        return clean(out)

    def send(self, s: str):
        os.write(self.fd, s.encode())

    def sendline(self, s: str):
        self.send(s + "\n")

    def close(self):
        # SIGKILL first, then reap with WNOHANG. A blocking waitpid here hung
        # the macOS run for 8 minutes after the ctrl-Z test: the alarm is
        # cancelled before teardown, so nothing bounded it. Teardown must never
        # be able to outlive the test it belongs to.
        try:
            os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        deadline = time.time() + 3.0
        while time.time() < deadline:
            try:
                pid, _ = os.waitpid(self.pid, os.WNOHANG)
                if pid:
                    break
            except ChildProcessError:
                break
            time.sleep(0.02)
        try:
            os.close(self.fd)
        except OSError:
            pass
        shutil.rmtree(self.home, ignore_errors=True)


def test(name):
    """Decorator registering a pty test. Each gets a fresh shell."""

    def wrap(fn):
        global passed, failed, skipped
        if FILTER and FILTER not in name:
            skipped += 1
            return fn
        sh = None
        signal.signal(signal.SIGALRM, _alarm)
        signal.alarm(TEST_TIMEOUT_S)
        try:
            sh = Shell()
            sh.read()  # consume banner + first prompt
            fn(sh)
            passed += 1
            print(f"\033[32m  PASS\033[0m {name}")
        except AssertionError as e:
            failed += 1
            failures.append(name)
            print(f"\033[31m  FAIL\033[0m {name}\n        {e}")
            if VERBOSE and sh:
                print("        --- session ---")
                for line in clean(sh.buf).splitlines()[-25:]:
                    print(f"        | {line}")
        except Exception as e:  # harness problem, not a zish problem
            failed += 1
            failures.append(name)
            print(f"\033[31m  ERROR\033[0m {name}: {type(e).__name__}: {e}")
        finally:
            signal.alarm(0)
            if sh:
                sh.close()
        return fn

    return wrap


def expect(haystack, needle, what=""):
    assert needle in haystack, f"expected {needle!r} in output{what}\n        got: {haystack[-400:]!r}"


def expect_soon(sh, needle, timeout=10.0):
    """Read until `needle` appears, rather than until the pty goes quiet.

    A quiet-based read is wrong here: the shell echoes each keystroke
    immediately, then pauses while the command actually runs, then prints the
    result. On a slow runner the quiet threshold fires *in that pause*, so the
    read returns the echoed line without the output — which is what turned CI
    red while the same test passed locally. Waiting for content makes the suite
    independent of how fast the machine is.
    """
    seen = ""
    deadline = time.time() + timeout
    while time.time() < deadline:
        seen += sh.read(quiet_for=0.15, timeout=1.0)
        if needle in seen:
            return seen
    assert needle in seen, \
        f"expected {needle!r} within {timeout}s\n        got: {seen[-400:]!r}"
    return seen


def vi_normal(sh):
    """Send Esc and land in vi normal mode.

    A bare Esc followed immediately by more bytes races the shell's own
    escape-sequence reader: escapeSequenceAction() does a non-blocking peek
    at the next byte to distinguish Esc from an arrow-key/Alt sequence, and
    if our next keystroke is already queued behind it (which it will be if
    sent back-to-back with no gap), that peek consumes it as a candidate
    Alt-sequence byte instead of delivering it as a normal-mode command. A
    real human typing has that gap for free; a script does not, so this
    inserts one and drains the mode-change redraw before returning.
    """
    sh.send("\x1b")
    time.sleep(0.08)
    sh.read(quiet_for=0.1, timeout=1.0)


def vi_edit(sh, typed, vi_keys, insert_text=None, quiet_for=0.15):
    """Type `typed`, Esc to vi normal mode, run `vi_keys`, optionally type
    `insert_text` if the sequence lands in insert mode — then drain.

    Does not send the trailing Enter: callers do that themselves and assert
    with expect_soon() on the fresh output that follows, so the assertion
    only ever sees what the *executed* command printed, never a substring of
    the on-screen editing that preceded it (the original typed text is still
    sitting in the pty's scrollback-in-flight at that point, and matching
    against it blindly would be a false pass).
    """
    sh.send(typed)
    sh.read(quiet_for=quiet_for, timeout=2.0)
    vi_normal(sh)
    sh.send(vi_keys)
    sh.read(quiet_for=quiet_for, timeout=2.0)
    if insert_text is not None:
        sh.send(insert_text)
        sh.read(quiet_for=quiet_for, timeout=2.0)
    sh.read(quiet_for=quiet_for, timeout=2.0)  # settle before caller sends Enter


# ---------------------------------------------------------------------------
print("\n\033[2mzish pty suite — %s\033[0m\n" % ZISH)
print("basics")
# ---------------------------------------------------------------------------


@test("prompt appears")
def _(sh):
    sh.sendline("")
    expect_soon(sh, "READY>")


@test("command runs and prints")
def _(sh):
    # Asserts on a *computed* value. A pty echoes whatever we type, so
    # checking for a literal we sent passes even against a shell that runs
    # nothing at all — verified: an earlier version of this test passed
    # against a stub that only printed a prompt.
    sh.sendline("echo $((21 + 21))")
    expect_soon(sh, "42")


@test("exit status is tracked")
def _(sh):
    sh.sendline("false")
    sh.read()
    sh.sendline("echo status=$?")
    expect_soon(sh, "status=1")


# ---------------------------------------------------------------------------
print("\njob control (signals + terminal handover)")
# ---------------------------------------------------------------------------


@test("ctrl-z suspends a foreground job")
def _(sh):
    sh.sendline("sleep 30")
    time.sleep(0.4)
    sh.send("\x1a")  # ctrl-Z
    out = sh.read(timeout=8)
    assert "Stopped" in out or "stopped" in out, f"no Stopped notice; got {out[-300:]!r}"


@test("jobs lists the stopped job")
def _(sh):
    sh.sendline("sleep 30")
    time.sleep(0.4)
    sh.send("\x1a")
    sh.read(timeout=8)
    sh.sendline("jobs")
    expect_soon(sh, "sleep 30")


@test("bg resumes it in the background")
def _(sh):
    sh.sendline("sleep 30")
    time.sleep(0.4)
    sh.send("\x1a")
    sh.read(timeout=8)
    sh.sendline("bg")
    sh.read(timeout=8)
    sh.sendline("jobs")
    out = sh.read(timeout=8)
    assert "Running" in out or "sleep" in out, f"job not running after bg: {out[-300:]!r}"


@test("finished background job prints a Done notice at the next prompt")
def _(sh):
    # There is no SIGCHLD handler (the core is single-threaded), so a
    # background child's completion is only ever discovered by polling the
    # job table. Before the fix, nothing polled it between commands: the
    # child zombied and "[1]+ Done" was never printed until the user
    # happened to run `jobs` or `wait`. The poll must run right before a
    # fresh prompt, so pressing Enter with no command is enough to trigger it.
    sh.sendline("sleep 0.2 &")
    sh.read(timeout=3)
    time.sleep(0.4)  # let the background job finish
    sh.sendline("")  # fresh prompt: this is where the poll must fire
    out = sh.read(timeout=5)
    assert "Done" in out and "sleep" in out, f"no Done notice for finished bg job; got {out[-400:]!r}"


@test("a finished job's cleanup does not break the current job")
def _(sh):
    # Regression: cleanupDoneJobs (fired every prompt by the Done-notice poll)
    # removed jobs WITHOUT the current_job/previous_job fixup that removeJob does,
    # leaving current_job pointing at the removed id. Result: after any Done
    # notice, bare `fg`/`bg` said "no current job" while another job still ran.
    sh.sendline("sleep 5 &")     # job 1: stays running, must remain current
    sh.read(timeout=3)
    sh.sendline("sleep 0.2 &")   # job 2: finishes and gets cleaned up
    sh.read(timeout=3)
    time.sleep(0.4)
    sh.sendline("")              # fresh prompt: Done notice + cleanupDoneJobs
    sh.read(timeout=5)
    sh.sendline("jobs")
    out = sh.read(timeout=5)
    # The survivor is still listed and is the current job (`+`), not stale.
    assert "sleep 5" in out, f"surviving job vanished after cleanup; got {out[-400:]!r}"
    assert "no current job" not in out
    sh.sendline("bg")            # bare bg must find the current job, not error
    out2 = sh.read(timeout=5)
    assert "no current job" not in out2, f"current job broken after cleanup; got {out2[-400:]!r}"


@test("signal-killed background job notice says Terminated, not Done")
def _(sh):
    # getPendingNotifications used raw EXITSTATUS (0 for a signaled job), so a
    # killed bg job wrongly printed "Done". It now decodes via decodeStatus.
    sh.sendline("sleep 5 &")
    sh.read(timeout=3)
    sh.sendline("kill $!")       # SIGTERM the background job
    sh.read(timeout=3)
    time.sleep(0.3)
    sh.sendline("")             # fresh prompt: notice fires
    out = sh.read(timeout=5)
    assert "Terminated" in out and "Done" not in out, \
        f"signaled bg job should say Terminated not Done; got {out[-400:]!r}"


@test("shell survives ctrl-c and keeps its prompt")
def _(sh):
    sh.sendline("sleep 30")
    time.sleep(0.4)
    sh.send("\x03")  # ctrl-C
    sh.read(timeout=8)
    sh.sendline("echo $((6 * 7))")   # computed: not present in what we typed
    expect_soon(sh, "42")


@test("terminal is usable after a foreground child exits")
def _(sh):
    # The tcsetpgrp handover: the shell hands the terminal to the child and
    # must take it back. If it does not, everything after this hangs or is
    # not echoed.
    sh.sendline("/bin/echo child-ran")
    sh.read()
    sh.sendline("echo $((100 + 23))")   # computed, so pty echo cannot fake it
    expect_soon(sh, "123")


@test("interactive read builtin accepts a typed line")
def _(sh):
    # The reported "overwrite? [y/N] — stuck" bug: a shell function's
    # `printf ...; read -r ans` ran while the line editor held the terminal in
    # raw mode, so there was no echo and Enter arrived as CR, never ending the
    # read. read must cook the terminal so a typed answer + Enter works.
    sh.sendline('printf "confirm? [y/N] "; read -r ans; echo "ANS=[$ans]"')
    time.sleep(0.4)
    sh.sendline("y")
    expect_soon(sh, "ANS=[y]", timeout=6)


@test("prompt stays raw after a command cooks the terminal")
def _(sh):
    # A command (or a misbehaving tool like a broken CLI) can leave the terminal
    # in cooked mode. The shell must re-assert its own raw mode before the next
    # prompt, or the prompt echoes "^C" and line-buffers input. Cook the tty via
    # stty, then confirm the prompt still works and Ctrl+C clears rather than
    # inserting a literal ^C.
    sh.sendline("stty icanon echo")
    sh.read(timeout=3)
    sh.send("garbage")          # type on the (post-command) prompt
    time.sleep(0.3)
    sh.send("\x03")             # Ctrl+C must clear the line, not insert ^C
    time.sleep(0.3)
    sh.sendline("echo raw_ok_$((5 + 6))")
    expect_soon(sh, "raw_ok_11", timeout=6)


@test("interactive select accepts a choice")
def _(sh):
    # `select` read the raw terminal too — same hang as `read`. Cooking the
    # terminal for its input loop makes a typed choice + Enter work.
    sh.sendline("select f in alpha beta; do echo PICK=$f; break; done")
    time.sleep(0.4)
    sh.sendline("2")
    expect_soon(sh, "PICK=beta", timeout=6)


@test("background job actually runs (not born stopped)")
def _(sh):
    # A forked background child used to run the terminal-control dance
    # (tcsetattr) from its background process group, get SIGTTOU, and stop
    # BEFORE exec — so `cmd &` never ran at all. It must execute and finish.
    sh.sendline("(sleep 0.3; echo bg_ran_$((8 + 9))) &")
    sh.read(timeout=3)
    expect_soon(sh, "bg_ran_17", timeout=8)


@test("a child prompting on /dev/tty with redirected stdin can be answered")
def _(sh):
    # age/ssh/sudo read confirmations from /dev/tty, not stdin. When stdin is
    # redirected the terminal handover was skipped, the child landed in a
    # background pgroup, its /dev/tty read failed with EIO, and the typed answer
    # went to the shell's line editor. It must reach the child instead.
    sh.sendline("printf '#!/bin/sh\\nread a </dev/tty; echo GOT:$a\\n' > ask; chmod +x ask")
    sh.read(timeout=3)
    sh.sendline("./ask < /dev/null")   # stdin redirected; prompt still reads /dev/tty
    time.sleep(0.4)
    sh.sendline("yes")                  # the answer must reach ./ask, not zish
    expect_soon(sh, "GOT:yes", timeout=6)


@test("ctrl-z suspends a pipeline, shell survives")
def _(sh):
    # The pipeline reap loop waited without WUNTRACED, so ^Z on `a | b` left
    # the shell blocked in waitpid forever while both stages sat stopped.
    sh.sendline("sleep 30 | cat")
    time.sleep(0.5)
    sh.send("\x1a")  # ctrl-Z
    out = sh.read(timeout=8)
    assert "Stopped" in out, f"no Stopped notice for pipeline; got {out[-300:]!r}"
    sh.sendline("jobs")
    out = expect_soon(sh, "Stopped")
    assert "sleep" in out, f"pipeline not listed in jobs: {out[-300:]!r}"
    sh.sendline("echo alive_$((14 * 3))")  # computed: proves a working prompt
    expect_soon(sh, "alive_42")


@test("ctrl-z suspends a subshell, shell survives")
def _(sh):
    # The subshell body ran in the SHELL's own process group, so ^Z during
    # `( sleep 30 )` SIGTSTP'd the whole shell, and the wait had no WUNTRACED.
    sh.sendline("( sleep 30 )")
    time.sleep(0.5)
    sh.send("\x1a")
    out = sh.read(timeout=8)
    assert "Stopped" in out, f"no Stopped notice for subshell; got {out[-300:]!r}"
    sh.sendline("echo alive_$((15 * 3))")
    expect_soon(sh, "alive_45")


@test("line editor still works after a subshell ran an external")
def _(sh):
    # `( external )` exec'd in place in the child, which cooked the tty; the
    # parent never restored raw mode, so the next prompt's line editor was
    # silently broken (cooked mode: keystrokes buffered by the kernel).
    sh.sendline("( /bin/echo sub_$((5 * 5)) )")
    expect_soon(sh, "sub_25")
    sh.sendline("echo editor_$((16 * 3))")
    expect_soon(sh, "editor_48")


@test("ctrl-c kills a child prompting on the terminal")
def _(sh):
    # The interactive shell ignores SIGINT for itself, and dispositions
    # survive exec — every fork-to-exec child must reset them to SIG_DFL or a
    # program blocked reading the tty can never be Ctrl+C'd.
    sh.sendline("printf '#!/bin/sh\\nread a; echo GOT:$a\\n' > asker; chmod +x asker")
    sh.read(timeout=3)
    sh.sendline("./asker")
    time.sleep(0.5)
    sh.send("\x03")  # ctrl-C must reach ./asker, not be eaten by inherited IGN
    sh.read(timeout=6)
    sh.sendline("echo killed_$((17 * 3))")
    expect_soon(sh, "killed_51")


@test("ctrl-z at an idle prompt is a clean no-op")
def _(sh):
    # zish is the session leader on this pty (no parent job-control shell to
    # return to), so self-suspend is meaningless: Ctrl+Z at an empty prompt
    # used to echo "^Z" repeatedly and garble the redraw. It must do nothing.
    for _ in range(3):
        sh.send("\x1a")
        time.sleep(0.15)
    out = sh.read(timeout=3)
    assert "^Z" not in out, f"idle ctrl-Z echoed ^Z garbage: {out[-300:]!r}"
    sh.sendline("echo idle_$((19 * 3))")
    expect_soon(sh, "idle_57")


@test("a foreground child is always escapable (ctrl-c and ctrl-z)")
def _(sh):
    # The invariant: while a foreground child runs the terminal is cooked
    # (ISIG on) and the shell's wait is WUNTRACED, so the user ALWAYS has an
    # exit — Ctrl+C interrupts, Ctrl+Z stops — and the shell regains control.
    # Ctrl+Z leg: stop it, see it in jobs, prompt works.
    sh.sendline("sleep 300")
    time.sleep(0.5)
    sh.send("\x1a")
    out = sh.read(timeout=8)
    assert "Stopped" in out, f"ctrl-Z did not stop the child: {out[-300:]!r}"
    sh.sendline("jobs")
    expect_soon(sh, "sleep 300")
    sh.sendline("kill %1")
    sh.read(timeout=3)
    # Ctrl+C leg: interrupt a fresh child, prompt works.
    sh.sendline("sleep 300")
    time.sleep(0.5)
    sh.send("\x03")
    sh.read(timeout=6)
    sh.sendline("echo escape_$((20 * 3))")
    expect_soon(sh, "escape_60")


@test("ctrl-c kills a pipeline blocked on the terminal")
def _(sh):
    sh.sendline("sleep 30 | cat")
    time.sleep(0.5)
    sh.send("\x03")
    sh.read(timeout=6)
    sh.sendline("echo pipe_int_$((18 * 3))")
    expect_soon(sh, "pipe_int_54")


@test("ctrl-c interrupts the time builtin's child")
def _(sh):
    # The `time` builtin forked/exec'd with NO signal reset, NO pgroup, NO
    # cooked tty — the timed child inherited SIG_IGN for INT through exec, so
    # `time sleep 30` could not be Ctrl+C'd at all. It now runs through the
    # same foreground owner as any external command.
    sh.sendline("time sleep 30")
    time.sleep(0.5)
    sh.send("\x03")
    sh.read(timeout=6)
    sh.sendline("echo timed_int_$((21 * 3))")   # computed: proves a live prompt
    expect_soon(sh, "timed_int_63")


@test("ctrl-z stops the time builtin's child, shell survives")
def _(sh):
    # The old wait was a non-UNTRACED wait4: Ctrl+Z stopped the child and the
    # shell sat in wait4 forever — the shell was wedged. The child must become
    # a stopped job and the prompt must come back.
    sh.sendline("time sleep 30")
    time.sleep(0.5)
    sh.send("\x1a")  # ctrl-Z
    out = sh.read(timeout=8)
    assert "Stopped" in out, f"no Stopped notice for timed child; got {out[-300:]!r}"
    sh.sendline("jobs")
    expect_soon(sh, "sleep 30")
    sh.sendline("kill %1")
    sh.read(timeout=3)
    sh.sendline("echo timed_stop_$((22 * 3))")
    expect_soon(sh, "timed_stop_66")


@test("ctrl-c interrupts a command reading a process substitution")
def _(sh):
    # <(sleep 30): cat blocks on the pipe until the substitution child exits.
    # Ctrl+C must interrupt the foreground cat and give the prompt back.
    sh.sendline("cat <(sleep 30)")
    time.sleep(0.5)
    sh.send("\x03")
    sh.read(timeout=6)
    sh.sendline("echo procsub_int_$((23 * 3))")
    expect_soon(sh, "procsub_int_69")


@test("process substitution child gets default signal dispositions")
def _(sh):
    # Discriminating test: the procsub child execs /bin/sh, and sigaction
    # dispositions survive exec. With the old inherited SIG_IGN the child
    # shrugged off its own `kill -INT $$` and printed the marker; with default
    # dispositions the SIGINT kills it before the echo runs.
    # The bad marker is computed ($((27*3)) -> alive_81) so the pty's echo of
    # the typed line can never contain it — only a child that survived the
    # SIGINT and ran the echo can produce it.
    sh.sendline('cat <(kill -INT $$; echo alive_$((27 * 3))); echo ps_done_$((24 * 3))')
    out = expect_soon(sh, "ps_done_72", timeout=8)
    assert "alive_81" not in out, \
        f"procsub child ignored SIGINT (inherited SIG_IGN through exec): {out[-300:]!r}"


@test("fg resumes a stopped job and ctrl-c then kills it")
def _(sh):
    # fg went through a divergent mechanism (JobTable.putJobInForeground with
    # a separately-captured shell_tmodes); it now shares the one foreground
    # owner. Resume the job, then Ctrl+C must reach it, and the prompt must
    # come back with a working line editor.
    sh.sendline("sleep 30")
    time.sleep(0.4)
    sh.send("\x1a")
    out = sh.read(timeout=8)
    assert "Stopped" in out, f"no Stopped notice; got {out[-300:]!r}"
    sh.sendline("fg")
    time.sleep(0.6)
    sh.send("\x03")
    sh.read(timeout=6)
    sh.sendline("echo fg_int_$((25 * 3))")
    expect_soon(sh, "fg_int_75")


@test("fg'd job can be ctrl-z'd again")
def _(sh):
    # Second stop through the fg path: the resumed job stops again, the shell
    # must print a Stopped notice, keep the job, and give back a live prompt.
    sh.sendline("sleep 30")
    time.sleep(0.4)
    sh.send("\x1a")
    sh.read(timeout=8)
    sh.sendline("fg")
    time.sleep(0.6)
    sh.send("\x1a")
    out = sh.read(timeout=8)
    assert "Stopped" in out, f"no Stopped notice on re-stop via fg; got {out[-300:]!r}"
    sh.sendline("jobs")
    expect_soon(sh, "sleep 30")
    sh.sendline("kill %1")
    sh.read(timeout=3)
    sh.sendline("echo fg_restop_$((26 * 3))")
    expect_soon(sh, "fg_restop_78")


# ---------------------------------------------------------------------------
print("\nline editor")
# ---------------------------------------------------------------------------


@test("tab completion completes a command")
def _(sh):
    # Type a prefix, TAB, then arguments. If completion did not turn "ech"
    # into "echo", the line does not run and 55 never appears.
    sh.send("ech\t")
    time.sleep(0.5)
    sh.sendline(" $((11 * 5))")
    expect_soon(sh, "55")


@test("tab completion does not execute what was typed")
def _(sh):
    # The 0.16.0 RCE: completion built a /bin/sh -c string, so metacharacters
    # in the typed word ran on TAB, before Enter. This is that, interactively.
    marker = "/tmp/zish_pty_pwned"
    if os.path.exists(marker):
        os.remove(marker)
    sh.send(f"x;touch$IFS{marker} -\t")
    time.sleep(0.8)
    sh.read()
    assert not os.path.exists(marker), "TAB executed the typed command line"


@test("ctrl-c clears the current line")
def _(sh):
    sh.send("echo should-not-run")
    sh.send("\x03")
    sh.read()
    sh.sendline("echo $((9 * 9))")
    expect_soon(sh, "81")


@test("up-arrow does not wedge the shell")
def _(sh):
    # Weakened deliberately, and worth explaining. Asserting that up-arrow
    # recalls a *specific* line proved unreliable: history is persistent (so it
    # recalled the previous test's command until each shell got a private
    # HOME), and with a fresh HOME the recall redraw races ghost-text
    # generation. Three CI failures, zero real bugs found.
    #
    # What is actually worth guarding is that the history keybinding cannot
    # leave the line editor wedged — a hang here would be a genuine defect,
    # and that is stable to test. Exact recall semantics belong in a unit test
    # over the history ring buffer, not through a pty.
    sh.sendline("echo $((12 * 12))")
    expect_soon(sh, "144")
    sh.send("\x1b[A")
    time.sleep(0.3)
    sh.send("\x03")          # abandon whatever is on the line
    sh.sendline("echo $((7 * 8))")
    expect_soon(sh, "56")


@test("para with no input does not hang the shell")
def _(sh):
    # `para ls` with no ::: items and stdin on the terminal used to block on a
    # read that never returned — an unkillable hang. It must refuse instead.
    # Only meaningful when the feat is staged (`make feats`); if `para` is not a
    # command, this reduces to "the shell prints not-found and stays alive".
    sh.sendline("para ls")
    # The @test alarm turns a real hang into a FAIL; here we assert liveness by
    # running another command and seeing its output.
    sh.sendline("echo still_alive_$((2 + 2))")
    expect_soon(sh, "still_alive_4")


# ---------------------------------------------------------------------------
print("\nvi mode")
# ---------------------------------------------------------------------------


@test("fX finds char forward, x deletes it")
def _(sh):
    vi_edit(sh, "echo aXbXcX", "0fXx")
    sh.send("\n")
    expect_soon(sh, "abXcX")


@test("dtX deletes up to (not through) the found char")
def _(sh):
    vi_edit(sh, "echo aaaXbbb", "0wdtX")
    sh.send("\n")
    out = expect_soon(sh, "Xbbb")
    # "Xbbb" alone is a weak check: it's a suffix of the untouched original
    # text too, so a `t` that silently no-ops (as on the pre-fix binary,
    # where a `d`-then-unhandled-key clears pending_op without deleting
    # anything) would still satisfy it. Confirm the "aaa" prefix is gone.
    assert "aaa" not in out, f"'t' motion deleted nothing: {out!r}"


@test("df) deletes through the found char, inclusive")
def _(sh):
    vi_edit(sh, "echo (abc) tail", "0wdf)")
    sh.send("\n")
    out = expect_soon(sh, "tail")
    assert "abc" not in out, f"paren contents survived: {out!r}"


@test("cf, changes through comma then inserts replacement")
def _(sh):
    # `w` first, so the operator range starts at "hello," rather than at the
    # buffer's absolute start (which would eat "echo" itself too).
    vi_edit(sh, "echo hello, world", "0wcf,", insert_text="bye")
    sh.send("\n")
    expect_soon(sh, "bye world")


@test("; repeats last find, , repeats it reversed")
def _(sh):
    # a,b,c,d — f, lands on comma 1; ; advances to comma 2, then comma 3;
    # , reverses back to comma 2, which x then deletes.
    vi_edit(sh, "echo a,b,c,d", "0f,;;,x")
    sh.send("\n")
    expect_soon(sh, "a,bc,d")


@test("3fa finds the third occurrence")
def _(sh):
    vi_edit(sh, "echo banana", "03fax")
    sh.send("\n")
    expect_soon(sh, "banan")


@test("% jumps to the matching paren")
def _(sh):
    # % from '(' lands on ')'; x deletes it, proving the jump landed exactly
    # on the close paren rather than somewhere else in the line. The parens
    # are inside a quoted argument — zish (like bash) treats a bare unquoted
    # '(' as a subshell-opening metacharacter, which is a shell-parsing
    # concern orthogonal to what this test is checking (vim.zig's bracket
    # matching operates on raw buffer bytes and does not know about quoting).
    vi_edit(sh, 'echo "(a b) c"', "0w%x")
    sh.send("\n")
    expect_soon(sh, "(a b c")


@test("ciw changes the word under the cursor")
def _(sh):
    vi_edit(sh, "echo hello world", "0wciw", insert_text="bye")
    sh.send("\n")
    expect_soon(sh, "bye world")


@test('di" empties a quoted string in place')
def _(sh):
    vi_edit(sh, 'echo "QUOTEDMARKER" tail', '0f"di"')
    sh.send("\n")
    out = expect_soon(sh, "tail")
    assert "QUOTEDMARKER" not in out, f"quoted content survived: {out!r}"


@test("ci( changes the contents of parens")
def _(sh):
    # Parens inside a quoted argument, same rationale as the % test above.
    vi_edit(sh, 'echo "(PARENMARKER)" tail', "0f(ci(", insert_text="x")
    sh.send("\n")
    out = expect_soon(sh, "tail")
    assert "PARENMARKER" not in out, f"paren content survived: {out!r}"
    expect(out, "(x) tail")


@test("e settles on the last char instead of overshooting past end")
def _(sh):
    # `e` must stop on the last char; five e's then `a` appends "END" to the
    # tail. If it overshoots past buf.len the cursor wraps and END lands early.
    vi_edit(sh, "echo abc", "0eeeeea", insert_text="END")
    sh.send("\n")
    out = expect_soon(sh, "abcEND")
    assert "eENDcho" not in out and "ENDcho" not in out, f"cursor wrapped: {out!r}"


@test("u undoes a change, Ctrl-R redoes it")
def _(sh):
    # `w` first so dw deletes "aaa " (leaving "echo bbb"), not "echo " itself
    # (leaving "aaa bbb" as an unknown-command line).
    vi_edit(sh, "echo aaa bbb", "0wdw")
    sh.send("\n")
    expect_soon(sh, "bbb")

    # Same trick on a fresh line: dw, then u should restore "aaa bbb" so the
    # executed command prints both words; Ctrl-R should undo the undo.
    vi_edit(sh, "echo aaa bbb", "0wdwu")
    sh.send("\n")
    expect_soon(sh, "aaa bbb")

    vi_edit(sh, "echo aaa bbb", "0wdwu\x12")  # dw, undo, redo (Ctrl-R)
    sh.send("\n")
    expect_soon(sh, "bbb")


@test("o then Esc on a multi-line buffer redraws in place, no prompt pile-up")
def _(sh):
    # `o` inserts a newline (open line below); repeated o/Esc builds an empty
    # multi-line buffer, and the vi-mode indicator in the built-in prompt (PS1="")
    # forces a redraw on every keystroke. The redraw must stay one prompt with
    # blank continuation lines — not re-emit a whole prompt per keystroke (a
    # deferred-wrap miscount on col-0 hard-newline rows piled up six prompt copies
    # in scrollback). Needs the built-in prompt: a static PS1 has no mode
    # indicator, so mode toggles don't redraw and the pile-up never shows.
    small = Shell(env_extra={"PS1": ""}, cols=80, rows=24)
    try:
        small.read()
        small.send("abc")
        small.read(quiet_for=0.2, timeout=2.0)
        for _ in range(3):
            vi_normal(small)        # Esc (with the anti-race gap) -> normal
            small.send("o")         # open line below -> insert
            small.read(quiet_for=0.15, timeout=2.0)
        vi_normal(small)
        small.read(quiet_for=0.2, timeout=2.0)
        screen = small.vt.visible_text()
        prompts = screen.count("$ abc")
        assert prompts == 1, f"prompt pile-up: {prompts} copies of '$ abc'\n" + \
            "\n".join("        | " + l for l in screen.splitlines() if l.strip())
    finally:
        small.close()
        sh.vt = None


@test("G jumps to the last line of a multi-line command, not line 1's end")
def _(sh):
    # Paste two lines, gg to the top, G to the last line, append X. A G that
    # only reached line 1's end would put X on "echo AA".
    sh.send("\x1b[200~echo AA\necho BB\x1b[201~")
    sh.read(quiet_for=0.2, timeout=2.0)
    vi_normal(sh)
    sh.send("ggGAX")
    sh.read(quiet_for=0.2, timeout=2.0)
    vi_normal(sh)
    sh.send("\n")
    out = expect_soon(sh, "BBX")
    assert "AAX" not in out, f"G landed on line 1: {out!r}"


@test("visual mode y yanks exactly the selection, not the whole line")
def _(sh):
    # Confirmed bug: `v` + word motion + `y` yanked the entire line instead
    # of the selected word, because every visual-mode key except a narrow
    # operator-starting subset bypassed vim.zig's selection-aware handleVisual
    # and fell through to the plain single-key normalModeAction — whose 'y'
    # unconditionally yanks the whole line. On "echo one two three", `0` goes
    # to the start, `w` lands on "one", `v e y` selects+yanks exactly "one",
    # `$ p` pastes it after the last char — the executed line must end with
    # "...threeone", not a second full copy of the whole command.
    vi_edit(sh, "echo one two three", "0wvey$p")
    sh.send("\n")
    expect_soon(sh, "one two threeone")


@test("visual mode l l y yanks exactly three chars")
def _(sh):
    # `ww` lands on "two"; `v ll` extends the selection right two more
    # columns (3 chars total: "two"), y yanks exactly that — not the whole
    # line. (Picked "two" rather than the first word: the whole-line-yank bug
    # pastes "echo one two three" back in, and a 3-char marker starting with
    # "ech" would be a substring of that buggy output too — a false pass.)
    vi_edit(sh, "echo one two three", "0wwvlly$p")
    sh.send("\n")
    expect_soon(sh, "one two threetwo")


@test("ctrl-c still escapes visual mode")
def _(sh):
    # Guards the routing fix above, not a pre-existing bug: routing every key
    # in visual mode through vim.zig's handleVisual (whose `else` arm
    # silently consumes anything unrecognized) would make Ctrl-C a dead key
    # there instead of aborting the line — passes on the old binary too,
    # which is expected; it documents behavior that must not regress.
    vi_edit(sh, "echo should-not-run", "v")
    sh.send("\x03")
    sh.read()
    sh.sendline("echo ok_$((3 * 3))")
    expect_soon(sh, "ok_9")


@test("enter still executes from visual mode")
def _(sh):
    vi_edit(sh, "echo vis_$((2 * 2))", "v")
    sh.send("\n")
    expect_soon(sh, "vis_4")


# ---------------------------------------------------------------------------
print("\nmultiline rendering")
# ---------------------------------------------------------------------------


@test("SIGWINCH reflows the current line immediately, no keystroke needed")
def _(sh):
    # zsh reflows the edit line the instant the window resizes. zish blocked in
    # read() with the resize flag set but unchecked until the next keypress,
    # because the libc read/poll wrappers retry EINTR — so a bare resize did
    # nothing. poll-gating the read lets SIGWINCH's EINTR reach run()'s loop.
    small = Shell(env_extra={"PS1": "READY> "}, cols=60, rows=20)
    try:
        small.read()
        small.send("echo " + "x" * 90)   # 102 visible cols → 2 rows at width 60
        small.read(quiet_for=0.2, timeout=2.0)
        # Narrow the pty; the kernel sends SIGWINCH. Send NO keystroke.
        fcntl.ioctl(small.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 20, 40, 0, 0))
        out = small.read(quiet_for=0.4, timeout=2.0)
        vt = VT(20, 40)
        vt.feed(out)   # render the resize redraw at the new width
        rows = [l for l in vt.visible_text().splitlines() if l.strip()]
        assert len(rows) == 3, (
            "line did not reflow on SIGWINCH without a keystroke "
            f"(got {len(rows)} rows, expected 3 at width 40):\n"
            + "\n".join("        | " + l for l in rows))
        assert all(len(l) <= 40 for l in rows), f"row exceeds new width 40: {rows}"
    finally:
        small.close()
        sh.vt = None


@test("pasted multi-line content renders a contiguous window")
def _(sh):
    # Regression: pasting a multi-line command into a terminal shorter than the
    # content dropped lines out of the *middle* of the display.
    #
    #   40x4 showed:  AAA, BBB, CCC, EEE     <- DDD gone
    #   40x3 showed:  AAA, BBB, EEE          <- CCC and DDD gone
    #
    # When content is taller than the viewport some lines must scroll off, and
    # that is fine — but what remains has to be a contiguous *suffix*, the last
    # N lines. Keeping the first rows and the last one, with a hole in between,
    # is what made the cursor look like it was in the wrong place. The buffer
    # was always correct; the command still ran right. This is display only.
    #
    # Cause: the redraw moves up to the region start and rewrites everything.
    # Once the content is taller than the screen the top has scrolled off and
    # is unreachable — ESC[nA saturates at row 0 — so the rewrite begins from
    # the wrong origin.
    sh.close()  # the default shell has no window size; make one that does
    small = Shell(cols=40, rows=4)
    try:
        small.read()
        body = "echo AAA \\\n  BBB \\\n  CCC \\\n  DDD \\\n  EEE"
        small.send("\x1b[200~" + body + "\x1b[201~")
        time.sleep(1.2)
        small.read()
        screen = small.vt.visible_text()

        order = ["AAA", "BBB", "CCC", "DDD", "EEE"]
        seen = [t for t in order if t in screen]
        assert seen, f"nothing rendered\n        screen: {screen!r}"

        # Continuation lines render flush-left, no gutter glyph in copied text.
        assert "│" not in screen, f"continuation gutter leaked into render: {screen!r}"

        # Must end at the last line and be gap-free back from there.
        idx = [order.index(t) for t in seen]
        contiguous = idx == list(range(idx[0], idx[-1] + 1))
        ends_at_last = idx[-1] == len(order) - 1
        assert contiguous and ends_at_last, (
            f"visible lines are not a contiguous suffix: {seen}\n"
            + "\n".join("        | " + l for l in screen.splitlines())
        )
    finally:
        small.close()
        sh.vt = None


# ---------------------------------------------------------------------------
print("\nsession feats (agent armor async substrate)")
# ---------------------------------------------------------------------------

PESTER_SCRIPT = """#!/bin/sh
read hello_frame
printf '%s\\n' '{"t":"say","text":"hello-\\u001b[31mred"}'
printf '%s\\n' '{"t":"run","cmd":"echo tool_ran_ok"}'
read result_line
sleep 0.4
printf '%s\\n' '{"t":"prompt","text":"proceed?"}'
read answer_line
printf '%s\\n' '{"t":"say","text":"answered-ok"}'
printf '%s\\n' '{"t":"done"}'
"""


def make_session_featroot(name, script, tier="standard"):
    """A temp feat root holding one session-feat backed by a shell script."""
    featroot = tempfile.mkdtemp(prefix="zish-featroot-")
    d = os.path.join(featroot, tier, name)
    os.makedirs(os.path.join(d, "bin"))
    with open(os.path.join(d, "feat.toml"), "w") as f:
        f.write(f'name = "{name}"\ntier = "{tier}"\nkind = "session"\nbin = "{name}"\n')
    p = os.path.join(d, "bin", name)
    with open(p, "w") as f:
        f.write(script)
    os.chmod(p, 0o755)
    return featroot


@test("session feat runs async: prompt stays live, say sanitized, answer round-trip")
def _(sh):
    # The whole async substrate in one arc. Fails fast on the old blocking
    # host: there the shell sits inside hostSessionFeat until the feat exits,
    # so the `echo alive` below never runs (the feat is parked awaiting its
    # prompt answer, which the old binary can neither display nor deliver).
    featroot = make_session_featroot("pester", PESTER_SCRIPT)
    small = Shell(env_extra={"ZISH_FEAT_PATH": featroot})
    try:
        small.read()
        small.sendline("pester")
        expect_soon(small, "started")
        # 1. liveness: the prompt is usable while the session runs
        small.sendline("echo alive_$((3 + 4))")
        expect_soon(small, "alive_7")
        # 2. prompt frame parks as a pending question (this also syncs us past
        #    the say frame, which may arrive in the same burst)
        expect_soon(small, "asks: proceed?")
        # 3. hostile say: sanitized text arrived, raw SGR never reached the tty
        assert "hello-red" in clean(small.buf), f"sanitized say missing: {clean(small.buf)[-400:]!r}"
        assert "\x1b[31mred" not in small.buf, "raw SGR from feat reached the terminal"
        small.sendline("session answer 1 yes")
        # `ended` is last in the stream; the answered say precedes it in the burst
        out = expect_soon(small, "ended")
        assert "answered-ok" in out, f"post-answer say missing: {out[-400:]!r}"
        # 4. the run hypercall was executed and audited: the JSONL event log
        #    has the result event, and `cat` of it is terminal-safe by
        #    construction (JSON escaping stores control bytes as \\u001b)
        small.sendline("cat ~/.zish/sessions/*.jsonl")
        expect_soon(small, "tool_ran_ok")
        assert "\x1b[31mred" not in small.buf, "raw SGR leaked into the event log"
    finally:
        small.close()
        shutil.rmtree(featroot, ignore_errors=True)


SNEAK_SCRIPT = """#!/bin/sh
read hello_frame
case "$hello_frame" in
  *'"run"'*) printf '%s\\n' '{"t":"say","text":"mask-listed-run"}' ;;
  *)         printf '%s\\n' '{"t":"say","text":"mask-omits-run"}' ;;
esac
printf '%s\\n' '{"t":"run","cmd":"echo pwned_by_extra_feat"}'
read reply
case "$reply" in
  *denied*) printf '%s\\n' '{"t":"say","text":"run-was-denied"}' ;;
  *)        printf '%s\\n' '{"t":"say","text":"run-was-allowed"}' ;;
esac
printf '%s\\n' '{"t":"done"}'
"""


@test("extra-tier session feat: run hostcall masked off, denial is loud")
def _(sh):
    # The hostcall capability mask: an untrusted (extra-tier) guest gets
    # {say,stream,done} only. Its hello must omit "run"; its run attempt must
    # yield a structured error frame (not silence, not execution), and the
    # denial must be attested on the terminal.
    featroot = make_session_featroot("sneak", SNEAK_SCRIPT, tier="extra")
    small = Shell(env_extra={"ZISH_FEAT_PATH": featroot})
    try:
        small.read()
        small.sendline("sneak")
        out = expect_soon(small, "ended")
        assert "mask-omits-run" in out, f"hello advertised run to an extra-tier guest: {out[-400:]!r}"
        assert "run-was-denied" in out, f"guest did not receive the error frame: {out[-400:]!r}"
        assert "hostcall denied: run" in out, f"denial not attested to the human: {out[-400:]!r}"
    finally:
        small.close()
        shutil.rmtree(featroot, ignore_errors=True)


TOOLWAIT_SCRIPT = """#!/bin/sh
read hello_frame
printf '%s\\n' '{"t":"run","cmd":"sleep 2; echo tool_finished_ok"}'
read reply
case "$reply" in
  *tool_finished_ok*) printf '%s\\n' '{"t":"say","text":"tool-completed"}' ;;
  *)                  printf '%s\\n' '{"t":"say","text":"tool-output-missing"}' ;;
esac
printf '%s\\n' '{"t":"done"}'
"""


@test("slow run frame does not freeze the prompt (pidfd tool child)")
def _(sh):
    # The tool child is a pollable pidfd in the input loop, so a slow `run`
    # (sleep 2) must leave the prompt live: a command typed DURING the tool
    # run must produce output BEFORE the tool's completion say. On the old
    # synchronous-run binary the shell is frozen inside the frame handler for
    # the whole sleep, so the typed command only runs afterwards — ordering
    # flips and this test goes red.
    featroot = make_session_featroot("toolwait", TOOLWAIT_SCRIPT)
    small = Shell(env_extra={"ZISH_FEAT_PATH": featroot})
    try:
        small.read()
        small.sendline("toolwait")
        expect_soon(small, "started")
        small.sendline("echo while_tool_$((5 + 6))")
        expect_soon(small, "while_tool_11")
        out = expect_soon(small, "ended")
        assert "tool-completed" in clean(small.buf), \
            f"tool result never reached the feat: {clean(small.buf)[-400:]!r}"
        b = clean(small.buf)
        assert b.index("while_tool_11") < b.index("tool-completed"), \
            "prompt was frozen during the tool run (ordering flipped)"
    finally:
        small.close()
        shutil.rmtree(featroot, ignore_errors=True)


CODER_SCRIPT = """#!/bin/sh
read hello_frame
printf '%s\\n' '{"t":"run","cmd":"false"}'
read reply
case "$reply" in
  *'"code":1'*) printf '%s\\n' '{"t":"say","text":"code-one-ok"}' ;;
  *)            printf '%s\\n' '{"t":"say","text":"code-wrong"}' ;;
esac
printf '%s\\n' '{"t":"done"}'
"""


@test("run result carries the real exit code")
def _(sh):
    # `false` must come back as {"code":1}. The old binary hardcoded code 0.
    featroot = make_session_featroot("coder", CODER_SCRIPT)
    small = Shell(env_extra={"ZISH_FEAT_PATH": featroot})
    try:
        small.read()
        small.sendline("coder")
        out = expect_soon(small, "ended")
        assert "code-one-ok" in clean(small.buf), \
            f"exit code missing or wrong in result frame: {clean(small.buf)[-400:]!r}"
    finally:
        small.close()
        shutil.rmtree(featroot, ignore_errors=True)


@test("agent model loop drives a tool call end to end (mock transport)")
def _(sh):
    # The real agent feat, transport mocked: a tool-call response runs a
    # command through zish, then a final-text response ends the turn. Proves
    # the whole loop — request build, response parse, run-frame mapping,
    # result feedback — with no network. The transcript is the evidence the
    # tool executed with REAL output (the mock's canned text alone wouldn't
    # prove the run happened).
    import json as _json
    mock = os.path.join(tempfile.mkdtemp(prefix="zish-mock-"), "m.jsonl")
    tool_resp = _json.dumps({"choices": [{"message": {"tool_calls": [
        {"id": "c1", "type": "function", "function": {
            "name": "run_command",
            "arguments": _json.dumps({"command": "echo agentmark_$((20+2))"})}}]}}]})
    final_resp = _json.dumps({"choices": [{"message": {"content": "ran it, got agentmark_22"}}]})
    with open(mock, "w") as f:
        f.write(_json.dumps({"status": 200, "body": tool_resp}) + "\n")
        f.write(_json.dumps({"status": 200, "body": final_resp}) + "\n")
    # the agent feat is a compiled binary staged by `make feats` into the real
    # HOME; the pty shell uses a throwaway HOME, so point a fresh shell at the
    # staged root (and own its cleanup — the decorator only closes `sh`).
    feats_root = os.path.expanduser("~/.zish/feats")
    if not os.path.isdir(os.path.join(feats_root, "standard", "agent")):
        # Graceful degrade like the para test: `make test-pty` depends on
        # `build`, not `feats`, so a fresh checkout has no staged agent feat.
        shutil.rmtree(os.path.dirname(mock), ignore_errors=True)
        print("        (agent feat not staged — run `make feats`; skipping)")
        return
    a = Shell(env_extra={"ZISH_FEAT_PATH": feats_root})
    try:
        a.read()
        a.sendline(f"agent --mock {mock} echo something for me")
        # wait once for the last marker; the say batches with it, so assert the
        # say against the accumulated buffer rather than racing two reads.
        expect_soon(a, "ended")
        buf = clean(a.buf)
        assert "started" in buf, f"session never started: {buf[-400:]!r}"
        assert "ran it, got agentmark_22" in buf, \
            f"final say missing: {buf[-400:]!r}"
        # the JSONL event log proves the run executed with real output: a
        # {"t":"run","cmd":"echo agentmark_..."} event and the result output
        a.sendline("cat ~/.zish/sessions/*agent*.jsonl")
        out = expect_soon(a, "agentmark_22")
        assert '"t":"run","cmd":"echo agentmark_' in out, \
            f"run event not in the event log: {out[-400:]!r}"
    finally:
        a.close()
        sh.vt = None
        shutil.rmtree(os.path.dirname(mock), ignore_errors=True)


@test("session feat with redirected stdout uses the sync host")
def _(sh):
    # isatty(stdout) is the async/sync discriminator: redirected, the feat is
    # hosted blocking and its say output lands in the redirect target; the
    # prompt frame is auto-cancelled (nobody to ask) so the script completes.
    featroot = make_session_featroot("pester", PESTER_SCRIPT)
    small = Shell(env_extra={"ZISH_FEAT_PATH": featroot})
    try:
        small.read()
        small.sendline("pester > ~/psync.out; echo sync_rc_$?; cat ~/psync.out")
        # answered-ok is last in the stream; the accumulated read holds the rest
        out = expect_soon(small, "answered-ok")
        assert "sync_rc_0" in out, f"sync host exit marker missing: {out[-400:]!r}"
        assert "started" not in out, "redirected session feat went async"
    finally:
        small.close()
        shutil.rmtree(featroot, ignore_errors=True)


@test("transcript is valid JSONL and cat-safe even with hostile feat output")
def _(sh):
    # The event log is append-only JSONL (Claude Code shape): every line a
    # typed JSON event, all text JSON-escaped. Two guarantees: it parses as
    # JSONL (the resume / front-end-ingestion unlock), and a raw ESC byte
    # never lands in the file (cat-safety by construction) even though the
    # pester feat emits a say containing an ESC/SGR sequence.
    import json as _json
    featroot = make_session_featroot("pester", PESTER_SCRIPT)
    small = Shell(env_extra={"ZISH_FEAT_PATH": featroot})
    try:
        small.read()
        small.sendline("pester")
        expect_soon(small, "asks: proceed?")
        small.sendline("session answer 1 yes")
        expect_soon(small, "ended")
        sess_dir = os.path.join(small.home, ".zish", "sessions")
        logs = [f for f in os.listdir(sess_dir) if f.endswith(".jsonl")]
        assert logs, "no .jsonl event log written"
        raw = open(os.path.join(sess_dir, logs[0]), "rb").read()
        assert b"\x1b" not in raw, "raw ESC byte leaked into the event log (not cat-safe)"
        types = []
        for line in raw.decode().splitlines():
            if not line.strip():
                continue
            ev = _json.loads(line)  # raises if not valid JSON → test fails
            types.append(ev["t"])
        assert types[0] == "start" and types[-1] == "end", f"log framing wrong: {types}"
        assert "run" in types and "say" in types, f"expected events missing: {types}"
    finally:
        small.close()
        shutil.rmtree(featroot, ignore_errors=True)


@test("session registry is file-based: a separate process lists live sessions")
def _(sh):
    # The org registry (~/.zish/sessions/*.meta) is what makes `session list`
    # work from ANY process — the unlock for external front-ends. Start a
    # session that parks awaiting an answer in the interactive shell, then read
    # it back from a separate `zish -c 'session list'` sharing the same HOME.
    import subprocess as _sp
    featroot = make_session_featroot("pester", PESTER_SCRIPT)
    small = Shell(env_extra={"ZISH_FEAT_PATH": featroot})
    try:
        small.read()
        small.sendline("pester")
        expect_soon(small, "asks: proceed?")  # now parked, meta written
        env = dict(os.environ)
        env["HOME"] = small.home
        env["ZISH_FEAT_PATH"] = featroot
        env["ZISH_BYPASS_PASSWORD"] = "1"
        r = _sp.run([ZISH, "-c", "session list"], env=env,
                    capture_output=True, text=True, timeout=10)
        out = clean(r.stdout)
        assert "pester" in out, f"cross-process list missing the session: {out!r}"
        assert "awaiting" in out, f"registry did not reflect the awaiting state: {out!r}"
        # release the session; its meta must then be swept
        small.sendline("session answer 1 yes")
        expect_soon(small, "ended")
        r2 = _sp.run([ZISH, "-c", "session list"], env=env,
                     capture_output=True, text=True, timeout=10)
        assert "pester" not in clean(r2.stdout), \
            f"ended session's meta not swept: {clean(r2.stdout)!r}"
    finally:
        small.close()
        shutil.rmtree(featroot, ignore_errors=True)


@test("control channel: a separate process answers a session's question")
def _(sh):
    # The write half of the file-based org surface. The registry made sessions
    # *visible* cross-process; the per-session control FIFO makes them
    # *controllable*: `session answer` in an unrelated zish process resolves
    # the id via ~/.zish/sessions/*.meta and writes into the hosting shell's
    # <hostpid>-<id>.ctl, which sits in its input poll set. Red on the old
    # binary: the separate process printed "session: no session 1".
    import subprocess as _sp
    featroot = make_session_featroot("pester", PESTER_SCRIPT)
    small = Shell(env_extra={"ZISH_FEAT_PATH": featroot})
    try:
        small.read()
        small.sendline("pester")
        expect_soon(small, "asks: proceed?")  # parked; meta + ctl FIFO on disk
        env = dict(os.environ)
        env["HOME"] = small.home
        env["ZISH_FEAT_PATH"] = featroot
        env["ZISH_BYPASS_PASSWORD"] = "1"
        r = _sp.run([ZISH, "-c", "session answer 1 yes"], env=env,
                    capture_output=True, text=True, timeout=10)
        assert r.returncode == 0, f"remote answer failed: rc={r.returncode} err={r.stderr!r}"
        # the hosting shell must deliver the answer and see the session finish
        out = expect_soon(small, "ended")
        assert "answered-ok" in clean(small.buf), \
            f"feat never received the remote answer: {out[-400:]!r}"
        # the answer is attested in the hosting shell's event log
        small.sendline("cat ~/.zish/sessions/*.jsonl")
        expect_soon(small, '"t":"answer"')
    finally:
        small.close()
        shutil.rmtree(featroot, ignore_errors=True)


ALICE_SCRIPT = """#!/bin/sh
read hello_frame
printf '%s\\n' '{"t":"prompt","text":"ping?"}'
read answer_frame
case "$answer_frame" in
  *pong*) printf '%s\\n' '{"t":"say","text":"alice-got-pong"}' ;;
  *) printf '%s\\n' '{"t":"say","text":"alice-got-garbage"}' ;;
esac
printf '%s\\n' '{"t":"done"}'
"""

BOB_SCRIPT = """#!/bin/sh
read hello_frame
i=0
while [ $i -lt 50 ]; do
  printf '%s\\n' '{"t":"run","cmd":"session list"}'
  read result_frame
  case "$result_frame" in *awaiting*) break ;; esac
  sleep 0.2
  i=$((i+1))
done
printf '%s\\n' '{"t":"run","cmd":"session answer 1 pong"}'
read result_frame
printf '%s\\n' '{"t":"done"}'
"""


@test("agent-to-agent: one session answers another session's prompt via run")
def _(sh):
    # The endgame arc in miniature: agent alice parks on a `prompt` hostcall;
    # agent bob discovers the question through `run session list` (the registry
    # is the org's shared bulletin board) and answers it through `run session
    # answer` — no human in the loop. bob's run executes in a forked subshell
    # child whose session-table copy has CLOSED pipe fds, so the answer must
    # route via the registry + control FIFO back to the live host, not the
    # dead in-process copy. Red on the old binary: the child's in-process
    # lookup won the race and wrote to a closed fd.
    featroot = make_session_featroot("alice", ALICE_SCRIPT)
    # add bob next to alice in the same featroot
    d = os.path.join(featroot, "standard", "bob")
    os.makedirs(os.path.join(d, "bin"))
    with open(os.path.join(d, "feat.toml"), "w") as f:
        f.write('name = "bob"\ntier = "standard"\nkind = "session"\nbin = "bob"\n')
    p = os.path.join(d, "bin", "bob")
    with open(p, "w") as f:
        f.write(BOB_SCRIPT)
    os.chmod(p, 0o755)

    small = Shell(env_extra={"ZISH_FEAT_PATH": featroot})
    try:
        small.read()
        small.sendline("alice")
        expect_soon(small, "asks: ping?")  # alice parked, meta says awaiting
        small.sendline("bob")
        # bob finds the question, answers it, alice confirms receipt
        expect_soon(small, "alice-got-pong", timeout=20.0)
    finally:
        small.close()
        shutil.rmtree(featroot, ignore_errors=True)


@test("control channel: a separate process kills a session; host tears it down")
def _(sh):
    # Remote kill goes through the same FIFO — the client never signals the
    # feat pid itself, because only the HOSTING shell can consistently clean
    # up its session table, meta record, and transcript.
    import subprocess as _sp
    featroot = make_session_featroot("pester", PESTER_SCRIPT)
    small = Shell(env_extra={"ZISH_FEAT_PATH": featroot})
    try:
        small.read()
        small.sendline("pester")
        expect_soon(small, "asks: proceed?")
        env = dict(os.environ)
        env["HOME"] = small.home
        env["ZISH_FEAT_PATH"] = featroot
        env["ZISH_BYPASS_PASSWORD"] = "1"
        r = _sp.run([ZISH, "-c", "session kill 1"], env=env,
                    capture_output=True, text=True, timeout=10)
        assert r.returncode == 0, f"remote kill failed: rc={r.returncode} err={r.stderr!r}"
        expect_soon(small, "ended")
        # meta and ctl FIFO are gone: nothing left for another process to see
        r2 = _sp.run([ZISH, "-c", "session list"], env=env,
                     capture_output=True, text=True, timeout=10)
        assert "pester" not in clean(r2.stdout), \
            f"killed session still in registry: {clean(r2.stdout)!r}"
        left = [f for f in os.listdir(os.path.join(small.home, ".zish", "sessions"))
                if f.endswith(".ctl") or f.endswith(".meta")]
        assert not left, f"control/meta files not cleaned up: {left}"
    finally:
        small.close()
        shutil.rmtree(featroot, ignore_errors=True)


# ---------------------------------------------------------------------------
total = passed + failed
print()
if failed == 0:
    print(f"\033[32mALL GREEN\033[0m — {passed} passed" + (f", {skipped} skipped" if skipped else ""))
    sys.exit(0)
print(f"\033[31mRED\033[0m — {failed}/{total} failed")
for f in failures:
    print(f"  \033[31m· {f}\033[0m")
sys.exit(1)
