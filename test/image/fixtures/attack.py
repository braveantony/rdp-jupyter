#!/usr/bin/env python3
"""Cross-account isolation attacks for test/image/isolation.test.sh (spec section 6).

Runs inside the image's venv python so pyzmq / jupyter_client / requests are
importable. Every subcommand is driven by isolation.test.sh:

  poll     run as alice, before bob logs in: sample every /proc/*/cmdline about
           every 1 ms and record whether bob's Jupyter token ever leaked into an
           argument vector, until a stop file appears. Writes a JSON verdict.
  token    run as bob, as soon as the server exists: copy bob's token to a file
           the poller reads, so its token-value match also covers the login
           window (not only the post-kernel window).
  setup    run as bob: start one kernel in bob's own server (reading bob's token
           from his server's environ, the port from his jpserver file) so a
           kernel and a 0600 connection file exist, and copy the token to a file
           for the poller. Prints the connection-file path and the HTTP port.
  control  run as bob: delivery positive control. Send a correctly signed
           execute_request to bob's kernel over the SAME DEALER path the unsigned
           attack uses (HMAC key from bob's connection file) and confirm it
           creates a marker, so the unsigned attack's frame is proven to reach
           the kernel and its failure is attributable to the missing signature.
  attack   run as alice: every isolation check from the threat-model table, one
           RESULT line each for isolation.test.sh to turn into a pass/bad line.

Only the attack and poll steps run as alice; the setup and control steps are
legitimate actions bob performs on his own session.
"""
import argparse
import ctypes
import errno
import glob
import json
import os
import sys
import time
import urllib.error
import urllib.request

# The token leaked onto a command line would look like the CLI argument D5
# removes (--ServerApp.token=...). Built from pieces so this script's own argv
# never contains the needle it searches for.
NEEDLE = "token" + "="
SERVER_GLOB = "/home/*/.local/share/jupyter/runtime/jpserver-*.json"


def read_cmdline(pid):
    with open("/proc/%s/cmdline" % pid, "rb") as fh:
        return fh.read().replace(b"\0", b" ").decode("utf-8", "replace")


def proc_uid(pid):
    return os.stat("/proc/%s" % pid).st_uid


# ---------------------------------------------------------------------------
# poll: run as alice from before bob's login
# ---------------------------------------------------------------------------
def cmd_poll(args):
    me = str(os.getpid())
    token = ""
    saw_needle = False
    saw_value = False
    saw_server = False
    needle_bytes = NEEDLE.encode()
    deadline = time.monotonic() + args.max_seconds
    while True:
        # Pick up the real token value once the harness has written it, so we
        # can also catch the value itself appearing anywhere, not just NEEDLE.
        if not token:
            try:
                with open(args.tokenfile) as fh:
                    token = fh.read().strip()
            except OSError:
                token = ""
        for path in glob.glob("/proc/[0-9]*/cmdline"):
            pid = path.split("/")[2]
            if pid == me:
                continue
            try:
                with open(path, "rb") as fh:
                    raw = fh.read()
            except OSError:
                continue
            if needle_bytes in raw:
                saw_needle = True
            if token and token.encode() in raw:
                saw_value = True
            text = raw.replace(b"\0", b" ").decode("utf-8", "replace")
            if "-m jupyterlab" in text:
                try:
                    if proc_uid(pid) == args.bob_uid:
                        saw_server = True
                except OSError:
                    pass
        if os.path.exists(args.stopfile) or time.monotonic() > deadline:
            break
        time.sleep(0.001)
    verdict = {
        "saw_needle": saw_needle,
        "saw_value": saw_value,
        "saw_server": saw_server,
        "had_token": bool(token),
    }
    with open(args.out, "w") as fh:
        json.dump(verdict, fh)
    print(json.dumps(verdict))
    return 0


# ---------------------------------------------------------------------------
# setup / control: run as bob on his own session
# ---------------------------------------------------------------------------
def bob_token_and_port(server_pid):
    env = {}
    with open("/proc/%s/environ" % server_pid, "rb") as fh:
        for kv in fh.read().decode("utf-8", "replace").split("\0"):
            if "=" in kv:
                k, v = kv.split("=", 1)
                env[k] = v
    jp = sorted(glob.glob(SERVER_GLOB))
    port = json.load(open(jp[0]))["port"] if jp else None
    return env.get("JUPYTER_TOKEN"), port


def cmd_setup(args):
    # The server writes its jpserver-*.json a moment after it starts, so give
    # the port time to appear.
    token = port = None
    end = time.monotonic() + 30
    while time.monotonic() < end:
        token, port = bob_token_and_port(args.server_pid)
        if token and port:
            break
        time.sleep(0.5)
    if not token or not port:
        print("setup: could not read bob's token/port (token=%s port=%s)"
              % (bool(token), port), file=sys.stderr)
        return 1
    req = urllib.request.Request(
        "http://127.0.0.1:%d/api/kernels" % port,
        data=b"{}",
        method="POST",
        headers={"Authorization": "token %s" % token,
                 "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        resp.read()
    # Wait for the kernel's 0600 connection file to land in bob's runtime dir.
    runtime = os.path.dirname(sorted(glob.glob(SERVER_GLOB))[0])
    pattern = os.path.join(runtime, "kernel-*.json")
    connfile = ""
    end = time.monotonic() + 30
    while time.monotonic() < end:
        hits = sorted(glob.glob(pattern))
        if hits:
            connfile = hits[0]
            break
        time.sleep(0.2)
    if not connfile:
        print("setup: kernel connection file never appeared", file=sys.stderr)
        return 1
    # Confirm the kernel is ready to service shell requests with a kernel_info
    # handshake, so the signed control and the unsigned attack both hit a kernel
    # that can execute. (REST execution_state stays "starting" until a channel
    # client connects, so a handshake is the reliable readiness signal. This
    # BlockingKernelClient is only used to wait here; the attack and its
    # positive control both go through the raw DEALER path in _dealer_send.)
    from jupyter_client import BlockingKernelClient
    kc = BlockingKernelClient()
    kc.load_connection_file(connfile)
    kc.start_channels()
    try:
        kc.wait_for_ready(timeout=60)
    except RuntimeError:
        print("setup: kernel never became ready", file=sys.stderr)
        return 1
    finally:
        kc.stop_channels()
    with open(args.tokenfile, "w") as fh:
        fh.write(token)
    os.chmod(args.tokenfile, 0o644)  # the poller runs as alice and must read it
    print("%s\t%d" % (connfile, port))
    return 0


def cmd_token(args):
    """Copy bob's token to a file the alice poller can read, as early as the
    server exists, so the poller's token-value match covers the login window
    too, not only the post-kernel window."""
    token, _ = bob_token_and_port(args.server_pid)
    if not token:
        print("token: could not read bob's token", file=sys.stderr)
        return 1
    with open(args.tokenfile, "w") as fh:
        fh.write(token)
    os.chmod(args.tokenfile, 0o644)
    return 0


def cmd_control(args):
    """Delivery positive control: send a correctly SIGNED execute_request to
    bob's kernel over the SAME DEALER path the unsigned attack uses, with the
    HMAC key read from bob's connection file. If this creates the marker, the
    raw transport demonstrably reaches and runs code in the kernel, so the
    unsigned attack failing to create its marker is attributable to the missing
    signature, not to a frame that never arrived. Run as bob."""
    conn = json.load(open(args.connfile))
    key = conn["key"].encode()
    port = conn["shell_port"]
    code = "open(%r, 'w').close()" % args.touch
    # setup already waited for the kernel to be ready; send the signed frame,
    # then give the kernel a moment to run it before checking the marker.
    end = time.monotonic() + 30
    delivered = False
    while time.monotonic() < end:
        delivered = _dealer_send(port, code, key)
        for _ in range(25):  # up to ~5 s for the kernel to execute
            if os.path.exists(args.touch):
                print("control: signed frame delivered to shell port %d, "
                      "marker created" % port)
                return 0
            time.sleep(0.2)
    print("control: delivered=%s touched=%s" % (delivered,
          os.path.exists(args.touch)), file=sys.stderr)
    return 1


# ---------------------------------------------------------------------------
# attack: run as alice
# ---------------------------------------------------------------------------
def bob_listen_ports(uid):
    ports = set()
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            lines = open(path).read().splitlines()[1:]
        except OSError:
            continue
        for ln in lines:
            f = ln.split()
            if len(f) > 7 and f[3] == "0A" and int(f[7]) == uid:
                ports.add(int(f[1].split(":")[1], 16))
    return sorted(ports)


def is_http(port):
    try:
        urllib.request.urlopen("http://127.0.0.1:%d/api" % port, timeout=3).read()
        return True
    except urllib.error.HTTPError:
        return True
    except Exception:
        return False


HANDSHAKE_TIMEOUT_MS = 3000


def _dealer_send(port, code, key):
    """Send one execute_request to a kernel ZMQ port over a DEALER socket and
    prove the frame actually reaches the peer. key=b"" signs with an empty HMAC
    (an unsigned request a keyed kernel rejects); a real key signs correctly.

    Returns True when the ZMTP handshake with the peer completed, i.e. the peer
    is a live kernel ROUTER and the frame was delivered to it; False when no
    handshake completed within the timeout (the port is not a kernel ZMQ
    socket). Delivery is made observable, not assumed:
      * wait on the socket monitor for EVENT_HANDSHAKE_SUCCEEDED before sending,
      * poll POLLOUT so the frame can be queued,
      * set LINGER>0 so close() blocks until libzmq has flushed the frame to
        the peer rather than discarding it (the LINGER=0 bug this replaces).
    Unexpected socket errors propagate; the caller must not treat a failed send
    as a blocked attack. Requires pyzmq, which the image's venv always has."""
    import zmq
    from jupyter_client.session import Session
    from zmq.utils.monitor import recv_monitor_message
    content = {"code": code, "silent": True, "store_history": False,
               "user_expressions": {}, "allow_stdin": False}
    # A fresh context per call: the monitor socket uses an inproc endpoint, and
    # reusing the shared Context.instance() across a loop of sends leaks those
    # and raises EADDRINUSE. ctx.term() below also blocks until LINGER flushes.
    ctx = zmq.Context()
    try:
        sock = ctx.socket(zmq.DEALER)
        mon = sock.get_monitor_socket()  # must be taken before connect
        sock.connect("tcp://127.0.0.1:%d" % port)
        handshook = False
        end = time.monotonic() + HANDSHAKE_TIMEOUT_MS / 1000.0
        while time.monotonic() < end:
            if mon.poll(100):
                evt = recv_monitor_message(mon)
                if evt["event"] == zmq.EVENT_HANDSHAKE_SUCCEEDED:
                    handshook = True
                    break
        if not handshook:
            sock.setsockopt(zmq.LINGER, 0)
            sock.close()
            mon.close()
            return False
        if not sock.poll(HANDSHAKE_TIMEOUT_MS, zmq.POLLOUT):
            sock.setsockopt(zmq.LINGER, 0)
            sock.close()
            mon.close()
            raise RuntimeError("port %d handshook but never became writable"
                               % port)
        Session(key=key).send(sock, "execute_request", content=content)
        sock.setsockopt(zmq.LINGER, 5000)  # flush the frame to the peer
        sock.close()                        # drains it (LINGER), then term waits
        mon.close()
        return True
    finally:
        ctx.term()


def cmd_attack(args):
    results = []

    def record(key, ok, detail):
        results.append((key, ok, detail))

    # Row: read B's /proc/<pid>/environ
    try:
        open("/proc/%s/environ" % args.server_pid, "rb").read()
        record("environ", False, "environ was readable")
    except PermissionError as e:
        record("environ", True, "PermissionError: %s" % e)
    except Exception as e:  # noqa: BLE001
        record("environ", False, "unexpected %s: %s" % (type(e).__name__, e))

    # Row: connect B's Jupyter server without a token
    code = None
    try:
        urllib.request.urlopen(
            "http://127.0.0.1:%d/api/kernels" % args.http_port, timeout=5).read()
    except urllib.error.HTTPError as e:
        code = e.code
    except Exception as e:  # noqa: BLE001
        record("api_kernels", False, "unexpected %s: %s" % (type(e).__name__, e))
    if code is not None:
        record("api_kernels", code == 403, "GET /api/kernels -> %s" % code)

    # Row: read B's runtime dir / connection file. Only EACCES proves isolation
    # (the file exists but 0700 traversal denies it); a not-found would be a
    # vacuous pass, so it fails loudly instead.
    hits = glob.glob("/home/bob/.local/share/jupyter/runtime/kernel-*.json")
    try:
        open(args.connfile, "rb").read()
        record("connfile", False, "connection file %s was readable" % args.connfile)
    except PermissionError as e:
        record("connfile", True, "PermissionError on %s; alice glob=%r"
               % (args.connfile, hits))
    except FileNotFoundError as e:
        record("connfile", False,
               "FileNotFoundError on %s (wrong path, vacuous): %s"
               % (args.connfile, e))
    except Exception as e:  # noqa: BLE001
        record("connfile", False, "unexpected %s: %s" % (type(e).__name__, e))

    # Row: connect B's kernel ZMQ ports without an HMAC signature
    try:
        os.remove(args.pwned)
    except OSError:
        pass
    ports = bob_listen_ports(args.bob_uid)
    zmq_ports = [p for p in ports if not is_http(p)]
    code = "open(%r, 'w').close()" % args.pwned
    shell = args.shell_port
    if shell not in zmq_ports:
        zmq_ports.append(shell)  # ensure the kernel's shell ROUTER is targeted
    delivered = []       # ports whose ZMTP handshake completed (frame delivered)
    errors = []          # send failures: recorded, never silently ignored
    shell_delivered = False
    shell_error = None
    for p in zmq_ports:
        try:
            d = _dealer_send(p, code, b"")
            if d:
                delivered.append(p)
            if p == shell:
                shell_delivered = d
        except Exception as e:  # noqa: BLE001
            errors.append("%d:%s:%s" % (p, type(e).__name__, e))
            if p == shell:
                shell_error = "%s: %s" % (type(e).__name__, e)
    time.sleep(5)
    pwned = os.path.exists(args.pwned)
    # Pass only if the unsigned frame was actually delivered to the kernel's
    # shell ROUTER (handshake proven, no send error) and still no code ran.
    # Delivery-without-execution is what proves the HMAC check rejected it; the
    # control row sends through this same path WITH a valid signature and does
    # create its marker, isolating the signature as the only difference.
    record("kernel_zmq",
           (not pwned) and shell_delivered and shell_error is None,
           "shell_port=%d shell_delivered=%s shell_error=%s "
           "all_delivered=%s other_errors=%s %s exists=%s"
           % (shell, shell_delivered, shell_error, delivered,
              [e for e in errors if not e.startswith("%d:" % shell)],
              args.pwned, pwned))

    # Row: read B's home dir
    try:
        os.listdir("/home/bob")
        record("home", False, "/home/bob was listable")
    except PermissionError as e:
        record("home", True, "PermissionError: %s" % e)
    except Exception as e:  # noqa: BLE001
        record("home", False, "unexpected %s: %s" % (type(e).__name__, e))

    # Row: read B's per-session dir $S (/tmp/sess/<display>.<bob uid>)
    sess_dirs = glob.glob("/tmp/sess/*.%d" % args.bob_uid)
    ok = bool(sess_dirs)
    detail = "dirs=%r" % sess_dirs
    for d in sess_dirs:
        try:
            os.listdir(d)
            ok = False
            detail = "%s was listable" % d
        except PermissionError as e:
            detail = "PermissionError: %s" % e
        except Exception as e:  # noqa: BLE001
            ok = False
            detail = "unexpected %s: %s" % (type(e).__name__, e)
    record("sess", ok, detail)

    # Row: rewrite the shared venv / extra dir
    for key, path in (("write_venv", "/opt/jupyter/venv/lib/pwn"),
                      ("write_extra", "/opt/jupyter/extra/pwn")):
        try:
            open(path, "w").close()
            os.remove(path)
            record(key, False, "%s was writable" % path)
        except PermissionError as e:
            record(key, True, "PermissionError: %s" % e)
        except Exception as e:  # noqa: BLE001
            record(key, False, "unexpected %s: %s" % (type(e).__name__, e))

    # Row: ptrace B's process
    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    PTRACE_ATTACH = 16
    ctypes.set_errno(0)
    ret = libc.ptrace(PTRACE_ATTACH, int(args.server_pid), 0, 0)
    err = ctypes.get_errno()
    if ret == 0:
        libc.ptrace(17, int(args.server_pid), 0, 0)  # PTRACE_DETACH, undo
    scope = "?"
    try:
        scope = open("/proc/sys/kernel/yama/ptrace_scope").read().strip()
    except OSError:
        pass
    record("ptrace", ret == -1 and err == errno.EPERM,
           "ret=%d errno=%s ptrace_scope=%s"
           % (ret, errno.errorcode.get(err, err), scope))

    # Positive control: the signed request did create its marker.
    record("control", os.path.exists(args.pwned_control),
           "%s exists=%s" % (args.pwned_control,
                             os.path.exists(args.pwned_control)))

    for key, ok, detail in results:
        print("RESULT\t%s\t%d\t%s" % (key, 1 if ok else 0, detail))
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("poll")
    sp.add_argument("--bob-uid", type=int, required=True)
    sp.add_argument("--tokenfile", required=True)
    sp.add_argument("--stopfile", required=True)
    sp.add_argument("--out", required=True)
    sp.add_argument("--max-seconds", type=int, default=600)
    sp.set_defaults(func=cmd_poll)

    sp = sub.add_parser("token")
    sp.add_argument("--server-pid", required=True)
    sp.add_argument("--tokenfile", required=True)
    sp.set_defaults(func=cmd_token)

    sp = sub.add_parser("setup")
    sp.add_argument("--server-pid", required=True)
    sp.add_argument("--tokenfile", required=True)
    sp.set_defaults(func=cmd_setup)

    sp = sub.add_parser("control")
    sp.add_argument("--connfile", required=True)
    sp.add_argument("--touch", required=True)
    sp.set_defaults(func=cmd_control)

    sp = sub.add_parser("attack")
    sp.add_argument("--bob-uid", type=int, required=True)
    sp.add_argument("--server-pid", required=True)
    sp.add_argument("--http-port", type=int, required=True)
    sp.add_argument("--shell-port", type=int, required=True)
    sp.add_argument("--connfile", required=True)
    sp.add_argument("--pwned", required=True)
    sp.add_argument("--pwned-control", required=True)
    sp.set_defaults(func=cmd_attack)

    args = p.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
