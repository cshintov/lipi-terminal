#!/usr/bin/python3
"""Offline Lipi export from committed source and explicit, pinned local dependencies."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import tarfile

IDENTITY = "io.github.cshintov.lipi-terminal"
NAME = "Lipi Terminal"
ICON = "LipiTerminal.icns"
UPSTREAM_APP_ICONS = ("iTerm2.icns", "AppIcon*", "iTerm2 App Icon for *.icon")
ROOT = Path(__file__).resolve().parents[1]
LOCK = "iTerm2.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"


def run(*args, cwd=None, env=None):
    return subprocess.check_output(args, cwd=cwd, env=env, stderr=subprocess.STDOUT)


def git(path, *args):
    return run("/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-C", str(path), *args)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def extract(repo, revision, dest):
    dest.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(git(repo, "archive", revision))) as archive:
        # The input is our committed local tree, not a downloaded archive.
        for member in archive.getmembers():
            if Path(member.name).is_absolute() or ".." in Path(member.name).parts:
                raise ValueError("Unsafe archive entry: " + member.name)
        archive.extractall(dest)


def public_plist(original):
    result = dict(original)
    for key in list(result):
        if key.startswith("SU") or key.startswith("CFBundleIcon"):
            del result[key]
    result.update(CFBundleIdentifier=IDENTITY, CFBundleName=NAME,
                  CFBundleDisplayName=NAME, CFBundleExecutable="iTerm2", CFBundleIconFile=ICON,
                  SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False,
                  SUEnableInstallerLauncherService=False, LipiPublicBuild=True)
    if "CFBundleDocumentTypes" in result:
        result["CFBundleDocumentTypes"] = [
            dict(item, CFBundleTypeIconFile=ICON) if item.get("CFBundleTypeIconFile") == "iTerm2.icns"
            else dict(item) for item in result["CFBundleDocumentTypes"]]
    return result


def install_public_icon(app, source_icon):
    resources = app / "Contents/Resources"
    # Preserve document icons and framework resources, replacing only the app artwork.
    for pattern in UPSTREAM_APP_ICONS:
        for path in resources.glob(pattern):
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink()
    shutil.copyfile(source_icon, resources / ICON)


def verify_public_icon(app, source_icon):
    plist = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert {key: value for key, value in plist.items() if key.startswith("CFBundleIcon")} == {
        "CFBundleIconFile": ICON}
    resources = app / "Contents/Resources"
    assert sha(resources / ICON) == sha(source_icon)
    assert not any(list(resources.glob(pattern)) for pattern in UPSTREAM_APP_ICONS)


def stage_source(output, dependencies):
    commit = git(ROOT, "rev-parse", "HEAD").decode().strip()
    if git(ROOT, "status", "--porcelain", "--untracked-files=no").strip():
        raise ValueError("Commit tracked changes before building; the export uses exact HEAD")
    source = output / "source"
    extract(ROOT, commit, source)
    for relative, supplied in dependencies.items():
        revision = git(ROOT, "ls-tree", commit, relative).decode().split()[2]
        repo = supplied or ROOT / relative
        if git(repo, "rev-parse", "HEAD").decode().strip() != revision:
            raise ValueError("Dependency is not at the pinned revision: " + relative)
        if git(repo, "status", "--porcelain", "--untracked-files=no").strip():
            raise ValueError("Dependency has tracked modifications: " + relative)
        extract(repo, revision, source / relative)
    shutil.copy2(source / "xcstrings/Localizable.xcstrings", source / "sources/Localizable.xcstrings")
    plist = public_plist(plistlib.loads((source / "plists/dev-iTerm2.plist").read_bytes()))
    version = (source / "version.txt").read_text().strip() % {"extra": "lipi." + commit[:12]}
    plist.update(CFBundleVersion=version, CFBundleShortVersionString=version,
                 CFBundleGetInfoString=version)
    (source / "plists/iTerm2.plist").write_bytes(plistlib.dumps(plist))
    # The public plist is already versioned. Avoid the upstream phase's machine-specific
    # Python/PyObjC requirement and the later channel-plist rewrite, in this copy only.
    project = source / "iTerm2.xcodeproj/project.pbxproj"
    text = project.read_text()
    lines = text.splitlines(keepends=True)
    replaced = 0
    for i, line in enumerate(lines):
        if "shellScript = " in line and ("exec tools/updateVersion.py" in line or
                                        "Update version" in line):
            lines[i] = '\t\t\tshellScript = "true";\n'
            replaced += 1
    if replaced != 2:
        raise ValueError("Upstream version build phases changed; review the public build")
    lines = [line for line in lines if not ("in Resources" in line and
             ("iTerm2 App Icon for " in line or "AppIcon.png" in line))]
    project.write_text("".join(lines))
    # Do not compile upstream app icon art into the public artifact.
    for icon in source.rglob("*.appiconset"):
        shutil.rmtree(icon)
    return commit, source


def stage_packages(cache, output, source):
    packages = output / "SourcePackages"
    if not (cache / "workspace-state.json").is_file():
        raise ValueError("Expected an existing Xcode SourcePackages cache")
    # Preserve package source symlinks, but never retain writable cache metadata links.
    for path in cache.rglob("*"):
        if not path.is_symlink():
            continue
        parts = path.relative_to(cache).parts
        if len(parts) < 3 or parts[0] != "checkouts" or ".git" in parts:
            raise ValueError("Cache metadata contains an external symlink: " + str(path))
    shutil.copytree(cache, packages, symlinks=True)
    pins = json.loads((source / LOCK).read_text())["pins"]
    checkouts = {p.name.lower(): p for p in (packages / "checkouts").iterdir()}
    for pin in pins:
        checkout = checkouts[pin["identity"].lower()]
        revision = pin["state"]["revision"]
        if not (checkout / ".git").is_dir():
            raise ValueError("Package must have producer-local Git metadata")
        top = Path(git(checkout, "rev-parse", "--show-toplevel").decode().strip()).resolve()
        if top != checkout.resolve():
            raise ValueError("Package Git metadata points outside its copied checkout")
        alternates = checkout / ".git/objects/info/alternates"
        if alternates.exists():
            # Use this producer's copied object store, never an original/global alternate.
            repositories = [p for p in (packages / "repositories").iterdir()
                            if p.name.lower().startswith(pin["identity"].lower() + "-")]
            matches = []
            for repo in repositories:
                try:
                    git(repo, "cat-file", "-e", revision + "^{commit}")
                    matches.append(repo)
                except subprocess.CalledProcessError:
                    pass
            if len(matches) != 1 or alternates.is_symlink():
                raise ValueError("Cannot uniquely resolve local package objects: " + pin["identity"])
            alternates.chmod(0o644)
            alternates.write_text(str(matches[0] / "objects") + "\n")
        if git(checkout, "rev-parse", "HEAD").decode().strip() != revision:
            raise ValueError("Package revision differs from Package.resolved")
        if git(checkout, "status", "--porcelain", "--untracked-files=no").strip():
            raise ValueError("Package checkout has tracked modifications")
    return packages


def verify_compilation(output):
    log = (output / "build.log").read_text()
    swift = [line for line in log.splitlines()
             if ("/swiftc " in line or "/swift-frontend " in line) and
             any("-module-name " + name + " " in line for name in
                 ["iTerm2", "iTerm2Shared", "iTerm2SharedARC"])]
    assert swift and all(" -Onone " not in line for line in swift)
    assert any(" -O " in line and "-assert-config Debug" in line for line in swift)
    assert any("-whole-module-optimization" in line for line in swift)
    assert all("LIPI_TERMINAL" in line for line in swift)
    assert any("DEBUG" in line and "ITERM_DEBUG" in line for line in swift)
    responses = [path for path in (output / "DerivedData").rglob("*common-args.resp")
                 if any("/" + name + ".build/" in str(path) for name in
                        ["iTerm2", "iTerm2Shared", "iTerm2SharedARC"])]
    assert responses
    for path in responses:
        args = shlex.split(path.read_text())
        assert "-O2" in args and "-DLIPI_TERMINAL=1" in args, str(path)
        assert not any("NS_BLOCK_ASSERTIONS" in arg or "sanitize=" in arg for arg in args)
    return {"optimizedWithAssertions": True, "lipiCompiled": True,
            "swiftCommandCount": len(swift), "clangResponseCount": len(responses)}


def verify_product(app, source_icon):
    verify_public_icon(app, source_icon)
    plist = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert plist["CFBundleIdentifier"] == IDENTITY
    assert plist["CFBundleName"] == NAME and plist["CFBundleExecutable"] == "iTerm2"
    assert plist["LipiPublicBuild"] is True
    assert not any(k.startswith("SUPublic") or k.startswith("SUFeed") for k in plist)
    assert plist["SUEnableAutomaticChecks"] is False
    assert plist["SUAutomaticallyUpdate"] is False
    macho = []
    for path in sorted(app.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        if "Mach-O" in run("/usr/bin/file", "-b", str(path)).decode():
            dependencies = run("/usr/bin/otool", "-L", str(path)).decode()
            assert "libclang_rt.asan" not in dependencies and "libclang_rt.tsan" not in dependencies
            macho.append(str(path.relative_to(app)))
    assert macho
    return {"machOFiles": macho, "filesSHA256": {
        str(p.relative_to(app)): sha(p) for p in sorted(app.rglob("*"))
        if p.is_file() and not p.is_symlink()}, "symlinks": {
        str(p.relative_to(app)): os.readlink(p) for p in sorted(app.rglob("*")) if p.is_symlink()}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New or empty build directory (never an installed app)")
    parser.add_argument("--source-packages", type=Path, required=True, help="Existing pinned Xcode SourcePackages cache, copied read-only")
    parser.add_argument("--developer-dir", type=Path, help="Xcode Developer directory (default: xcode-select -p)")
    parser.add_argument("--noise-source", type=Path, help="Pinned noise-c checkout, if the source submodule is absent")
    parser.add_argument("--shell-integration-source", type=Path, help="Pinned shell integration checkout, if the source submodule is absent")
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    if output == ROOT or ROOT in output.parents or output == Path.home() or any(p.suffix == ".app" for p in (output, *output.parents)):
        parser.error("Output must be a separate build directory, not the source, home, or an app")
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        parser.error("Output must be new or empty; existing builds are never replaced")
    developer = args.developer_dir or Path(run("/usr/bin/xcode-select", "-p").decode().strip())
    xcodebuild = developer / "usr/bin/xcodebuild"
    if not xcodebuild.is_file():
        parser.error("A full Xcode Developer directory is required")
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    commit, source = stage_source(output, {
        "Companion/CompanionCore/Sources/CNoise/vendor": args.noise_source,
        "submodules/iTerm2-shell-integration": args.shell_integration_source})
    packages = stage_packages(args.source_packages.expanduser().resolve(), output, source)
    for directory in ["home", "tmp", "PackageCache"]:
        (output / directory).mkdir(mode=0o700)
    env = dict(HOME=str(output / "home"), CFFIXED_USER_HOME=str(output / "home"),
               TMPDIR=str(output / "tmp") + "/", LANG="en_US.UTF-8",
               PATH="/usr/bin:/bin:/usr/sbin:/sbin", DEVELOPER_DIR=str(developer),
               GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_COUNT="1",
               GIT_CONFIG_KEY_0="core.hooksPath", GIT_CONFIG_VALUE_0="/dev/null",
               GIT_ALLOW_PROTOCOL="file", GIT_TERMINAL_PROMPT="0", GIT_ASKPASS="/usr/bin/false")
    command = [str(xcodebuild), "-project", str(source / "iTerm2.xcodeproj"), "-scheme", "iTerm2",
               "-configuration", "Development", "-destination", "platform=macOS,arch=" + os.uname().machine,
               "-derivedDataPath", str(output / "DerivedData"), "-clonedSourcePackagesDirPath", str(packages),
               "-packageCachePath", str(output / "PackageCache"), "-onlyUsePackageVersionsFromResolvedFile",
               "-disableAutomaticPackageResolution", "-skipPackageUpdates", "-scmProvider", "system",
               "-scm-disable-keychain", "-jobs", "4", "ONLY_ACTIVE_ARCH=YES",
               "SYMROOT=" + str(output / "Products"), "CODE_SIGN_IDENTITY=", "CODE_SIGNING_REQUIRED=NO",
               "CODE_SIGNING_ALLOWED=NO", "DEVELOPMENT_TEAM=", "PROVISIONING_PROFILE_SPECIFIER=",
               "ENABLE_ADDRESS_SANITIZER=NO", "ENABLE_THREAD_SANITIZER=NO",
               "SWIFT_OPTIMIZATION_LEVEL=-O", "SWIFT_COMPILATION_MODE=wholemodule", "GCC_OPTIMIZATION_LEVEL=2",
               "OTHER_SWIFT_FLAGS=$(inherited) -assert-config Debug",
               "GCC_PREPROCESSOR_DEFINITIONS=$(inherited) LIPI_TERMINAL=1",
               "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LIPI_TERMINAL",
               "ASSETCATALOG_COMPILER_APPICON_NAME=", "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS=NO"]
    print("Building isolated Lipi source " + commit + ". Output: " + str(output), flush=True)
    with (output / "build-settings.json").open("wb") as log:
        subprocess.run(command + ["-showBuildSettings", "-json"], cwd=source, env=env, stdout=log, check=True)
    settings = json.loads((output / "build-settings.json").read_text())
    for target in settings:
        values = target["buildSettings"]
        assert values["SWIFT_OPTIMIZATION_LEVEL"] == "-O" and values["GCC_OPTIMIZATION_LEVEL"] == "2"
        assert "LIPI_TERMINAL" in values["SWIFT_ACTIVE_COMPILATION_CONDITIONS"]
        assert "LIPI_TERMINAL=1" in values["GCC_PREPROCESSOR_DEFINITIONS"]
        assert values.get("ENABLE_NS_ASSERTIONS", "YES") != "NO"
    with (output / "build.log").open("wb") as log:
        process = subprocess.Popen(command + ["build"], cwd=source, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        for line in process.stdout:
            log.write(line)
            log.flush()
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
        code = process.wait()
    (output / "build-exit.txt").write_text(str(code) + "\n")
    if code:
        raise SystemExit(code)
    compilation = verify_compilation(output)
    app = output / (NAME + ".app")
    shutil.copytree(output / "Products/Development/iTerm2.app", app, symlinks=True)
    source_icon = source / "Resources/lipi" / ICON
    install_public_icon(app, source_icon)
    manifest = verify_product(app, source_icon)
    receipt = {"sourceCommit": commit, "sourceTree": git(ROOT, "rev-parse", commit + "^{tree}").decode().strip(),
               "compilation": compilation, "bundleIdentifier": IDENTITY, "buildExit": code,
               "packageResolvedSHA256": sha(source / LOCK), "buildLogSHA256": sha(output / "build.log"),
               "settingsSHA256": sha(output / "build-settings.json"), "app": app.name,
               "appIconSHA256": sha(source_icon),
               "scope": "Build only; no installation, launch, signing credentials, or runtime acceptance"}
    (output / "app-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    receipt["appManifestSHA256"] = sha(output / "app-manifest.json")
    (output / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("Built " + str(app) + ". Not installed or launched.")


if __name__ == "__main__":
    main()
