#!/usr/bin/env python3
"""Round 3 probe.

Round 2 turned up the key finding:

    accctrl?type=req_acc&value=<APP_UUID>&value2=Sciens&value3=clear
        -> ok,S5D-FB94FA,remote,encrypted

A bare `ok` (not `ok_under_research_no_msg`!), meaning the camera
has fully accepted us. `value3=clear` very likely tells the camera
"I want cleartext communication." This script verifies the
hypothesis by:

  1. Issuing accctrl with value3=clear.
  2. Immediately trying the full PR-3 connect sequence:
     getstate, setsetting/device_name, recmode, getinfo/allmenu.
  3. As a bonus: startstream + open a UDP listener and see if
     datagrams arrive.
  4. Polite goodbye: stopstream + playmode.

If steps 2–3 succeed, we know the fix and can amend PR 3 / capture
the fixture for real.
"""
import socket
import sys
import urllib.request
from urllib.parse import quote

CAMERA_IP = "192.168.54.1"
CAMERA = f"http://{CAMERA_IP}"
DEVICE_NAME = "Sciens"
APP_UUID = "4D454900-1C3C-C912-CE00-FEE1FACE0001"
UDP_PORT = 49199
N_FRAMES = 5
TIMEOUT = 5.0
CAPTURE_TIMEOUT = 10.0


def http(url, label=""):
    print(f"[{label}]")
    print(f"  GET {url}")
    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT) as r:
            body = r.read().decode("utf-8", errors="replace").strip()
            short = body if len(body) <= 250 else body[:250] + "..."
            print(f"  -> {short}")
            return body
    except Exception as e:
        print(f"  -> ERROR: {e}")
        return None


def section(t):
    print()
    print("=" * 70)
    print(t)
    print("=" * 70)


def main(out_dir):
    section("1. accctrl with value3=clear")
    body = http(
        f"{CAMERA}/cam.cgi?mode=accctrl&type=req_acc"
        f"&value={APP_UUID}&value2={DEVICE_NAME}&value3=clear",
        label="req_acc + value3=clear",
    )
    if body is None or not body.startswith("ok"):
        print(f"FATAL: accctrl didn't accept us cleanly: {body}")
        return 1
    fields = body.split(",")
    print(f"  ok-prefix confirmed; fields: {fields}")

    section("2. PR-3 connect sequence — does it work now?")
    g = http(f"{CAMERA}/cam.cgi?mode=getstate", label="getstate")
    if g and ("err_reject" in g or "err_param" in g or "err_critical" in g):
        print("  getstate STILL fails — `value3=clear` alone isn't enough.")
    else:
        print("  getstate succeeded — value3=clear is the fix.")
    http(
        f"{CAMERA}/cam.cgi?mode=setsetting&type=device_name"
        f"&value={quote(DEVICE_NAME)}",
        label="setsetting device_name",
    )
    rec = http(f"{CAMERA}/cam.cgi?mode=camcmd&value=recmode",
               label="camcmd recmode")
    if rec and "ok" in rec:
        print("  recmode OK")
    http(f"{CAMERA}/cam.cgi?mode=getinfo&type=allmenu&size=1",
         label="getinfo allmenu (size=1 -- just confirm it responds)")

    section("3. startstream + capture")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 22)
    sock.bind(("0.0.0.0", UDP_PORT))
    sock.settimeout(CAPTURE_TIMEOUT)
    http(f"{CAMERA}/cam.cgi?mode=startstream&value={UDP_PORT}",
         label="startstream")
    captured = []
    try:
        for i in range(N_FRAMES):
            data, addr = sock.recvfrom(65535)
            fname = f"{out_dir}/mjpeg_frame_{i+1:02d}.bin"
            with open(fname, "wb") as f:
                f.write(data)
            print(f"     {fname}: {len(data)} bytes from {addr[0]}")
            captured.append(fname)
    except socket.timeout:
        print(f"     TIMEOUT after {len(captured)} datagrams")
    finally:
        sock.close()

    section("4. polite goodbye")
    http(f"{CAMERA}/cam.cgi?mode=stopstream", label="stopstream")
    http(f"{CAMERA}/cam.cgi?mode=camcmd&value=playmode", label="playmode")

    section("Result")
    print(f"Captured {len(captured)} datagram(s).")
    return 0 if captured else 2


if __name__ == "__main__":
    default_out = "test/fixtures/lumix"
    out = sys.argv[1] if len(sys.argv) > 1 else default_out
    sys.exit(main(out))
