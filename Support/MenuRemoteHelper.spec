# Build a nested macOS bundle so code and data follow Apple's signing layout.
import os
from pathlib import Path

from PyInstaller.utils.hooks import collect_submodules, copy_metadata

root = Path(SPECPATH).parent
analysis = Analysis(
    [str(root / "Sources/MenuRemote/Resources/atv_bridge.py")],
    datas=copy_metadata("pyatv", recursive=True),
    hiddenimports=collect_submodules("pyatv") + collect_submodules("zeroconf"),
)
pyz = PYZ(analysis.pure)
executable = EXE(
    pyz, analysis.scripts, [("u", None, "OPTION")],
    exclude_binaries=True, name="MenuRemoteHelper", console=True,
    target_arch="arm64", codesign_identity=os.environ.get("MENU_REMOTE_CODESIGN_IDENTITY") or None,
)
collection = COLLECT(executable, analysis.binaries, analysis.datas, name="MenuRemoteHelper")
app = BUNDLE(
    collection, name="MenuRemoteHelper.app",
    bundle_identifier="com.nickkjolsing.menuremote.helper",
    info_plist={
        "LSUIElement": True,
        "LSMinimumSystemVersion": "14.0",
        "NSLocalNetworkUsageDescription": "MenuRemote connects to your Apple TV over the local network.",
    },
)
