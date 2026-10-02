"""Private POSIX process groups: cleanup on normal exit as well as failure."""
import os
import signal
import subprocess


def finish_owned_group(child):
    # Each caller launches this child with start_new_session=True. Even a
    # successful leader may leave workers alive, so always stop the owned PG.
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    # Permission/errors propagate: never report cleanup as successful.
    return child.wait(timeout=10)
