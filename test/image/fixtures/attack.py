#!/usr/bin/env python3
"""Cross-account isolation attacks for test/image/isolation.test.sh (spec section 6).

Runs inside the image's venv python so pyzmq / jupyter_client / requests are
importable. Every subcommand is driven by isolation.test.sh:

  poll     run as alice, before bob logs in: sample every /proc/*/cmdline about
           every 1 ms and record whether bob's Jupyter token ever leaked into an
           argument vector, until a stop file appears. Writes a JSON verdict.
  setup    run as bob: start one kernel in bob's own server (reading bob's token
           from his server's environ, the port from his jpserver file) so a
           kernel and a 0600 connection file exist, and copy the token to a file
           for the poller. Prints the connection-file path and the HTTP port.
  control  run as bob: positive control. Send a correctly signed execute_request
           to bob's own kernel that creates a marker file, proving the payload
           used by the unsigned attack below would run if a kernel accepted it.
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
import socket
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
    with open(args.tokenfile, "w") as fh:
        fh.write(token)
    os.chmod(args.tokenfile, 0o644)  # the poller runs as alice and must read it
    print("%s\t%d" % (connfile, port))
    return 0


def cmd_control(args):
    from jupyter_client import BlockingKernelClient
    kc = BlockingKernelClient()
    kc.load_connection_file(args.connfile)
    kc.start_channels()
    kc.wait_for_ready(timeout=30)
    code = "open(%r, 'w').close()" % args.touch
    kc.execute(code)
    time.sleep(3)
    kc.stop_channels()
    return 0 if os.path.exists(args.touch) else 1


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


def send_unsigned_execute(port, code):
    """Send an unsigned execute_request to a kernel shell/control port.

    An empty signing key makes jupyter_client send an empty HMAC signature; a
    kernel that has a real key rejects the frame, so the code never runs. Falls
    back to hand-rolled ZMQ framing only if pyzmq is unavailable (it is not)."""
    content = {"code": code, "silent": True, "store_history": False,
               "user_expressions": {}, "allow_stdin": False}
    try:
        import zmq
        from jupyter_client.session import Session
        ctx = zmq.Context.instance()
        sess = Session(key=b"")  # empty key -> unsigned
        sock = ctx.socket(zmq.DEALER)
        sock.linger = 0
        sock.connect("tcp://127.0.0.1:%d" % port)
        sess.send(sock, "execute_request", content=content)
        sock.close()
    except ImportError:
        _raw_unsigned_execute(port, content)


def _raw_unsigned_execute(port, content):
    import uuid
    import struct
    header = {"msg_id": uuid.uuid4().hex, "msg_type": "execute_request",
              "username": "x", "session": uuid.uuid4().hex, "version": "5.3"}
    frames = [b"<IDS|MSG>", b"",
              json.dumps(header).encode(), b"{}", b"{}",
              json.dumps(content).encode()]
    sock = socket.create_connection(("127.0.0.1", port), timeout=3)
    # Minimal ZMTP 3.0 NULL handshake for a DEALER peer, then one message.
    # Best-effort only: pyzmq is always importable here, so this path is never
    # taken; it exists so the unsigned attack still has a shot without pyzmq.
    sock.sendall(b"\xff" + b"\x00" * 8 + b"\x7f\x03\x00")  # signature + version
    sock.sendall(b"NULL" + b"\x00" * 16)
    sock.recv(64)
    cmd_body = b"\x05READY\x0bSocket-Type\x00\x00\x00\x06DEALER"
    sock.sendall(struct.pack("!BB", 0x04, len(cmd_body)) + cmd_body)
    for i, fr in enumerate(frames):
        flag = 0x01 if i < len(frames) - 1 else 0x00
        if len(fr) < 256:
            sock.sendall(struct.pack("!BB", flag, len(fr)) + fr)
        else:
            sock.sendall(struct.pack("!BQ", flag | 0x02, len(fr)) + fr)
    sock.close()


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

    # Row: read B's runtime dir / connection file
    try:
        open(args.connfile, "rb").read()
        record("connfile", False, "connection file was readable")
    except (PermissionError, FileNotFoundError) as e:
        hits = glob.glob("/home/bob/.local/share/jupyter/runtime/kernel-*.json")
        record("connfile", True, "%s; glob=%r" % (type(e).__name__, hits))
    except Exception as e:  # noqa: BLE001
        record("connfile", False, "unexpected %s: %s" % (type(e).__name__, e))

    # Row: connect B's kernel ZMQ ports without an HMAC signature
    try:
        os.remove(args.pwned)
    except OSError:
        pass
    ports = bob_listen_ports(args.bob_uid)
    zmq_ports = [p for p in ports if not is_http(p)]
    for p in zmq_ports:
        try:
            send_unsigned_execute(p, "open(%r, 'w').close()" % args.pwned)
        except Exception:  # noqa: BLE001
            pass
    time.sleep(5)
    pwned = os.path.exists(args.pwned)
    record("kernel_zmq", not pwned,
           "ports=%s zmq=%s %s exists=%s" % (ports, zmq_ports, args.pwned, pwned))

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
    sp.add_argument("--connfile", required=True)
    sp.add_argument("--pwned", required=True)
    sp.add_argument("--pwned-control", required=True)
    sp.set_defaults(func=cmd_attack)

    args = p.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
