#!/usr/bin/python3
"""Bind an experimental app to approved receipts, not rerun or certify native tests.

Checks receipted main binary layout, production inputs and private launch settings.
This is not whole-bundle integrity or fresh live-behavior proof. No receipt is executed.
"""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import pwd
import re
import subprocess
import sys
import tempfile


class GuardError(Exception):
    pass


def digest(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise GuardError(message)


def approved_json(path, expected):
    require(digest(path) == expected, "approved receipt digest differs: " + path.name)
    return json.loads(path.read_text())


def verify(args, write_stamp=True):
    build = approved_json(args.build_receipt, args.build_receipt_sha256)
    tests = approved_json(args.test_receipt, args.test_receipt_sha256)
    manifest_hash = digest(args.source_manifest)
    require(build["buildExit"] == 0 and build["buildSucceeded"] and build["normalNotASan"], "normal build receipt required")
    require(tests["buildExit"] == tests["testExit"] == tests["failures"] == 0 and tests["methods"] > 0,
            "passing native-test receipt required")
    require(build["commit"] == tests["commit"], "build/test source identities differ")
    require(build["manifestSha256"] == tests["manifestSha256"] == manifest_hash, "source manifest binding differs")
    app = args.app.resolve()
    require(not args.app.is_symlink() and app.name == "iTerm2.app" and
            app.parent.parent.name == "app-snapshots" and "Products" not in app.parts and
            app.parent.name.startswith(build["commit"][:12]), "use a commit-named immutable app copy, not Products")
    for directory, dirs, files in os.walk(app, followlinks=False):
        for name in dirs + files:
            path = pathlib.Path(directory) / name
            require(path.resolve().is_relative_to(app), "app symlink escapes its snapshot")
    binary = app / "Contents/MacOS/iTerm2"
    dylib = binary.with_name("iTerm2.debug.dylib")
    require(binary.is_file() and not binary.is_symlink() and os.access(binary, os.X_OK), "main app binary must be a regular executable")
    # Older approved receipts predate binaryLayout and always bind the debug dylib.
    layout = build.get("binaryLayout", "debug-dylib")
    require(layout in ("debug-dylib", "monolithic"), "unsupported binary layout")
    binaries = {"iTerm2": digest(binary)}
    if layout == "debug-dylib":
        require(dylib.is_file() and not dylib.is_symlink(), "receipted debug dylib missing or symlinked")
        binaries["iTerm2.debug.dylib"] = digest(dylib)
        require(binaries["iTerm2.debug.dylib"] == build["debugDylibSha256"], "debug dylib hash differs")
    else:
        require(build.get("debugDylibSha256") is None and not dylib.exists() and not dylib.is_symlink(),
                "monolithic receipt requires no debug dylib")
    require(binaries["iTerm2"] == build["executableSha256"], "main executable hash differs")
    inventory = build.get("binaries")
    require(layout != "monolithic" or inventory is not None, "monolithic binary inventory required")
    if inventory is not None:
        require(set(inventory) == set(binaries) and all(inventory[name]["sha256"] == sha for name, sha in binaries.items()),
                "receipt binary inventory differs")
    entries = json.loads(args.source_manifest.read_text())
    seen = set()
    production = {}
    for entry in entries:
        relative = pathlib.PurePosixPath(entry["path"])
        require(not relative.is_absolute() and ".." not in relative.parts and str(relative) not in seen, "invalid manifest path")
        seen.add(str(relative))
        if str(relative) == "ModernTests/SessionViewTests.swift":
            continue  # Test-only/guard-only commits do not reattribute an unchanged app.
        path = args.source / relative
        require(path.resolve().is_relative_to(args.source.resolve()), "source path escapes checkout")
        require(digest(path) == entry["sha256"], "production input differs: " + str(relative))
        production[str(relative)] = entry["sha256"]
    require(production and "ModernTests/SessionViewTests.swift" in seen, "production/test manifest required")
    require(re.fullmatch(r"iterm2-ml-[a-z0-9-]+", args.suite) and args.profile.name == args.suite + ".plist", "private suite/profile required")
    prefs = plistlib.loads(args.profile.read_bytes())
    profiles = [p for p in prefs["New Bookmarks"] if p["Guid"] == prefs["Default Bookmark Guid"]]
    require(len(profiles) == 1, "one default experimental profile required")
    profile = profiles[0]
    settings = {key: profile.get(key) for key in ["Normal Font", "Non Ascii Font", "Use Non-ASCII Font", "ASCII Anti Aliased", "Non-ASCII Anti Aliased"]}
    if args.scrollable_preview:
        for key, expected in {"Mouse Reporting": True, "Mouse Reporting allow mouse wheel": True,
                              "Scrollback in Alternate Screen": False, "Allow Alternate Mouse Scroll": False,
                              "Automatically Enable Alternate Mouse Scroll": False}.items():
            require(profile.get(key) is expected, "scrollable preview requires " + key + "=" + str(expected))
    require(args.font_size in (18, 20), "only explicitly approved font sizes 18 and 20 are supported")
    require(settings == {"Normal Font": f"Monaco {args.font_size}", "Non Ascii Font": f"NotoSansMalayalam-Regular {args.font_size}",
                        "Use Non-ASCII Font": True, "ASCII Anti Aliased": False, "Non-ASCII Anti Aliased": False}, "experimental font/settings differ")
    require(args.expected_paragraph_flow in ("off", "on"), "paragraph expectation must be off or on")
    paragraph_flow = args.expected_paragraph_flow == "on"
    require(prefs.get("MalayalamParagraphFlow", False) is paragraph_flow, "paragraph policy differs from explicit expectation")
    require(not paragraph_flow or prefs.get("MalayalamVisualWrap") is True, "paragraph policy requires visual wrapping")
    require(prefs.get("MalayalamCellStrip") is True, "development preview must explicitly enable the logical-cell ruler")
    require(prefs.get("MalayalamNaturalRows") is True and prefs.get("SUEnableAutomaticChecks") is False and
            prefs.get("SUAutomaticallyUpdate") is False, "restart-only mode/updater contract differs")
    require(digest(args.font) == args.font_sha256, "font file hash differs")
    require(not args.stamp.resolve().is_relative_to(app), "stamp cannot modify immutable app")
    binding = {"buildSourceCommit": build["commit"], "app": str(app), "suite": args.suite,
        "production": production, "buildReceipt": args.build_receipt_sha256, "testReceipt": args.test_receipt_sha256,
        "manifest": manifest_hash, "settings": settings, "profile": digest(args.profile), "font": args.font_sha256,
        "binaryLayout": layout, "binaries": binaries, "fontSize": args.font_size, "paragraphFlowExpected": paragraph_flow, "scrollablePreview": args.scrollable_preview,
        "guard": digest(__file__), "launcher": digest(pathlib.Path(__file__).with_name("launch-patched.sh"))}
    fingerprint = hashlib.sha256(json.dumps(binding, sort_keys=True).encode()).hexdigest()
    if args.stamp.exists() and json.loads(args.stamp.read_text()).get("fingerprint") == fingerprint:
        return False
    if not write_stamp:
        return True
    args.stamp.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.stamp.with_suffix(".tmp")
    temporary.write_text(json.dumps({"fingerprint": fingerprint, "buildSourceCommit": build["commit"],
        "proof": "approved receipt and launch-contract binding only, native tests not rerun"}, indent=2) + "\n")
    os.replace(temporary, args.stamp)
    return True


def ensure_launchable(args):
    patterns = ["^" + re.escape(str(args.app.resolve() / "Contents/MacOS/iTerm2")) + r"( |$)",
                r"/iTerm2\.app/Contents/MacOS/iTerm2 .*-suite " + re.escape(args.suite) + r"( |$)"]
    for pattern in patterns:
        status = subprocess.run(["/usr/bin/pgrep", "-f", pattern], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
        require(status in (0, 1), "process detector failed (exit " + str(status) + ")")
        require(status == 1, "live executable path or suite, use a distinct immutable copy and fresh suite")


def launch_environment():
    account = pwd.getpwuid(os.getuid())
    return {"HOME": account.pw_dir, "USER": account.pw_name, "LOGNAME": account.pw_name,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "SHELL": "/bin/bash"}


def prepare_suite(args, command=("/usr/bin/defaults",)):
    expected = plistlib.loads(args.profile.read_bytes())
    imported = subprocess.run([*command, "import", args.suite, str(args.profile)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=launch_environment())
    require(imported.returncode == 0, "private profile import failed")
    exported = subprocess.run([*command, "export", args.suite, "-"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=launch_environment())
    require(exported.returncode == 0 and plistlib.loads(exported.stdout) == expected,
            "private suite readback differs from checked profile")


def self_test():
    with tempfile.TemporaryDirectory(prefix="iterm2-ml-guard-") as temporary:
        root = pathlib.Path(temporary).resolve()
        commit = "1" * 40
        app = root / "app-snapshots" / commit[:12] / "iTerm2.app"
        binary = app / "Contents/MacOS/iTerm2"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"synthetic executable, never executed")
        binary.chmod(0o700)
        dylib = binary.with_name("iTerm2.debug.dylib")
        dylib.write_bytes(b"synthetic debug dylib")
        source = root / "source"
        (source / "sources").mkdir(parents=True)
        (source / "ModernTests").mkdir()
        (source / "sources/example.swift").write_text("first-party fixture")
        (source / "ModernTests/SessionViewTests.swift").write_text("test fixture")
        manifest = root / "source-manifest.json"
        manifest.write_text(json.dumps([{"path": name, "sha256": digest(source / name)} for name in
            ["sources/example.swift", "ModernTests/SessionViewTests.swift"]]))
        build = root / "build.json"
        build.write_text(json.dumps({"commit": commit, "buildExit": 0, "buildSucceeded": True,
            "manifestSha256": digest(manifest), "executableSha256": digest(binary),
            "debugDylibSha256": digest(dylib), "normalNotASan": "approved normal receipt",
            "snapshot": {"path": str(app)}}))
        tests = root / "tests.json"
        tests.write_text(json.dumps({"commit": commit, "buildExit": 0, "testExit": 0,
            "failures": 0, "methods": 13, "manifestSha256": digest(manifest)}))
        suite = "iterm2-ml-guard-fixture"
        profile = root / (suite + ".plist")
        profile.write_bytes(plistlib.dumps({"MalayalamNaturalRows": True, "MalayalamCellStrip": True,
            "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False,
            "New Bookmarks": [{"Guid": "fixture", "Normal Font": "Monaco 20",
                "Non Ascii Font": "NotoSansMalayalam-Regular 20", "Use Non-ASCII Font": True,
                "ASCII Anti Aliased": False, "Non-ASCII Anti Aliased": False}],
            "Default Bookmark Guid": "fixture"}))
        font = root / "font.ttf"
        font.write_bytes(b"synthetic font bytes")
        args = argparse.Namespace(app=app, source=source, source_manifest=manifest,
            build_receipt=build, build_receipt_sha256=digest(build), test_receipt=tests,
            test_receipt_sha256=digest(tests), profile=profile, suite=suite,
            font=font, font_sha256=digest(font), stamp=root / "stamp.json",
            font_size=20, expected_paragraph_flow="off", scrollable_preview=False)
        assert verify(args) and not verify(args), "unchanged binding must be quiet"
        stamp = args.stamp.read_bytes()

        def rejected(label, change, restore):
            change()
            try:
                try:
                    verify(args)
                except GuardError:
                    pass
                else:
                    raise AssertionError(label + " was accepted")
                assert args.stamp.read_bytes() == stamp, "failure must not stamp"
            finally:
                restore()
            assert not verify(args), "restored original must remain unchanged"
            print("PASS " + label)

        for label, path in [("changed executable", binary), ("changed dylib", dylib),
                            ("changed source", source / "sources/example.swift"), ("changed font", font)]:
            original = path.read_bytes()
            rejected(label, lambda: path.write_bytes(b"changed"), lambda: path.write_bytes(original))
        rejected("non-executable main", lambda: binary.chmod(0o600), lambda: binary.chmod(0o700))
        original = tests.read_bytes()
        sentinel = root / "must-not-execute"
        rejected("unapproved success JSON", lambda: tests.write_text(json.dumps({"success": True,
            "argv": ["/usr/bin/touch", str(sentinel)]})), lambda: tests.write_bytes(original))
        assert not sentinel.exists(), "receipts must never be executed"
        original = profile.read_bytes()
        bad_profile = plistlib.loads(original)
        bad_profile["New Bookmarks"][0]["Normal Font"] = "Monaco 12"
        rejected("wrong font setting", lambda: profile.write_bytes(plistlib.dumps(bad_profile)), lambda: profile.write_bytes(original))
        suite = args.suite
        rejected("daily suite", lambda: setattr(args, "suite", "com.googlecode.iterm2"), lambda: setattr(args, "suite", suite))
        link = app / "escape"
        rejected("escaping app symlink", lambda: link.symlink_to(root), lambda: link.unlink())
        item = source / "sources/example.swift"
        outside = root / "outside.swift"
        outside.write_bytes(item.read_bytes())
        original = item.read_bytes()
        def escape_source():
            item.unlink()
            item.symlink_to(outside)
        def restore_source():
            item.unlink()
            item.write_bytes(original)
        rejected("escaping source symlink", escape_source, restore_source)
        actual_app = args.app
        rejected("Products path", lambda: setattr(args, "app", root / "Products/iTerm2.app"), lambda: setattr(args, "app", actual_app))
        ensure_launchable(args)
        for executable, tail in [(binary, []), (root / "other/iTerm2.app/Contents/MacOS/iTerm2", ["-suite", args.suite])]:
            # The system shell preserves argv0; the macOS Python launcher replaces it.
            child = subprocess.Popen([str(executable), "--noprofile", "--norc", "-c",
                "printf 'READY\\n'; IFS= read -r line", *tail],
                executable="/bin/bash", stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=launch_environment())
            try:
                assert child.stdout.readline() == b"READY\n"
                try:
                    ensure_launchable(args)
                except GuardError:
                    pass
                else:
                    raise AssertionError("live executable or suite accepted")
            finally:
                child.stdin.close()
                child.wait()
            ensure_launchable(args)
            print("PASS live executable/suite refusal")
        fake_defaults = root / "defaults.py"
        actual_prefs = root / "actual-suite.plist"
        actual_prefs.write_bytes(plistlib.dumps({"wrong": True}))
        fake_defaults.write_text("import os,pathlib,sys\n"
            "if os.environ.get('CFFIXED_USER_HOME'): sys.exit('inherited preference-home override')\n"
            "stored=pathlib.Path(__file__).with_name('actual-suite.plist')\n"
            "if sys.argv[1]=='import': stored.write_bytes(pathlib.Path(sys.argv[3]).read_bytes())\n"
            "elif sys.argv[1]=='export': sys.stdout.buffer.write(stored.read_bytes())\n")
        previous_home = os.environ.get("CFFIXED_USER_HOME")
        os.environ["CFFIXED_USER_HOME"] = "/unrelated-preference-home"
        try:
            prepare_suite(args, (sys.executable, "-I", "-S", str(fake_defaults)))
        finally:
            if previous_home is None:
                os.environ.pop("CFFIXED_USER_HOME", None)
            else:
                os.environ["CFFIXED_USER_HOME"] = previous_home
        assert plistlib.loads(actual_prefs.read_bytes()) == plistlib.loads(profile.read_bytes()), "launcher did not import checked profile"
        print("PASS checked profile imported and read back")
        original = profile.read_bytes()
        changed = plistlib.loads(original)
        changed["New Bookmarks"][0]["Command"] = "nonexecuted fixture command"
        profile.write_bytes(plistlib.dumps(changed))
        assert verify(args) and not verify(args), "full profile changes must invalidate stamp"
        profile.write_bytes(original)
        assert verify(args) and args.stamp.read_bytes() == stamp
        assert not sentinel.exists()
        # The observed bad preview had wheel enabled but its parent reporting gate off.
        preview = plistlib.loads(original)
        preview["New Bookmarks"][0].update({"Mouse Reporting": True, "Mouse Reporting allow mouse wheel": True,
            "Scrollback in Alternate Screen": False, "Allow Alternate Mouse Scroll": False,
            "Automatically Enable Alternate Mouse Scroll": False})
        profile.write_bytes(plistlib.dumps(preview))
        args.scrollable_preview = True
        assert verify(args) and not verify(args)
        stamp = args.stamp.read_bytes()
        for key in ("Mouse Reporting", "Mouse Reporting allow mouse wheel", "Scrollback in Alternate Screen",
                    "Allow Alternate Mouse Scroll", "Automatically Enable Alternate Mouse Scroll"):
            bad = plistlib.loads(profile.read_bytes())
            bad["New Bookmarks"][0][key] = not bad["New Bookmarks"][0][key]
            correct = profile.read_bytes()
            rejected("scrollable preview gate " + key, lambda: profile.write_bytes(plistlib.dumps(bad)),
                     lambda: profile.write_bytes(correct))
        assert verify(args) is False
        args.scrollable_preview = False
        assert verify(args), "preview expectation must be fingerprinted"
        profile.write_bytes(original)
        assert verify(args)
        stamp = args.stamp.read_bytes()
        # Exercise every binary-layout/font/policy combination, not only the historical debug/20/off path.
        for layout in ("debug-dylib", "monolithic"):
            for size in (18, 20):
                for policy in ("off", "on"):
                    if layout == "debug-dylib":
                        dylib.write_bytes(b"synthetic debug dylib")
                    elif dylib.exists():
                        dylib.unlink()
                    receipt = json.loads(build.read_text())
                    inventory = {"iTerm2": {"sha256": digest(binary)}}
                    if dylib.exists():
                        inventory["iTerm2.debug.dylib"] = {"sha256": digest(dylib)}
                    receipt.update(binaryLayout=layout, debugDylibSha256=digest(dylib) if dylib.exists() else None,
                                   binaries=inventory)
                    build.write_text(json.dumps(receipt))
                    args.build_receipt_sha256 = digest(build)
                    prefs = plistlib.loads(original)
                    prefs["New Bookmarks"][0].update({"Normal Font": f"Monaco {size}",
                        "Non Ascii Font": f"NotoSansMalayalam-Regular {size}"})
                    prefs.update(MalayalamParagraphFlow=policy == "on", MalayalamVisualWrap=True)
                    profile.write_bytes(plistlib.dumps(prefs))
                    args.font_size, args.expected_paragraph_flow = size, policy
                    assert verify(args) and not verify(args), "new approved binding must stamp once"
                    stamp = args.stamp.read_bytes()
                    rejected("font expectation mismatch", lambda: setattr(args, "font_size", 20 if size == 18 else 18),
                             lambda: setattr(args, "font_size", size))
                    rejected("paragraph expectation mismatch", lambda: setattr(args, "expected_paragraph_flow", "on" if policy == "off" else "off"),
                             lambda: setattr(args, "expected_paragraph_flow", policy))
                    source_bytes = item.read_bytes()
                    rejected("changed source in " + layout, lambda: item.write_bytes(b"changed"), lambda: item.write_bytes(source_bytes))
                    if layout == "monolithic":
                        rejected("unexpected debug dylib", lambda: dylib.write_bytes(b"unexpected"), lambda: dylib.unlink())
                    else:
                        dylib_bytes = dylib.read_bytes()
                        rejected("missing debug dylib", lambda: dylib.unlink(), lambda: dylib.write_bytes(dylib_bytes))
                    print(f"PASS {layout}/{size}/paragraph-{policy}")
    print("PASS guard fixtures")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--launch", action="store_true")
    parser.add_argument("--scrollable-preview", action="store_true",
                        help="require native wheel reporting and tmux-owned history before launch")
    parser.add_argument("--font-size", type=int, choices=(18, 20), default=20)
    parser.add_argument("--expected-paragraph-flow", choices=("off", "on"), default="off")
    for name in ["app", "source", "source-manifest", "build-receipt", "test-receipt", "profile", "font", "stamp"]:
        parser.add_argument("--" + name, type=pathlib.Path)
    for name in ["suite", "build-receipt-sha256", "test-receipt-sha256", "font-sha256"]:
        parser.add_argument("--" + name)
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if any(value is None for name, value in vars(args).items() if name not in ["self_test", "launch"]):
        parser.error("all binding arguments are required")
    if args.launch:
        require(sys.platform == "darwin" and os.environ.get("ITERM2_LAYOUT_LAB_LAUNCH") == "1",
                "launch requires macOS and explicit ITERM2_LAYOUT_LAB_LAUNCH=1")
        ensure_launchable(args)
        verify(args, write_stamp=False)
        prepare_suite(args)
    if verify(args):
        print("Build guard: approved source/build/test receipts and private launch contract bound; native tests not rerun.", flush=True)
    if args.launch:
        binary = args.app.resolve() / "Contents/MacOS/iTerm2"
        os.execve(str(binary), [str(binary), "-suite", args.suite, "-MalayalamNaturalRows", "YES",
                  "-SUEnableAutomaticChecks", "NO", "-SUAutomaticallyUpdate", "NO"], launch_environment())


if __name__ == "__main__":
    try:
        main()
    except (GuardError, OSError, ValueError, KeyError, TypeError) as error:
        print("Build guard: " + str(error), file=sys.stderr)
        sys.exit(1)
