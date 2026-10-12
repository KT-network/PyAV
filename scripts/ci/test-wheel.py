"""Run the repository's tests against the installed wheel, not the source tree."""

import ast
import os
import sys
import unittest
from pathlib import Path


def main():
    project = Path(sys.argv[1]).resolve()
    if sys.version_info[:2] != (3, 8):
        raise RuntimeError("Wheel tests must use CPython 3.8")

    import av

    installed = Path(av.__file__).resolve()
    if project == installed or project in installed.parents:
        raise RuntimeError(
            f"Tests imported the source tree instead of the wheel: {installed}"
        )

    metadata = ast.parse((project / "av" / "about.py").read_text(encoding="utf-8"))
    expected_version = ast.literal_eval(metadata.body[0].value)
    if av.__version__ != expected_version:
        raise RuntimeError(f"Installed version {av.__version__} != {expected_version}")
    print(f"Testing PyAV {av.__version__} from {installed}", flush=True)

    # Cache downloaded test assets in the checkout on hosted runners.
    os.environ["PYAV_TESTDATA_DIR"] = str(project / "tests" / "assets")
    suite = unittest.defaultTestLoader.discover(
        start_dir=str(project / "tests"), top_level_dir=str(project)
    )
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
