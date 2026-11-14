#!/usr/bin/python3
"""Saved-cell preview with a private tmux document owner, not a one-shot alt grid.

Use a private iTerm profile with Scrollback in Alternate Screen off; tmux owns document history.
Run check-build.py with --scrollable-preview: mouse reporting and wheel on, alternate arrows off.
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
import tempfile
import termios
import time
import tty


def require(condition, message):
    if not condition:
        raise ValueError(message)


def cells(row):
    # Same BMP/cell-run bound as the retained saved-row replay.
    text = row.get("text", "")
    require(all(ord(c) <= 0xffff for c in text), "BMP fixture required")
    result, offset = [], 0
    for run in row.get("code_points_per_cell", []):
        count = run["num_code_points"]
        require(isinstance(count, int) and count > 0, "nonempty source cells required")
        for _ in range(run["repeats"]):
            result.append(text[offset:offset + count])
            offset += count
    styles = [dict(run, repeats=1) for run in row.get("style", []) for _ in range(run["repeats"])]
    require(offset == len(text) and len(styles) == len(result), "cell/style runs differ")
    return list(zip(result, styles))


def sgr(style):
    allowed = {"fgStandard", "fgAlternate", "bgStandard", "bgAlternate", "bold", "faint",
               "italic", "blink", "underline", "strikethrough", "invisible", "inverse",
               "guarded", "image", "repeats"}
    require(set(style) <= allowed, "unsupported style field")
    require(not any(style.get(k) for k in ("guarded", "image", "blink", "strikethrough", "invisible")),
            "unsupported presentation")
    codes = [0]
    for prefix, default, indexed in [("fg", 39, 38), ("bg", 49, 48)]:
        if prefix + "Standard" in style:
            value = style[prefix + "Standard"]
            require(type(value) is int and 0 <= value <= 255, "invalid palette entry")
            codes.extend([indexed, 5, value])
        else:
            alternate = style.get(prefix + "Alternate")
            require(alternate == 0 or (alternate == 3 and style.get("inverse")), "unsupported alternate color")
            codes.append(default)
    codes.extend(code for key, code in [("bold", 1), ("faint", 2), ("italic", 3), ("underline", 4), ("inverse", 7)] if style.get(key))
    return ("\x1b[" + ";".join(map(str, codes)) + "m").encode()


def document(fixture):
    wire, lines = bytearray(), []
    for index, row in enumerate(fixture["rows"]):
        require(row["continuation"] == 1, "saved HARD rows required")
        if index:
            wire.extend(b"\x1b[0m\r\n")
        line = []
        for cell, style in cells(row):
            # A linear terminal stream needs real spaces, not cursor moves which clamp at the edge.
            value = " " if cell == "\0" else cell
            require(value and all(ord(c) >= 32 and ord(c) != 127 for c in value), "control character in fixture")
            wire.extend(sgr(style))
            wire.extend(value.encode())
            line.append(value)
        lines.append("".join(line).rstrip(" "))
    wire.extend(b"\x1b[0m\x1b[?25l")
    return bytes(wire), lines


def load(args):
    raw = args.fixture.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == args.fixture_sha256, "fixture digest differs")
    fixture = json.loads(raw)
    require(1 <= args.expected_rows <= 1000, "expected row count outside document bound")
    require(fixture["originalGrid"] == [212, 53] and len(fixture["rows"]) == args.expected_rows,
            "fixture differs from explicitly expected row count")
    return raw, document(fixture)


def tmux(args, *command):
    return ["/opt/homebrew/bin/tmux", "-u", "-L", args.socket, "-f", str(args.runtime / "tmux.conf"), *command]


def emit(args):
    _, (wire, expected) = load(args)
    require(os.isatty(0) and os.isatty(1), "owned tmux pane required")
    socket = pathlib.Path(os.environ.get("TMUX", "").split(",")[0])
    require(socket.name == args.socket and socket.stat().st_uid == os.getuid(), "wrong tmux owner")
    old = termios.tcgetattr(0)
    try:
        tty.setraw(0)
        sys.stdout.buffer.write(wire)
        sys.stdout.buffer.flush()
        # Read actual primary/history output before switching to copy mode. No reinjection or sleeps.
        deadline = time.monotonic() + 10
        while True:
            captured = subprocess.check_output(tmux(args, "capture-pane", "-p", "-J", "-S", "-", "-t", "document:0.0"), text=True)
            actual = [line.rstrip(" ") for line in captured.splitlines()]
            if actual[:len(expected)] == expected and not any(actual[len(expected):]):
                break
            require(time.monotonic() < deadline, "document source did not settle")
        subprocess.run(tmux(args, "copy-mode", "-t", "document:0.0"), check=True)
        subprocess.run(tmux(args, "send-keys", "-t", "document:0.0", "-X", "history-top"), check=True)
        (args.runtime / "ready.json").write_text(json.dumps({
            "fixtureSha256": args.fixture_sha256, "logicalRows": len(expected),
            "normalizedUnicodeSha256": hashlib.sha256("\n".join(expected).encode()).hexdigest(),
            "socket": args.socket, "pane": "document:0.0", "sourceOwner": "tmux-primary-history",
            "normalization": "NUL cells become spaces; trailing spaces ignored for source readiness",
            "scope": "source ready only, scroll/resize/style/visual verification required"}, indent=2) + "\n")
        while True:
            # This is a read-only document, not a fake live Claude composer.
            if not os.read(0, 4096):
                return
    finally:
        termios.tcsetattr(0, termios.TCSANOW, old)


def launch(args):
    require(sys.platform == "darwin" and os.environ.get("ITERM2_LAYOUT_LAB_LAUNCH") == "1",
            "launch requires macOS and explicit ITERM2_LAYOUT_LAB_LAUNCH=1")
    require(not os.environ.get("TMUX"), "do not nest in a user tmux")
    root = args.runtime_root
    require(root is not None and root.is_absolute() and root.is_dir(), "explicit --runtime-root directory required")
    require(root.stat().st_uid == os.getuid() and root.stat().st_mode & 0o077 == 0,
            "runtime root must be owned by this user and private")
    require(args.runtime.is_absolute() and args.runtime.resolve() != root.resolve() and
            args.runtime.resolve().is_relative_to(root.resolve()), "runtime must be below the private root")
    require(not args.runtime.exists(), "fresh document runtime required")
    require(re.fullmatch(r"iterm2ml-document-[a-z0-9-]{1,36}", args.socket), "private socket name required")
    require(not (pathlib.Path("/tmp") / ("tmux-" + str(os.getuid())) / args.socket).exists(), "socket already exists")
    raw, _ = load(args)
    args.runtime.mkdir(mode=0o700)
    (args.runtime / "home").mkdir(mode=0o700)
    (args.runtime / "fixture.json").write_bytes(raw)
    script = args.runtime / "preview-document.py"
    script.write_bytes(pathlib.Path(__file__).read_bytes())
    (args.runtime / "tmux.conf").write_text("set -s set-clipboard off\nset -g mouse on\nset -g status off\n"
        "set -g history-limit 1000\nset -g destroy-unattached on\n"
        "bind -T copy-mode WheelUpPane send-keys -X -N 5 cursor-up\n"
        "bind -T copy-mode WheelDownPane send-keys -X -N 5 cursor-down\n")
    child = [sys.executable, "-I", "-S", str(script), "--emit", "--fixture", str(args.runtime / "fixture.json"),
             "--fixture-sha256", args.fixture_sha256, "--expected-rows", str(args.expected_rows),
             "--runtime", str(args.runtime), "--socket", args.socket]
    env = {"HOME": str(args.runtime / "home"), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/bash",
           "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TERM": "xterm-256color"}
    os.execve("/opt/homebrew/bin/tmux", tmux(args, "new-session", "-s", "document", "-n", "saved-corpus", shlex.join(child)), env)


def self_test():
    row = {"text": "കേ\0X", "continuation": 1,
           "code_points_per_cell": [{"num_code_points": 2, "repeats": 1}, {"num_code_points": 1, "repeats": 2}],
           "style": [{"fgAlternate": 0, "bgStandard": 237, "bold": True, "repeats": 3}]}
    wire, lines = document({"rows": [row, {"continuation": 1}]})
    assert lines == ["കേ X", ""] and wire.count(b"\r\n") == 1
    assert b"\x1b[?1049" not in wire and b"H" not in wire and b"48;5;237;1m" in wire
    faint = {"fgAlternate": 0, "bgAlternate": 0, "faint": True}
    assert sgr(faint) == b"\x1b[0;39;49;2m"
    assert sgr(dict(faint, faint=False)) == b"\x1b[0;39;49m"
    with tempfile.TemporaryDirectory(prefix="iterm2ml-document-codec-") as temporary:
        path = pathlib.Path(temporary) / "fixture.json"
        raw = json.dumps({"originalGrid": [212, 53], "rows": [row] * 135}).encode()
        path.write_bytes(raw)
        args = argparse.Namespace(fixture=path, fixture_sha256=hashlib.sha256(raw).hexdigest(), expected_rows=135)
        assert len(load(args)[1][1]) == 135
        for count in (53, 0, 1001):
            args.expected_rows = count
            try:
                load(args)
            except ValueError:
                pass
            else:
                raise AssertionError("wrong document bound accepted")
        raw = json.dumps({"originalGrid": [212, 53], "rows": [row] * 53}).encode()
        path.write_bytes(raw)
        args.fixture_sha256 = hashlib.sha256(raw).hexdigest()
        args.expected_rows = 53
        assert len(load(args)[1][1]) == 53
    for bad in [dict(row, text="\x1b" + row["text"][1:]), dict(row, continuation=2)]:
        try:
            document({"rows": [bad]})
        except ValueError:
            pass
        else:
            raise AssertionError("invalid document accepted")
    print("PASS linear saved-document codec, styles, control rejection, no alternate-grid replay")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--emit", action="store_true")
    parser.add_argument("--fixture", type=pathlib.Path)
    parser.add_argument("--fixture-sha256")
    parser.add_argument("--expected-rows", type=int, default=53,
                        help="explicit fixture row count (default: the original 53-row preview)")
    parser.add_argument("--runtime", type=pathlib.Path)
    parser.add_argument("--runtime-root", type=pathlib.Path, help="private parent directory for a fresh preview runtime")
    parser.add_argument("--socket")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    require(all(getattr(args, key) is not None for key in ("fixture", "fixture_sha256", "runtime", "socket")), "document binding required")
    if args.emit:
        emit(args)
    else:
        launch(args)


if __name__ == "__main__":
    main()
