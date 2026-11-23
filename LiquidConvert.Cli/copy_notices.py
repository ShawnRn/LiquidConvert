"""Include the interpreter license and the dependency notices shipped in wheels."""

from importlib.metadata import distributions
from pathlib import Path
from shutil import copyfile
import sys


def main():
    destination = Path(sys.argv[1]) / "third-party-notices"
    destination.mkdir(exist_ok=True)
    copyfile(Path(sys.base_prefix) / "LICENSE.txt", destination / "Python-LICENSE.txt")
    for distribution in distributions():
        name = distribution.metadata["Name"]
        for file in distribution.files or ():
            if not any(part.endswith(".dist-info") for part in file.parts):
                continue
            if not file.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE")):
                continue
            source = distribution.locate_file(file)
            if source.is_file():
                copyfile(source, destination / f"{name}-{file.name}")


if __name__ == "__main__":
    main()
