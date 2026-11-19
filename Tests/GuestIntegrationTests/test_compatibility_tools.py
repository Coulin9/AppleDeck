import hashlib
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import struct
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[2] / "runtime/guest/rootfs/usr/lib/appledeck"
loader = importlib.machinery.SourceFileLoader("compatibility_control", str(SCRIPTS / "steam-compatibility-offline"))
spec = importlib.util.spec_from_loader(loader.name, loader)
control = importlib.util.module_from_spec(spec)
with patch.object(sys, "path", [str(SCRIPTS), *sys.path]):
    loader.exec_module(control)
tools = control.tools


def binary_vdf(values):
    output = bytearray()
    for key, value in values.items():
        if isinstance(value, dict):
            kind, data = 0, binary_vdf(value)
        elif isinstance(value, int):
            kind, data = 2, struct.pack("<I", value)
        else:
            kind, data = 1, value.encode() + b"\0"
        output.extend(bytes([kind]) + key.encode() + b"\0" + data)
    return bytes(output) + b"\x08"


class CompatibilityToolTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.steam = self.root / "Steam"
        self.state = self.root / "state"

    def steam_metadata(self):
        data = struct.pack("<II", 0x07564428, 1)
        for catalog_id, base_id, appid, name in (
            (891390, "proton_10", 3658110, "Proton 10.0"),
            (3043620, "proton_11-arm64", 4628740, "Proton 11.0 (ARM64)"),
        ):
            record = {"appid": appid, "display_name": name, "from_oslist": "windows", "to_oslist": "linux"}
            tree = binary_vdf({"appinfo": {"extended": {"compat_tools": {base_id: record}}}})
            data += struct.pack("<II", catalog_id, 60 + len(tree)) + bytes(60) + tree
        path = self.steam / "appcache/appinfo.vdf"
        path.parent.mkdir(parents=True)
        path.write_bytes(data + bytes(4))

    def make_steam_install(self, library, appid, name, state, architecture=62):
        root = library / "steamapps/common" / name
        (root / "files/share/default_pfx/drive_c/windows/system32").mkdir(parents=True)
        (root / "version").touch()
        (root / "toolmanifest.vdf").touch()
        (root / "proton").touch(mode=0o755)
        arch = "aarch64" if architecture == 183 else "x86_64"
        ntdll = root / f"files/lib/wine/{arch}-unix/ntdll.so"
        ntdll.parent.mkdir(parents=True)
        ntdll.write_bytes(b"\x7fELF\x02\x01" + bytes(12) + struct.pack("<H", architecture))
        (library / f"steamapps/appmanifest_{appid}.acf").write_text(
            f'"AppState" {{ "appid" "{appid}" "name" "{name}" "installdir" "{name}" "StateFlags" "{state}" }}')
        return root

    def test_catalog_and_offline_install_share_steam_appids(self):
        self.steam_metadata()
        other_library = self.root / "second library"
        root = self.make_steam_install(other_library, "3658110", "Proton 10.0", 6)
        self.make_steam_install(self.steam, "4628740", "Proton 11.0 (ARM64)", 4, 183)
        (self.steam / "steamapps/libraryfolders.vdf").write_text(
            '"libraryfolders" { "1" { "path" ' + tools.compat.vdf_quote(str(other_library)) + ' } }')
        catalog = tools.steam_catalog(self.steam)
        self.assertEqual(set(catalog), {"steam:3658110", "steam:4628740"})
        items = tools.steam_tools(self.steam, catalog)
        self.assertEqual(items["steam:3658110"].root, root.resolve())
        self.assertIsNone(items["steam:3658110"].neptune_problem)
        self.assertIsNone(items["steam:4628740"].neptune_problem)

        exchange = self.root / "exchange"
        source = exchange / "native"
        self.make_steam_install(source, "3658110", "Proton 10.0", 4)
        destination = self.root / "fresh" / "Steam"
        control.install_steam(destination, exchange, "steam:3658110")
        control.install_steam(destination, exchange, "steam:3658110")
        appmanifest = "steamapps/appmanifest_3658110.acf"
        self.assertEqual((destination / appmanifest).read_bytes(), (source / appmanifest).read_bytes())
        self.assertIsNotNone(tools.steam_tools(destination, catalog)["steam:3658110"].root)
        (destination / appmanifest).unlink()
        self.assertIsNone(tools.steam_tools(destination, catalog)["steam:3658110"].root)

    def test_multiple_neptune_switches_are_persisted_for_steam_start(self):
        self.steam_metadata()
        self.make_steam_install(self.steam, "3658110", "Proton 10.0", 4)
        self.make_steam_install(self.steam, "4628740", "Proton 11.0 (ARM64)", 4, 183)
        change = {"action": "neptune", "tool": "steam:3658110", "enabled": True}
        with self.assertRaisesRegex(ValueError, "只读"):
            control.request(self.steam, self.state, self.root, "read", change)
        tools.set_neptune(self.steam, self.state, change)
        arm = dict(change, tool="steam:4628740")
        with self.assertRaisesRegex(ValueError, "Mullion"):
            control.request(self.steam, self.state, self.root, "write", dict(arm, graphicsBackend="neptune"))
        tools.set_neptune(self.steam, self.state, arm, "mullion")
        row = next(item for item in tools.inventory(self.steam, self.state)["items"] if item["id"] == "steam:3658110")
        self.assertTrue(row["neptuneEnabled"])
        self.assertFalse(row["neptuneGenerated"])
        self.assertEqual(tools.selections(self.state), {tools.DEFAULT_BASE, "steam:3658110", "steam:4628740"})

    def test_ge_install_publishes_only_a_verified_steam_tool(self):
        tag = "GE-Proton11-12"
        stem = tag + "-x86_64"
        key = tools.ge_key(tag, "x86_64")
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
            for name, content in {
                "proton": b"#!/bin/sh\n",
                "compatibilitytool.vdf": (
                    '"compatibilitytools" { "compat_tools" { "' + stem + '" { "install_path" "." "display_name" "'
                    + stem + '" } } }').encode(),
            }.items():
                member = tarfile.TarInfo(stem + "/" + name)
                member.mode = 0o755
                member.size = len(content)
                archive.addfile(member, io.BytesIO(content))
        contents = buffer.getvalue()
        exchange = self.root / "exchange"
        exchange.mkdir()
        (exchange / "proton.tar.gz").write_bytes(contents)
        checksum = exchange / "checksum"
        checksum.write_text("0" * 128)
        with self.assertRaisesRegex(ValueError, "校验失败"):
            control.install_ge(self.steam, exchange, key)
        self.assertEqual(tools.installed_ge_tools(self.steam), {})
        checksum.write_text(hashlib.sha512(contents).hexdigest())
        control.install_ge(self.steam, exchange, key)
        with self.assertRaisesRegex(ValueError, "目录已存在"):
            control.install_ge(self.steam, exchange, key)
        self.assertEqual(list(tools.installed_ge_tools(self.steam)), [key])

    def test_discards_legacy_tool_without_changing_game_prefix(self):
        root = tools.tool_dir(self.steam, tools.DEFAULT_BASE)
        root.mkdir(parents=True)
        (root / tools.OWNER).write_text(json.dumps({"schema": 1, "base": "/old/base"}))
        config = self.steam / "config/config.vdf"
        config.parent.mkdir(parents=True)
        text = '"InstallConfigStore" { "Software" { "Valve" { "Steam" {} } } }'
        config.write_text(tools.compat.set_mapping(text, "42", {
            "name": tools.legacy_tool_id(tools.DEFAULT_BASE), "config": "", "priority": "250",
        }))
        prefix = self.steam / "steamapps/compatdata/42/pfx/user.reg"
        prefix.parent.mkdir(parents=True)
        prefix.write_bytes(b"game state")
        control.discard_obsolete_tools(self.steam, self.state)
        self.assertFalse(root.exists())
        self.assertEqual(tools.compat.mappings(config.read_text()), {})
        self.assertEqual(prefix.read_bytes(), b"game state")

    def test_disabling_current_tool_restores_its_base_mapping(self):
        base = self.make_steam_install(self.steam, "4628710", "Proton 11.0", 4)
        root = tools.tool_dir(self.steam, tools.DEFAULT_BASE)
        runtime = root / "runtimes/current"
        runtime.mkdir(parents=True)
        identifier = tools.tool_id(tools.DEFAULT_BASE)
        (root / "compatibilitytool.vdf").write_text(
            f'"compatibilitytools" {{ "compat_tools" {{ "{identifier}" {{ "install_path" "runtimes/current" }} }} }}')
        (runtime / tools.OWNER).write_text(json.dumps({
            "schema": 2, "base_key": tools.DEFAULT_BASE, "base": str(base),
            "base_id": "", "tool_id": identifier, "runtime": "runtimes/current",
        }))
        self.state.mkdir(parents=True)
        (self.state / "selection.json").write_text("[]")
        config = self.steam / "config/config.vdf"
        config.parent.mkdir(parents=True)
        text = '"InstallConfigStore" { "Software" { "Valve" { "Steam" {} } } }'
        config.write_text(tools.compat.set_mapping(text, "42", {
            "name": identifier, "config": "user-config", "priority": "250",
        }))
        control.discard_obsolete_tools(self.steam, self.state)
        self.assertFalse(root.exists())
        self.assertEqual(tools.compat.mappings(config.read_text())["42"], {
            "name": "proton_11", "config": "user-config", "priority": "250",
        })
