"""Expected inventory of the embedded Sparkle framework.

Packaging verification stays a closed allowlist: instead of hardcoding every
Sparkle path, the expected directories, files, symlinks, and executable
members are derived from the vendored framework copy that assembly embeds
(minus the excluded development/XPC payloads). Any drift between the vendored
framework and the packaged app therefore still fails verification exactly.

Environment contract (exported by scripts/common.sh):
  SPARKLE_FRAMEWORK_SOURCE  absolute path of the vendored Sparkle.framework
  SPARKLE_EMBED_EXCLUDES    space-separated top-level members not embedded
"""

import os
import pathlib
import stat

FRAMEWORK_RELATIVE = "Contents/Frameworks/Sparkle.framework"
EXECUTABLE_MEMBERS = {
    "Versions/B/Sparkle",
    "Versions/B/Autoupdate",
    "Versions/B/Updater.app/Contents/MacOS/Updater",
}


def sparkle_expected(prefix=""):
    """Return (directories, files, links, executables) for the embedded
    framework, each relative path prepended with ``prefix``.

    ``links`` maps relative symlink paths to their exact targets. Raises if
    the vendored framework is missing so verification can never silently run
    without its Sparkle expectations.
    """
    source = os.environ.get("SPARKLE_FRAMEWORK_SOURCE", "")
    excludes = set(os.environ.get("SPARKLE_EMBED_EXCLUDES", "").split())
    root = pathlib.Path(source)
    if not source or not root.is_dir():
        raise RuntimeError(f"vendored Sparkle framework is missing: {source!r}")

    def excluded(relative):
        parts = pathlib.PurePosixPath(relative).parts
        if len(parts) == 1 and parts[0] in excludes:
            return True
        return len(parts) >= 3 and parts[0] == "Versions" and parts[2] in excludes

    base = prefix + FRAMEWORK_RELATIVE
    directories = {p for p in _parents_of(base)}
    directories.add(base)
    files = set()
    links = {}
    executables = set()
    for current, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
        kept = []
        for name in dirnames:
            path = pathlib.Path(current, name)
            relative = path.relative_to(root).as_posix()
            if excluded(relative):
                continue
            if path.is_symlink():
                links[f"{base}/{relative}"] = os.readlink(path)
            else:
                directories.add(f"{base}/{relative}")
                kept.append(name)
        dirnames[:] = kept
        for name in filenames:
            path = pathlib.Path(current, name)
            relative = path.relative_to(root).as_posix()
            if excluded(relative):
                continue
            if path.is_symlink():
                links[f"{base}/{relative}"] = os.readlink(path)
                continue
            if not stat.S_ISREG(path.lstat().st_mode):
                raise RuntimeError(f"unsupported vendored Sparkle member: {relative}")
            files.add(f"{base}/{relative}")
            if relative in EXECUTABLE_MEMBERS:
                executables.add(f"{base}/{relative}")
    missing = {f"{base}/{member}" for member in EXECUTABLE_MEMBERS} - executables
    if missing:
        raise RuntimeError(f"vendored Sparkle framework lacks executables: {sorted(missing)}")
    return directories, files, links, executables


def _parents_of(relative):
    parts = pathlib.PurePosixPath(relative).parts
    for index in range(1, len(parts)):
        yield "/".join(parts[:index])
