"""Include dependency versions and upstream license files with the shipped helper."""

from importlib.metadata import distributions
import json
from pathlib import Path
import shutil
import sys


def main(destination):
    destination = Path(destination)
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    versions = {}
    # Include build-tool notices too, to cover the PyInstaller bootloader.
    for dist in sorted(distributions(), key=lambda item: item.metadata["Name"].lower()):
        name = dist.metadata["Name"]
        versions[name] = dist.version
        for file in dist.files or []:
            if any(word in str(file).lower() for word in ("license", "copying", "notice")):
                source = Path(dist.locate_file(file))
                if source.is_file():
                    target = destination / name / str(file)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, target)
    python_license = Path(sys.base_prefix) / "lib" / f"python{sys.version_info.major}.{sys.version_info.minor}" / "LICENSE.txt"
    if not python_license.is_file():
        raise RuntimeError(f"Python license missing: {python_license}")
    shutil.copyfile(python_license, destination / "Python.LICENSE.txt")
    (destination / "versions.json").write_text(json.dumps({
        "python": sys.version.split()[0], "packages": versions,
    }, indent=2) + "\n")


if __name__ == "__main__":
    main(sys.argv[1])
