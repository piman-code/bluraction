"""Entry point used by the native Windows packager."""
if __name__ == '__main__':
    import multiprocessing

    # PyInstaller dispatches spawned workers before importing Qt/application code.
    multiprocessing.freeze_support()

    import sys

    if sys.argv[1:2] == ['--candidate-smoke']:
        from platforms.windows.bluraction.candidate_smoke import main

        raise SystemExit(main(sys.argv[2:]))

    from platforms.windows.bluraction.__main__ import main

    raise SystemExit(main())
