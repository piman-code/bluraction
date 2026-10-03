"""Run from the repository root: python -m platforms.windows.bluraction."""
import multiprocessing

# Frozen child dispatch must run before Qt/application imports.
if __name__ == '__main__':
    multiprocessing.freeze_support()

from pathlib import Path
import sys

from PySide6.QtWidgets import QApplication

from .ui import BlurActionWindow


def main(argv=None):
    argv = sys.argv if argv is None else argv
    app = QApplication(argv)
    app.setApplicationName('BlurAction')
    app.setOrganizationName('BlurAction')
    window = BlurActionWindow()
    window.show()
    if len(argv) > 1:
        paths = [Path(path) for path in argv[1:]]
        if len(paths) == 1 and paths[0].suffix.lower() == '.bluraction':
            window.open_project(paths[0])
        else:
            window.open_paths(paths)
    return app.exec()


if __name__ == '__main__':
    raise SystemExit(main())
