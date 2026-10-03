"""Entry point used by the native Windows packager."""
if __name__ == '__main__':
    import multiprocessing

    # PyInstaller dispatches spawned workers before importing Qt/application code.
    multiprocessing.freeze_support()

    from platforms.windows.bluraction.__main__ import main

    raise SystemExit(main())
