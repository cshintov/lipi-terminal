#!/usr/bin/python3
"""Source/build-contract tests. No GUI, network, preferences, or keychain access."""
import pathlib
import subprocess
import tempfile
import plistlib
import unittest
import xml.etree.ElementTree as ET

import lipi_build

ROOT = pathlib.Path(__file__).resolve().parents[1]


def preprocess(path, lipi):
    text = (ROOT / path).read_text()
    text = "\n".join(line for line in text.splitlines()
                     if not line.lstrip().startswith(("#import", "#include")))
    return subprocess.check_output(["/usr/bin/clang", "-E", "-P", "-x", "objective-c",
                                    "-DLIPI_TERMINAL=" + str(int(lipi)), "-"],
                                   input=text.encode(), stderr=subprocess.PIPE).decode()


class LipiBuildTests(unittest.TestCase):
    def test_hostile_plist_cannot_enable_update(self):
        document_types = [{"CFBundleTypeIconFile": "iTerm2.icns"},
                          {"CFBundleTypeIconFile": "iTerm2Script.icns"}]
        result = lipi_build.public_plist({"CFBundleDocumentTypes": document_types,
            "SUFeedURL": "https://invalid.example/appcast",
            "SUFeedURLForFinal": "https://invalid.example/final", "SUPublicEDKey": "old-key",
            "SUPublicDSAKeyFile": "old-key.pem", "SUEnableAutomaticChecks": True,
            "SUAutomaticallyUpdate": True, "CFBundleIconName": "old-icon",
            "CFBundleIconFile": "old-icon.icns", "CFBundleIconFiles": ["old-icon"],
            "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["old-icon"]}},
            "CFBundleIdentifier": "com.googlecode.iterm2"})
        self.assertEqual(result["CFBundleIdentifier"], lipi_build.IDENTITY)
        self.assertFalse(result["SUEnableAutomaticChecks"])
        self.assertFalse(result["SUAutomaticallyUpdate"])
        self.assertFalse(any(key.startswith(("SUFeed", "SUPublic")) for key in result))
        self.assertEqual({key: value for key, value in result.items() if key.startswith("CFBundleIcon")},
                         {"CFBundleIconFile": "LipiTerminal.icns"})
        self.assertEqual(result["CFBundleDocumentTypes"][0]["CFBundleTypeIconFile"], "LipiTerminal.icns")
        self.assertEqual(result["CFBundleDocumentTypes"][1], document_types[1])
        self.assertEqual(document_types[0]["CFBundleTypeIconFile"], "iTerm2.icns")
        source_icon = ROOT / "Resources/lipi/LipiTerminal.icns"
        self.assertEqual(lipi_build.sha(source_icon),
                         "93e621c6099c669707c2bbb589cec03c8415c410c478f37c42f171553683dbb6")
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / "Lipi Terminal.app"
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(result))
            for name in ["iTerm2.icns", "AppIcon.icns", "AppIcon.png", "iTerm2Script.icns"]:
                (resources / name).write_bytes(b"fixture")
            (resources / "iTerm2 App Icon for Nightly.icon").mkdir()
            lipi_build.install_public_icon(app, source_icon)
            self.assertEqual((resources / "LipiTerminal.icns").read_bytes(), source_icon.read_bytes())
            self.assertEqual((resources / "iTerm2Script.icns").read_bytes(), b"fixture")
            lipi_build.verify_public_icon(app, source_icon)
            (resources / "LipiTerminal.icns").write_bytes(b"wrong icon")
            with self.assertRaises(AssertionError):
                lipi_build.verify_public_icon(app, source_icon)
            lipi_build.install_public_icon(app, source_icon)
            (resources / "AppIcon.png").write_bytes(b"upstream")
            with self.assertRaises(AssertionError):
                lipi_build.verify_public_icon(app, source_icon)

    def test_no_updater_object_in_nib(self):
        tree = ET.parse(ROOT / "sources/MainMenu/Base.lproj/MainMenu.xib")
        self.assertFalse(tree.findall(".//*[@customClass='SUUpdater']"))
        self.assertFalse(tree.findall(".//*[@property='suUpdater']"))

    def test_public_compile_has_no_updater_checks_or_feed_writes(self):
        for path in ["sources/AppKit/iTermApplicationDelegate.m",
                     "sources/AppLaunch/iTermLaunchExperienceController.m",
                     "sources/iTermController/iTermController.m"]:
            text = preprocess(path, True)
            self.assertNotIn("[SUUpdater sharedUpdater]", text, path)
            self.assertNotIn("[suUpdater checkForUpdates:", text, path)
            self.assertNotIn('forKey:@"SUFeedURL"', text, path)
            self.assertNotIn('forKey:@"SUFeedAlternateAppNameKey"', text, path)

    def test_upstream_compile_keeps_updater(self):
        self.assertIn("[SUUpdater sharedUpdater]",
                      preprocess("sources/AppKit/iTermApplicationDelegate.m", False))
        self.assertIn('forKey:@"SUFeedURL"',
                      preprocess("sources/iTermController/iTermController.m", False))

    def test_public_suite_and_package_check_precede_lock(self):
        text = preprocess("sources/AppKit/main.m", True)
        self.assertLess(text.index("Lipi public build identity mismatch"), text.index("[iTermInstanceLock acquire]"))
        self.assertLess(text.index('suiteNameForBase:@"lipi-terminal"'),
                        text.index("[iTermInstanceLock acquire]"))
        self.assertIn("if (![iTermUserDefaults customSuiteName])", text)

    def test_legacy_migration_returns_before_access(self):
        text = preprocess("sources/AppLaunch/iTermMigrationHelper.m", True)
        method = text.split("+ (void)migrateApplicationSupportDirectoryIfNeeded {", 1)[1]
        self.assertEqual(method.split("\n}", 1)[0].strip(), "return;")

    def test_crash_submission_is_inert(self):
        text = preprocess("ThirdParty/UKCrashReporter/UKCrashReporter.m", True)
        method = text.split("sendCrashReport:", 1)[1].split("{", 1)[1]
        self.assertEqual(method.split("\n}", 1)[0].strip(), "return;")
        self.assertNotIn("UKCrashReporterCheckForCrash();",
                         preprocess("sources/iTermController/iTermController.m", True))

    def test_private_keychain_families_have_public_namespaces(self):
        for file in ["Companion/CompanionMacIdentity.swift", "Companion/CompanionPushNonceRegistry.swift",
                     "AITerm/AITermControllerObjC.swift", "PasswordManager/KeychainPasswordDataSource.swift",
                     "PasswordManager/AdapterPasswordDataSource.swift"]:
            text = (ROOT / "sources" / file).read_text()
            public = text.split("#if LIPI_TERMINAL", 1)[1].split("#else", 1)[0]
            self.assertIn("io.github.cshintov.lipi-terminal.", public, file)


if __name__ == "__main__":
    unittest.main()
