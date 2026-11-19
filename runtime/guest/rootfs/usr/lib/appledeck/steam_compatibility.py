"""Steam-owned installations and the Neptune selections for this Steam user."""

from dataclasses import dataclass, replace
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import re
import struct


_loader = importlib.machinery.SourceFileLoader(
    "steam_compat_default", str(Path(__file__).with_name("steam-compat-default")))
_spec = importlib.util.spec_from_loader(_loader.name, _loader)
compat = importlib.util.module_from_spec(_spec)
_loader.exec_module(compat)

DEFAULT_BASE = "steam:4628710"
OWNER = "appledeck-neptune.json"
GE_NAME = re.compile(r"(GE-Proton[0-9][A-Za-z0-9.-]{0,39}?)(?:-(x86_64|aarch64))?", re.IGNORECASE)
BASE_KEY = re.compile(r"steam:[0-9]{1,10}|ge:ge-proton[0-9][a-z0-9.-]{0,39}:(?:x86_64|aarch64)")
VDF_TOOLS = ("compatibilitytools", "compat_tools")
NEPTUNE_ARCHITECTURES = {"x86_64": 62, "aarch64": 183}


def backend_allows(architecture, backend):
    return architecture != "aarch64" or backend == "mullion"


def steam_root():
    return Path(os.environ.get("APPLEDECK_STEAM_ROOT") or Path.home() / ".local/share/Steam")


def state_dir():
    data = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share")
    return Path(os.environ.get("APPLEDECK_GFX_STATE") or data / "appledeck/gfx-path") / "neptune"


def selections(state):
    try:
        enabled = json.loads((state / "selection.json").read_text())
    except FileNotFoundError:
        return {DEFAULT_BASE}
    if not isinstance(enabled, list) or any(
            not isinstance(key, str) or not BASE_KEY.fullmatch(key) for key in enabled):
        raise ValueError("Neptune 开关配置无效。")
    return set(enabled)


def tool_dir(steam, key):
    name = "appledeck-neptune" if key == DEFAULT_BASE else "appledeck-neptune-" + key.replace(":", "-")
    return steam / "compatibilitytools.d" / name


def legacy_tool_id(key):
    if key == DEFAULT_BASE:
        return "appledeck_neptune"
    return "appledeck_neptune_" + key.replace(":", "_")


def tool_id(key):
    name = legacy_tool_id(key)
    # Steam maps Windows cloud paths into the Wine prefix only for tool IDs
    # that contain "proton". GE registrations already include it.
    return name + "_proton" if key.startswith("steam:") else name


def registration_runtime(root):
    values, blocks, _ = compat.vdf_entries((root / "compatibilitytool.vdf").read_text())
    entries = [path for path in blocks if len(path) == 3 and path[:2] == VDF_TOOLS]
    if len(entries) != 1:
        raise ValueError("Neptune 兼容工具注册无效。")
    relative = values[(*entries[0], "install_path")][0]
    runtime = (root / relative).resolve()
    if runtime == root.resolve() or not runtime.is_relative_to(root.resolve()):
        raise ValueError("Neptune 运行时目录无效。")
    return runtime


def owned_tools(steam):
    """Read the published runtime, or identify a legacy tool for explicit removal."""
    result = {}
    for root in (steam / "compatibilitytools.d").glob("appledeck-neptune*"):
        if root.is_symlink() or not root.is_dir():
            continue
        try:
            legacy = root / OWNER
            location = legacy if legacy.is_file() else registration_runtime(root) / OWNER
            marker = json.loads(location.read_text())
            if marker.get("schema") not in (1, 2) or not isinstance(marker.get("base"), str):
                continue
            key = marker.get("base_key", DEFAULT_BASE)
            if isinstance(key, str) and BASE_KEY.fullmatch(key) and root == tool_dir(steam, key):
                if marker["schema"] == 2:
                    runtime = registration_runtime(root)
                    if (marker.get("tool_id") != tool_id(key)
                            or runtime != (root / marker["runtime"]).resolve()):
                        continue
                result[key] = marker
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            continue
    return result


def runtime_root(steam, key):
    marker = owned_tools(steam).get(key)
    if not marker or marker.get("schema") != 2:
        raise ValueError("请重新生成 Neptune 兼容层。")
    runtime = registration_runtime(tool_dir(steam, key))
    if not all((runtime / name).is_file() for name in ("proton", "version", "neptune-launch")):
        raise ValueError("Neptune 运行时文件不完整。")
    return runtime


def libraries(steam):
    paths = {steam}
    try:
        values, _, _ = compat.vdf_entries((steam / "steamapps/libraryfolders.vdf").read_text())
    except (OSError, ValueError):
        values = {}
    for path, (value, _, _) in values.items():
        if len(path) == 3 and path[0] == "libraryfolders" and path[-1] == "path":
            candidate = Path(value)
            if candidate.is_absolute():
                paths.add(candidate)
    return [steam, *sorted(paths - {steam})]


def elf_machine(path):
    try:
        with path.open("rb") as source:
            header = source.read(20)
        if header[:6] == b"\x7fELF\x02\x01":
            return struct.unpack_from("<H", header, 18)[0]
    except (OSError, struct.error):
        pass
    return None


def base_architecture(root):
    wine = root / "files/lib/wine"
    if ((root / "files/bin-arm64/wine").is_file()
            and elf_machine(wine / "aarch64-unix/ntdll.so") == 183):
        return "aarch64"
    for architecture, machine in NEPTUNE_ARCHITECTURES.items():
        if elf_machine(wine / f"{architecture}-unix/ntdll.so") == machine:
            return architecture
    return None


@dataclass(frozen=True)
class BaseTool:
    id: str
    name: str
    architecture: str
    base_id: str = ""
    root: Path | None = None
    build: str = ""
    downloading: bool = False
    progress: float | None = None

    @property
    def prefix_template(self):
        if self.architecture == "aarch64" and (self.root / "files/bin-arm64/wine").is_file():
            return "files/share/default_pfx_arm64"
        return "files/share/default_pfx"

    @property
    def neptune_problem(self):
        if not self.root:
            return None
        try:
            # The offline writer mounts /home noexec. Steam will execute this
            # file only after boot, so inspect its mode rather than access(X_OK).
            launcher = self.root / "proton"
            executable = launcher.is_file() and bool(launcher.stat().st_mode & 0o111)
        except OSError:
            executable = False
        if (self.architecture not in NEPTUNE_ARCHITECTURES
                or base_architecture(self.root) != self.architecture
                or not executable
                or not (self.root / self.prefix_template / "drive_c/windows/system32").is_dir()
                or not all((self.root / name).is_file() for name in ("version", "toolmanifest.vdf"))):
            return "此版本的 Wine 目录布局无法加载当前 Neptune 载荷。"
        return None


def steam_catalog(steam):
    # Steam's own x86 and ARM64 Steam Play manifests. The tool AppIDs are integer VDF values.
    try:
        records = compat.read_appinfo(steam / "appcache/appinfo.vdf", {"891390", "3043620"})
    except (OSError, ValueError, IndexError, struct.error):
        return {}
    tools = {}
    for catalog_id, architecture in (("891390", "x86_64"), ("3043620", "aarch64")):
        data = records.get(catalog_id, {}).get("appinfo", {}).get("extended", {}).get("compat_tools", {})
        for base_id, info in data.items():
            if info.get("from_oslist") != "windows" or info.get("to_oslist") != "linux":
                continue
            appid = str(info.get("appid", ""))
            name = info.get("display_name")
            if not re.fullmatch(r"[0-9]{1,10}", appid) or not name:
                continue
            key = "steam:" + appid
            tools[key] = BaseTool(key, name, architecture, base_id)
    return tools


def steam_tools(steam, catalog):
    tools = dict(catalog)
    for library in libraries(steam):
        for manifest in (library / "steamapps").glob("appmanifest_*.acf"):
            key = "steam:" + manifest.stem.removeprefix("appmanifest_")
            try:
                values, _, _ = compat.vdf_entries(manifest.read_text())
                data = {path[-1]: entry[0] for path, entry in values.items()
                        if len(path) == 2 and path[0] == "appstate"}
                name, directory = data["name"], data["installdir"]
                if Path(directory).name != directory or directory in ("", ".", ".."):
                    continue
                root = library / "steamapps/common" / directory
                state = int(data["stateflags"])
                downloaded = int(data.get("bytesdownloaded", "0"))
                total = int(data.get("bytestodownload", "0"))
            except (OSError, ValueError, KeyError):
                continue
            tool = tools.get(key)
            if tool and tool.root:
                continue
            if tool is None:
                # A locally installed official Proton can outlive its catalog listing.
                if (not BASE_KEY.fullmatch(key) or not name.startswith("Proton ")
                        or not (root / "proton").is_file()):
                    continue
                arch = "aarch64" if "(ARM64)" in name else "x86_64"
                tool = BaseTool(key, name, arch)
            installed = bool(state & 4) and (root / "proton").is_file()
            tools[key] = replace(tool, root=root.resolve() if installed else None,
                                 architecture=(base_architecture(root) if installed else None) or tool.architecture,
                                 build=data.get("buildid", ""),
                                 downloading=not installed and bool(state & (2 | 32 | 128 | 256 | 512 | 1024)),
                                 progress=min(downloaded / total, 1) if total > 0 else None)
    if DEFAULT_BASE not in tools:
        tools[DEFAULT_BASE] = BaseTool(DEFAULT_BASE, "Proton 11.0", "x86_64", "proton_11")
    default = tools[DEFAULT_BASE]
    # Keep previously provisioned x86-64 Proton 11 installs working on older disks.
    override = os.environ.get("APPLEDECK_NEPTUNE_PROTON")
    if override or (not default.root and not default.downloading):
        for root in ([Path(override)] if override else
                     [library / "steamapps/common/Proton 11.0" for library in libraries(steam)]):
            if base_architecture(root) == "x86_64" and (root / "proton").is_file():
                tools[DEFAULT_BASE] = replace(default, root=root.resolve(), architecture="x86_64")
                break
    return tools


def ge_key(tag, architecture):
    return "ge:" + tag.lower() + ":" + architecture


def ge_tool(directory):
    try:
        values, blocks, _ = compat.vdf_entries((directory / "compatibilitytool.vdf").read_text())
    except (OSError, ValueError):
        return None
    for path in blocks:
        if len(path) != 3 or path[:2] != VDF_TOOLS:
            continue
        name = values.get((*path, "display_name"), (directory.name,))[0]
        release = GE_NAME.fullmatch(name) or GE_NAME.fullmatch(path[-1])
        install = values.get((*path, "install_path"), (".",))[0]
        root = (directory / install).resolve()
        if not release or not root.is_relative_to(directory.resolve()) or not (root / "proton").is_file():
            continue
        architecture = base_architecture(root) or release[2] or "x86_64"
        return BaseTool(ge_key(release[1], architecture), name, architecture, path[-1], root)
    return None


def installed_ge_tools(steam):
    tools = {}
    for directory in sorted((steam / "compatibilitytools.d").glob("*")):
        if directory.name.startswith((".", "appledeck-neptune")) or not directory.is_dir():
            continue
        if tool := ge_tool(directory):
            tools.setdefault(tool.id, tool)
    return tools


def inventory(steam, state):
    installed = steam_tools(steam, steam_catalog(steam))
    installed.update(installed_ge_tools(steam))
    enabled = selections(state)
    registered = owned_tools(steam)
    try:
        failures = json.loads((state / "errors.json").read_text())
    except (OSError, ValueError):
        failures = {}
    if not isinstance(failures, dict):
        failures = {}
    items = []
    for key in installed.keys() | registered.keys() | enabled:
        tool = installed.get(key)
        marker = registered.get(key, {})
        if not tool:
            name = marker.get("display_name", "").removeprefix("AppleDeck Neptune · ")
            architecture = marker.get("architecture") or (key.split(":")[-1] if key.startswith("ge:") else "x86_64")
            tool = BaseTool(key, name or key.split(":")[1], architecture)
        present = tool.root is not None
        items.append({"id": key, "name": tool.name, "source": key.split(":")[0],
                      "architecture": tool.architecture, "installed": present,
                      "downloading": tool.downloading, "progress": tool.progress,
                      "neptuneEnabled": key in enabled and (present or key in registered or key in failures),
                      "neptuneGenerated": marker.get("schema") == 2, "neptuneProblem": tool.neptune_problem,
                      "neptuneBuild": (marker.get("build") or marker.get("version")) if marker.get("schema") == 2 else None,
                      "neptuneError": failures.get(key) if key in enabled else None})
    return {"items": items}


def set_neptune(steam, state, request, backend="neptune"):
    key, turn_on = request.get("tool"), request.get("enabled")
    if not isinstance(key, str) or not BASE_KEY.fullmatch(key) or not isinstance(turn_on, bool):
        raise ValueError("无效的 Neptune 开关请求。")
    enabled = selections(state)
    if turn_on:
        bases = steam_tools(steam, steam_catalog(steam)) if key.startswith("steam:") else installed_ge_tools(steam)
        tool = bases.get(key)
        if not tool or not tool.root:
            raise ValueError("请先安装此兼容层。")
        if not backend_allows(tool.architecture, backend):
            raise ValueError("ARM64 Neptune 兼容层需要 Mullion。")
        if problem := tool.neptune_problem:
            raise ValueError(problem)
        enabled.add(key)
    else:
        enabled.discard(key)
    compat.atomic_write(state / "selection.json", json.dumps(sorted(enabled)) + "\n")
