#!/usr/bin/env python3
"""Measure synthetic text in an isolated tmux server, without a startup shell."""
import json
import hashlib
from pathlib import Path
import re
import subprocess
import sys
import uuid

LAB = Path(__file__).resolve().parent
ROOT = LAB.parent.parent
BUILD = ROOT / "context/experiments/layout-lab"
TMUX = "/opt/homebrew/bin/tmux"
ENV = {"HOME": str(Path.home()), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
       "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"}
MARKER = b"|END|"
CLEAR = b"\x1b[2J\x1b[H"


def tmux_prefix(socket):
    if not re.fullmatch(r"iterm2ml-probe-[0-9a-f]{32}", socket):
        raise ValueError("Only a generated private probe socket is allowed")
    return [TMUX, "-u", "-L", socket, "-f", "/dev/null"]


def validate(text):
    if (not isinstance(text, str) or not text or len(text) > 100 or
            MARKER.decode() in text or any(ord(c) < 32 or ord(c) == 127 for c in text)):
        raise ValueError("Only bounded synthetic single-line text is allowed")


def emit(text, socket=None, channel=None):
    validate(text)
    if socket is None:
        sys.stdout.buffer.write(CLEAR + text.encode() + MARKER)
    else:
        prefix = tmux_prefix(socket)
        if not re.fullmatch(r"iterm2ml-scalar-[0-9]+", channel or ""):
            raise ValueError("Only a generated private scalar channel is allowed")

        def wait_for_lock():
            subprocess.run([*prefix, "wait-for", "-L", channel], cwd=ROOT, env=ENV,
                           stdin=subprocess.DEVNULL, capture_output=True, check=True)

        wait_for_lock()  # Held before output, so a late next waiter cannot lose the handoff.
        sys.stdout.buffer.write(CLEAR)
        for scalar in text:
            sys.stdout.buffer.write(scalar.encode())
            sys.stdout.buffer.flush()
            wait_for_lock()
        sys.stdout.buffer.write(MARKER)
    sys.stdout.buffer.flush()
    sys.stdin.buffer.read(1)  # Keep this owned pane alive for its grid capture.


def read_case_output(controller, log, command, expected_pane, text, channel):
    observed = {}
    snapshots = []
    expected = CLEAR + text.encode() + MARKER
    while True:
        line = controller.stdout.readline()
        log.write(line)
        log.flush()
        if not line or line.startswith(b"%exit"):
            raise RuntimeError("Control client exited before the synthetic end marker")
        if line.startswith((b"%window-close ", b"%error ")):
            raise RuntimeError("Owned pane or control command failed before the end marker")
        if not line.startswith(b"%output "):
            continue
        _, pane, value = line.rstrip(b"\n").split(b" ", 2)
        if expected_pane is not None and pane != expected_pane:
            continue
        decoded = re.sub(rb"\\([0-7]{3})", lambda m: bytes([int(m[1], 8)]), value)
        observed[pane] = observed.get(pane, b"") + decoded
        current = observed[pane]
        if not expected.startswith(current):
            raise RuntimeError("Unexpected probe output before the end marker")
        if channel and len(snapshots) < len(text):
            prefix_text = text[:len(snapshots) + 1]
            prefix_bytes = CLEAR + prefix_text.encode()
            if current.startswith(prefix_bytes):
                if current != prefix_bytes:
                    raise RuntimeError("Scalar output advanced before prefix acknowledgement")
                target = pane.decode("ascii")
                cursor = list(map(int, command("display-message", "-p", "-t", target,
                                               "#{cursor_x},#{cursor_y}").stdout.split(b",")))
                capture = command("capture-pane", "-p", "-t", target, "-S", "0", "-E", "0").stdout.rstrip(b"\n")
                if text == "ABC" and cursor != [len(prefix_text), 0]:
                    raise RuntimeError("ASCII scalar prefix cursor does not match its acknowledged source")
                snapshots.append({"scalarCount": len(prefix_text), "sourcePrefix": prefix_text,
                                  "cursor": cursor, "capture": capture.decode("utf-8"),
                                  "capturePreservesPrefixBytes": capture == prefix_text.encode()})
                command("wait-for", "-U", channel)
        if MARKER in current:
            if channel and len(snapshots) != len(text):
                raise RuntimeError("End marker arrived before every scalar prefix was observed")
            return pane, snapshots


def copy_column_selections(command, target, text, columns):
    # Only the unique probe server's internal buffers, never the system clipboard.
    command("set-option", "-s", "set-clipboard", "off")
    if command("show-options", "-s", "-v", "set-clipboard").stdout.strip() != b"off":
        raise RuntimeError("Private-server clipboard integration must be off")
    command("set-window-option", "-t", target, "mode-keys", "vi")
    cells = []
    selections = []
    for column in range(columns):
        command("copy-mode", "-t", target)
        command("send-keys", "-t", target, "-X", "start-of-line")
        if column:
            command("send-keys", "-t", target, "-N", str(column), "-X", "cursor-right")
        command("send-keys", "-t", target, "-X", "begin-selection")
        coordinates = command("display-message", "-p", "-t", target,
                              "#{copy_cursor_x},#{copy_cursor_y};#{selection_start_x},#{selection_start_y};#{selection_end_x},#{selection_end_y}").stdout.decode().strip()
        cursor, start, end = [list(map(int, pair.split(","))) for pair in coordinates.split(";")]
        selections.append({"requestedColumn": column, "cursor": cursor,
                           "selectionStart": start, "selectionEnd": end})
        if any(point != [column, 0] for point in [cursor, start, end]):
            raise RuntimeError("Copy selection did not reach the requested single grid column: " + coordinates)
        command("send-keys", "-t", target, "-X", "copy-selection-and-cancel")
        cells.append(command("save-buffer", "-").stdout.decode("utf-8"))
        command("delete-buffer")
    if "".join(cells).encode() != text.encode():
        raise RuntimeError("Selected tmux cells do not reconstruct the exact input")
    if text == "ABC" and cells != ["A", "B", "C"]:
        raise RuntimeError("Single-column selection failed the ASCII control")
    if text == "e\u0301" and cells != ["e\u0301"]:
        raise RuntimeError("Single-column combining selection changed its source")
    return cells, selections


def measure(include_cells=False, scalar_chunks=False):
    fixtures = json.loads((BUILD / "cell-measurements.json").read_text())
    cases = [("ASCII control", "ABC", None)]
    if include_cells:
        cases.append(("Combining control", "e\u0301", None))
    cases += [(f"Cell fixture {i + 1}", "".join(f["cells"]), len(f["cells"]))
              for i, f in enumerate(fixtures)]
    for _, text, _ in cases:
        validate(text)  # Reject every fixture before any server or pane exists.
    mode = "tmux-cells" if include_cells else "tmux-width"
    if scalar_chunks:
        mode = "tmux-scalar-chunks"
    folder = BUILD / mode
    folder.mkdir(parents=True, exist_ok=True)
    socket = "iterm2ml-probe-" + uuid.uuid4().hex
    prefix = tmux_prefix(socket)

    def command(*args, check=True):
        return subprocess.run([*prefix, *args], env=ENV, cwd=ROOT,
                              capture_output=True, check=check)

    # Never attach to or stop a server which existed before this invocation.
    if command("has-session", check=False).returncode == 0:
        raise RuntimeError("Unexpected existing server at the unique probe address")
    controller = None
    results = []
    print(json.dumps({"ownedSocket": socket}), flush=True)
    with (folder / "control-output.log").open("wb") as log:
        try:
            for index, (name, text, source_cells) in enumerate(cases):
                channel = f"iterm2ml-scalar-{index}" if scalar_chunks else None
                arguments = ["--emit-scalar-chunks", socket, channel, text] if scalar_chunks else ["--emit", text]
                emitter = ["/usr/bin/python3", "-I", "-S", "-u", str(Path(__file__).resolve()), *arguments]
                expected_pane = None
                if index == 0:
                    controller = subprocess.Popen(
                        [*prefix, "-C", "new-session", "-s", "probe", "-x", "200", "-y", "10", *emitter],
                        cwd=ROOT, env=ENV, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT)
                else:
                    expected_pane = command("new-window", "-P", "-F", "#{pane_id}",
                                            "-t", "probe:", *emitter).stdout.strip()
                pane, snapshots = read_case_output(controller, log, command, expected_pane, text, channel)
                target = pane.decode("ascii")
                pane_width = int(command("display-message", "-p", "-t", target, "#{pane_width}").stdout)
                x, y = map(int, command("display-message", "-p", "-t", target,
                                        "#{cursor_x},#{cursor_y}").stdout.split(b","))
                capture = command("capture-pane", "-p", "-t", target, "-S", "0", "-E", "0").stdout.rstrip(b"\n")
                if y != 0 or not capture.endswith(MARKER) or x < len(MARKER):
                    raise RuntimeError("Probe wrapped or marker was not captured at the cursor")
                result = {"name": name, "input": text, "sourceDerivedCells": source_cells,
                          "tmuxColumns": x - len(MARKER), "cursorAfterMarker": [x, y],
                          "paneWidth": pane_width,
                          "capture": capture.decode("utf-8"),
                          "capturePreservesInputBytes": capture == text.encode() + MARKER}
                if include_cells:
                    cells, selections = copy_column_selections(command, target, text, result["tmuxColumns"])
                    result["selectionPieces"] = cells
                    result["copySelections"] = selections
                    result["partitionMethod"] = "Exact-coordinate one-column vi copy selections, not a memory dump"
                if scalar_chunks:
                    result["prefixObservations"] = snapshots
                results.append(result)
                print(json.dumps(result, ensure_ascii=False), flush=True)
                if index == 0 and (result["tmuxColumns"] != 3 or not result["capturePreservesInputBytes"]):
                    raise RuntimeError("ASCII control failed; no Malayalam width conclusion is valid")
            payload = {"tmuxVersion": command("-V").stdout.decode().strip(), "socket": socket,
                       "configuration": "/dev/null", "requestedWidth": 200, "locale": ENV["LC_ALL"], "inputMode": mode,
                       "sourceSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                       "fixtureSHA256": hashlib.sha256((BUILD / "cell-measurements.json").read_bytes()).hexdigest(),
                       "scope": "Private tmux parsing/grid only; no iTerm2 or Claude Code execution",
                       "cases": results}
            (folder / "measurements.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
        finally:
            if controller is not None:
                command("kill-server", check=False)  # This unique server only.
                controller.communicate()
                if command("has-session", check=False).returncode == 0:
                    raise RuntimeError("Owned probe server survived cleanup")


if __name__ == "__main__":
    if not sys.flags.isolated or not sys.flags.no_site:
        raise SystemExit("Launch explicitly with /usr/bin/python3 -I -S to disable startup customization")
    if len(sys.argv) == 3 and sys.argv[1] == "--emit":
        emit(sys.argv[2])
    elif len(sys.argv) == 5 and sys.argv[1] == "--emit-scalar-chunks":
        emit(sys.argv[4], socket=sys.argv[2], channel=sys.argv[3])
    elif len(sys.argv) == 1:
        measure()
    elif sys.argv[1:] == ["--cells"]:
        measure(include_cells=True)
    elif sys.argv[1:] == ["--scalar-chunks"]:
        measure(include_cells=True, scalar_chunks=True)
    else:
        raise SystemExit("Usage: tmux-width-probe.py [--cells | --scalar-chunks | --emit synthetic-text]")
