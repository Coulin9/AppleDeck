import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "runtime/guest/rootfs/usr/lib/appledeck/steam-neptune-path"
loader = importlib.machinery.SourceFileLoader("neptune_path", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
neptune = importlib.util.module_from_spec(spec)
with patch.object(sys, "path", [str(SCRIPT.parent), *sys.path]):
    loader.exec_module(neptune)


class NeptunePathTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.steam = self.root / "Steam"
        self.base = self.steam / "steamapps/common/Proton 11.0"
        self.payload = self.root / "payload"
        self.state = self.root / "state"
        self.cmdline = self.root / "cmdline"
        self.config = self.steam / "config/config.vdf"
        self.config.parent.mkdir(parents=True)
        self.config.write_text('"InstallConfigStore" { "Software" { "Valve" { "Steam" {} } } }\n')
        hashes = {}
        for arch, machine in neptune.tools.NEPTUNE_ARCHITECTURES.items():
            for name in neptune.payload_files(arch):
                target = self.payload / name
                target.parent.mkdir(parents=True, exist_ok=True)
                data = bytearray(64)
                data[:6] = b"\x7fELF\x02\x01"
                struct.pack_into("<H", data, 18, machine)
                if name.endswith(".dll"):
                    data = bytearray(256)
                    data[:2] = b"MZ"
                    struct.pack_into("<I", data, 0x3c, 0x80)
                    data[0x80:0x84] = b"PE\0\0"
                    struct.pack_into("<H", data, 0x84, 0x8664)
                    if name.endswith("/nptunix.dll"):
                        data[0x40:0x50] = b"Wine builtin DLL"
                        data[0xa0:0xac] = b"nptunix.dll\0"
                target.write_bytes(data)
                hashes[name] = neptune.digest(target)
        (self.payload / "payload.json").write_text(json.dumps({"schema": 1, "files": hashes}))
        ntdll = self.base / "files/lib/wine/x86_64-unix/ntdll.so"
        ntdll.parent.mkdir(parents=True)
        ntdll.write_bytes((self.payload / "x86_64-unix/nptunix.so").read_bytes())
        self.manifest = ('"manifest" { "version" "2" "commandline" "/proton %verb%" '
                         '"require_tool_appid" "4183110" "use_sessions" "1" }\n')
        (self.base / "toolmanifest.vdf").write_text(self.manifest)
        (self.base / "version").write_text("upstream-build\n")
        (self.base / "steampipe_fixups.json").write_text('{"empty_dirs":[],"no_write_paths":[]}')
        (self.base / "user_settings.py").write_text("user_settings = {}\n")
        (self.base / "proton").write_text(
            '#!/bin/sh\nprintf "%s\\n" "$0" "${PROTON_USE_ARM64:-unset}" '
            '"${NPT_PERF:-unset}" "${WINEDLLOVERRIDES:-unset}" '
            '"${JAVA_TOOL_OPTIONS:-unset}" "${FEX_DISKCACHE:-unset}" "$@"\n')
        (self.base / "proton").chmod(0o755)
        template = self.base / "files/share/default_pfx"
        (template / "drive_c/windows/system32").mkdir(parents=True)
        (template / "system.reg").write_text("upstream-registry\n")
        self.prefix = self.steam / "steamapps/compatdata/42/pfx/drive_c/windows/system32"
        self.prefix.mkdir(parents=True)
        (self.prefix / "d3d12.dll").write_bytes(b"user-graphics-dll")

    def prepare(self, backend="neptune"):
        return neptune.synchronize_tools(self.steam, self.state, self.payload, backend)

    def runtime(self, key=None):
        return neptune.tools.runtime_root(self.steam, key or neptune.tools.DEFAULT_BASE)

    def launch(self, backend="neptune", arguments=None, appid="42", environment=None):
        self.cmdline.write_text("appledeck.gfx=" + backend)
        env = dict(os.environ, APPLEDECK_CMDLINE=str(self.cmdline), SteamAppId=appid)
        for variable in ("NPT_PERF", "PROTON_USE_ARM64", "WINEDLLOVERRIDES", "JAVA_TOOL_OPTIONS", "FEX_DISKCACHE"):
            env.pop(variable, None)
        env.update(environment or {})
        return subprocess.check_output([str(self.runtime() / "neptune-launch"), *(arguments or ["run"])],
                                       env=env, text=True).splitlines()

    def test_runtime_preserves_upstream_files_and_leaves_games_alone(self):
        before = self.config.read_bytes()
        original = (self.base / "proton").read_bytes()
        self.prepare()
        runtime = self.runtime()
        self.assertEqual((runtime / "proton").read_bytes(), original)
        self.assertEqual((runtime / "version").read_bytes(), (self.base / "version").read_bytes())
        self.assertEqual((runtime / "steampipe_fixups.json").read_bytes(),
                         (self.base / "steampipe_fixups.json").read_bytes())
        self.assertEqual((runtime / "files/share/default_pfx/system.reg").read_text(), "upstream-registry\n")
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual((self.prefix / "d3d12.dll").read_bytes(), b"user-graphics-dll")
        self.assertFalse((self.state / "ownership.json").exists())
        self.assertNotIn("proton.real", [path.name for path in runtime.iterdir()])
        self.assertIn('"commandline" "/neptune-launch %verb%"', (runtime / "toolmanifest.vdf").read_text())
        self.assertIn('"require_tool_appid" "4183110"', (runtime / "toolmanifest.vdf").read_text())
        self.assertIn('"use_sessions" "1"', (runtime / "toolmanifest.vdf").read_text())
        self.assertEqual((runtime / "files/share/default_pfx/drive_c/windows/system32/nptunix.dll").read_bytes(),
                         (self.payload / "x86_64-windows/nptunix.dll").read_bytes())

    def test_internal_links_are_private_and_source_changes_cannot_leak(self):
        source = self.base / "files/library.txt"
        source.write_text("original")
        (self.base / "files/absolute").symlink_to(source)
        (self.base / "files/relative").symlink_to("library.txt")
        self.prepare()
        runtime = self.runtime()
        self.assertEqual((runtime / "files/absolute").resolve(), runtime / "files/library.txt")
        source.write_text("updated upstream")
        self.assertEqual((runtime / "files/absolute").read_text(), "original")
        self.assertEqual((runtime / "files/relative").read_text(), "original")
        self.prepare()
        self.assertNotEqual(self.runtime(), runtime)
        self.assertEqual((self.runtime() / "files/library.txt").read_text(), "updated upstream")
        self.assertFalse(runtime.exists())

    def test_unchanged_inputs_reuse_published_runtime(self):
        self.prepare()
        runtime = self.runtime()
        stamp = (runtime / "proton").stat().st_mtime_ns
        self.prepare()
        self.assertEqual(self.runtime(), runtime)
        self.assertEqual((runtime / "proton").stat().st_mtime_ns, stamp)
        (self.base / "user_settings.py").write_text('user_settings = {"PROTON_LOG": "1"}\n')
        self.prepare()
        self.assertNotEqual(self.runtime(), runtime)

    def test_bad_payload_keeps_existing_runtime_and_game_files(self):
        self.prepare()
        runtime = self.runtime()
        registration = (neptune.tools.tool_dir(self.steam, neptune.tools.DEFAULT_BASE)
                        / "compatibilitytool.vdf").read_bytes()
        (self.payload / "x86_64-windows/d3d12.dll").write_bytes(b"tampered")
        self.assertEqual(self.prepare(), {})
        self.assertEqual(self.runtime(), runtime)
        self.assertEqual((neptune.tools.tool_dir(self.steam, neptune.tools.DEFAULT_BASE)
                          / "compatibilitytool.vdf").read_bytes(), registration)
        self.assertEqual((self.prefix / "d3d12.dll").read_bytes(), b"user-graphics-dll")
        self.assertIn("checksum mismatch", json.loads((self.state / "errors.json").read_text())[neptune.tools.DEFAULT_BASE])

    def test_payload_requires_valid_pe_architecture_and_wine_builtin(self):
        target = self.payload / "x86_64-windows/nptunix.dll"
        original = target.read_bytes()
        manifest_path = self.payload / "payload.json"
        manifest = json.loads(manifest_path.read_text())
        for offset, replacement, message in [
            (0, b"NO", "PE header"),
            (0x84, b"\x4c\x01", "PE architecture"),
            (0x40, b"Wrong builtin!!!", "Wine builtin"),
        ]:
            with self.subTest(message=message):
                contents = bytearray(original)
                contents[offset:offset + len(replacement)] = replacement
                target.write_bytes(contents)
                manifest["files"]["x86_64-windows/nptunix.dll"] = neptune.digest(target)
                manifest_path.write_text(json.dumps(manifest))
                with self.assertRaisesRegex(ValueError, message):
                    neptune.validate_payload(self.payload, "x86_64")

    def test_changed_source_aborts_before_publication(self):
        self.prepare()
        runtime = self.runtime()
        (self.base / "version").write_text("next-upstream-build\n")
        copy_runtime = neptune.copy_runtime

        def changed_during_copy(base, target):
            copy_runtime(base, target)
            (base / "version").write_text("another-build\n")

        with patch.object(neptune, "copy_runtime", changed_during_copy):
            self.assertEqual(self.prepare(), {})
        self.assertEqual(self.runtime(), runtime)

    def test_launcher_changes_graphics_only_for_every_game(self):
        self.prepare()
        for appid in ("1091500", "223850", "2622380"):
            args = ["waitforexitandrun", "/games/game.exe", "--user-argument"]
            output = self.launch(arguments=args, appid=appid)
            self.assertEqual(output[1], "0")
            self.assertEqual(output[4:6], ["unset", "unset"])
            self.assertEqual(output[6:], args)
        output = self.launch(arguments=["getcompatpath", "/games/file"], environment={"WINEDLLOVERRIDES": "winhttp=n"})
        self.assertIn("winhttp=n", output[3])
        stock = self.launch(backend="venus", environment={"JAVA_TOOL_OPTIONS": "-Duser=true"})
        self.assertEqual(Path(stock[0]), self.base / "proton")
        self.assertEqual(stock[4], "-Duser=true")
        self.assertEqual(stock[1:4], ["unset", "unset", "unset"])

    def test_unsupported_manifest_and_first_copy_failure_can_retry(self):
        (self.base / "toolmanifest.vdf").write_text('"manifest" { "commandline" "/unknown %verb%" }')
        self.assertEqual(self.prepare(), {})
        self.assertFalse(neptune.tools.tool_dir(self.steam, neptune.tools.DEFAULT_BASE).exists())
        (self.base / "toolmanifest.vdf").write_text(self.manifest)
        with patch.object(neptune, "copy_runtime", side_effect=OSError("copy failure")):
            self.assertEqual(self.prepare(), {})
        self.assertFalse(neptune.tools.tool_dir(self.steam, neptune.tools.DEFAULT_BASE).exists())
        self.assertIn(neptune.tools.DEFAULT_BASE, self.prepare())

    def test_fallback_rejects_a_changed_runtime_contract(self):
        self.prepare()
        (self.base / "toolmanifest.vdf").write_text(self.manifest.replace("4183110", "1628350"))
        with self.assertRaises(subprocess.CalledProcessError):
            self.launch(backend="venus")

    def test_legacy_tool_is_identified_for_removal_without_prefix_migration(self):
        directory = neptune.tools.tool_dir(self.steam, neptune.tools.DEFAULT_BASE)
        directory.mkdir(parents=True)
        (directory / neptune.OWNER).write_text(json.dumps({"schema": 1, "base": str(self.base)}))
        self.assertEqual(neptune.tools.owned_tools(self.steam)[neptune.tools.DEFAULT_BASE]["schema"], 1)
        with self.assertRaises(ValueError):
            self.runtime()
        neptune.remove_tool(self.steam, neptune.tools.DEFAULT_BASE)
        self.prepare()
        self.assertEqual(neptune.tools.owned_tools(self.steam)[neptune.tools.DEFAULT_BASE]["schema"], 2)
        self.assertEqual((self.prefix / "d3d12.dll").read_bytes(), b"user-graphics-dll")

    def test_ge_registration_fields_and_modules_are_preserved(self):
        key = neptune.tools.ge_key("GE-Proton11-12", "x86_64")
        base = self.steam / "compatibilitytools.d/GE-Proton11-12"
        shutil.copytree(self.base, base)
        (base / "protonfixes").mkdir()
        (base / "protonfixes/__init__.py").write_text("# upstream game fixes\n")
        (base / "compatibilitytool.vdf").write_text(
            '"compatibilitytools" { "compat_tools" { "ge-proton11-12" { "install_path" "." '
            '"display_name" "GE-Proton11-12" "from_oslist" "windows" "to_oslist" "linux" "priority" "5" } } }')
        self.state.mkdir(parents=True)
        (self.state / "selection.json").write_text(json.dumps([key]))
        self.prepare()
        runtime = self.runtime(key)
        self.assertEqual((runtime / "protonfixes/__init__.py").read_text(), "# upstream game fixes\n")
        vdf = (neptune.tools.tool_dir(self.steam, key) / "compatibilitytool.vdf").read_text()
        self.assertIn('"priority" "5"', vdf)
        self.assertIn('"runtimes/', vdf)

    def test_arm64_runtime_requires_mullion_and_keeps_its_template(self):
        key = "steam:4628740"
        base = self.base.with_name("Proton 11.0 (ARM64)")
        shutil.copytree(self.base, base)
        (base / "files/bin-arm64").mkdir()
        (base / "files/bin-arm64/wine").touch()
        (base / "files/share/default_pfx").rename(base / "files/share/default_pfx_arm64")
        ntdll = base / "files/lib/wine/aarch64-unix/ntdll.so"
        ntdll.parent.mkdir()
        ntdll.write_bytes((self.payload / "aarch64-unix/nptunix.so").read_bytes())
        (self.steam / "steamapps/appmanifest_4628740.acf").write_text(
            '"AppState" { "name" "Proton 11.0 (ARM64)" "installdir" "Proton 11.0 (ARM64)" "StateFlags" "4" }')
        self.state.mkdir(parents=True)
        (self.state / "selection.json").write_text(json.dumps([key]))
        self.assertEqual(self.prepare(), {})
        self.prepare("mullion")
        runtime = self.runtime(key)
        self.assertEqual((runtime / "files/share/default_pfx_arm64/drive_c/windows/system32/nptunix.dll").read_bytes(),
                         (self.payload / "aarch64-windows/nptunix.dll").read_bytes())


if __name__ == "__main__":
    unittest.main()
