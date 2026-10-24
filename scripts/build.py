#!/usr/bin/env python3
"""Build a distributable Aseprite extension archive."""

from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "dist" / "Palette-Trio.aseprite-extension"
FILES = [
    Path("package.json"),
    Path("LICENSE"),
    Path("main.lua"),
    Path("src/color.lua"),
    Path("src/model.lua"),
    Path("src/persistence.lua"),
    Path("src/aseprite.lua"),
    Path("src/source.lua"),
    Path("src/session.lua"),
    Path("src/grid.lua"),
    Path("src/ui.lua"),
    Path("src/dialogs.lua"),
    Path("src/menu.lua"),
    Path("src/about.lua"),
    Path("src/light_engine.lua"),
    Path("src/light_aseprite.lua"),
    Path("src/light_view.lua"),
    Path("src/light_widgets.lua"),
    Path("src/light_job.lua"),
    Path("src/light_ui.lua"),
]


def check_version() -> None:
    """The About dialog's version lives in code; it must match package.json."""
    import json
    import re

    manifest = json.loads((ROOT / "package.json").read_text())["version"]
    about = (ROOT / "src" / "about.lua").read_text()
    match = re.search(r'About\.VERSION\s*=\s*"([^"]+)"', about)
    if not match or match.group(1) != manifest:
        raise SystemExit(
            f"Version mismatch: package.json is {manifest}, "
            f"src/about.lua has {match.group(1) if match else 'none'}"
        )


def main() -> None:
    check_version()
    listed = {p.as_posix() for p in FILES}
    missing = sorted(
        p.relative_to(ROOT).as_posix()
        for p in (ROOT / "src").glob("*.lua")
        if p.relative_to(ROOT).as_posix() not in listed
    )
    if missing:
        raise SystemExit(f"Source files missing from FILES: {missing}")
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(OUTPUT, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for relative_path in FILES:
            archive.write(ROOT / relative_path, relative_path.as_posix())
    print(f"Built {OUTPUT}")


if __name__ == "__main__":
    main()
