#!/usr/bin/env python3
"""Capture raw Lumix MJPEG-over-UDP datagrams for test fixtures.

Bench-only. Run AFTER joining the workstation to the camera's WiFi
AP (LUMIX-XXXXXX). Uses the encrypted-session handshake required by
hardened firmware (Wi-Fi Password mandatorily enabled), as
reverse-engineered by njfdev/liblumix:

  1. Fetch UPnP descriptor (port 60606) → extract <UDN>, strip
     the `uuid:` prefix.
  2. accctrl?type=req_acc_g (grant probe).
  3. Loop accctrl?type=req_acc_e&value=<hex(UDN)>&value2=<hex(name)>
     until the response's first comma-separated field starts with
     `ok`. The LAST comma-separated field is the session ID.
  4. All subsequent requests carry header `X-SESSION_ID: <id>`.
  5. setsetting?type=device_name (affirm display name).
  6. camcmd?value=recmode.
  7. Open UDP listener on 49199.
  8. startstream → capture N raw datagrams to
     test/fixtures/lumix/mjpeg_frame_NN.bin.
  9. stopstream + camcmd?value=playmode (polite goodbye).

Output dir defaults to the conventional fixtures dir; override
with the first positional arg.

Re-runnable: each invocation overwrites any prior mjpeg_frame_NN.bin
files in the output dir.
"""
import re
import socket
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
from urllib.parse import quote

CAMERA_IP = "192.168.54.1"
CAMERA = f"http://{CAMERA_IP}"
UPNP_PORT = 60606
UPNP_DESCRIPTOR_PATH = "/Lumix/Server0/ddd"
DEVICE_NAME = "Sciens"
UDP_PORT = 49199
N_FRAMES = 5
HTTP_TIMEOUT = 5.0
ACCCTRL_POLL_INTERVAL = 0.5
ACCCTRL_MAX_ATTEMPTS = 120  # 60s of polling
CAPTURE_TIMEOUT = 10.0


def hex_lower(s: str) -> str:
    """Lowercase hex encoding of UTF-8 bytes — matches liblumix's
    hex_lower::encode."""
    return s.encode("utf-8").hex()


def http(url: str, headers=None, timeout: float = HTTP_TIMEOUT):
    """Issue a GET and print + return the decoded body. Returns None
    on network/parse error (failure printed)."""
    print(f"  GET {url}")
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read().decode("utf-8", errors="replace").strip()
            print(f"     -> {body[:200]}")
            return body
    except Exception as e:
        print(f"     -> ERROR: {e}")
        return None


def parse_udn(descriptor_xml: str) -> str | None:
    """Find <UDN> in the UPnP descriptor and strip the `uuid:` prefix.
    Tries namespaced first, falls back to a regex if the descriptor
    isn't in the standard urn:schemas-upnp-org:device-1-0 namespace."""
    try:
        root = ET.fromstring(descriptor_xml)
    except ET.ParseError:
        return None
    ns = {"u": "urn:schemas-upnp-org:device-1-0"}
    elt = root.find(".//u:UDN", ns) or root.find(".//UDN")
    if elt is None or not elt.text:
        m = re.search(r"<UDN>([^<]+)</UDN>", descriptor_xml)
        if not m:
            return None
        raw = m.group(1).strip()
    else:
        raw = elt.text.strip()
    return raw[5:] if raw.lower().startswith("uuid:") else raw


def first_field_is_ok(csv_body: str) -> bool:
    """Tolerant: accept any first field starting with `ok` (covers
    bare `ok` and S5/S5D's `ok_under_research_no_msg`)."""
    return csv_body.split(",", 1)[0].startswith("ok")


def main(out_dir):
    print("=== Lumix MJPEG fixture capture (encrypted handshake) ===")
    print(f"Output dir: {out_dir}")
    print()

    print("Step 1: fetch UPnP descriptor")
    desc = http(f"http://{CAMERA_IP}:{UPNP_PORT}{UPNP_DESCRIPTOR_PATH}")
    if not desc:
        print("FATAL: UPnP descriptor unreachable. Is the workstation on the camera's WiFi?")
        return 1
    udn = parse_udn(desc)
    if not udn:
        print("FATAL: couldn't extract <UDN> from descriptor.")
        return 1
    print(f"  UDN (after stripping 'uuid:'): {udn}")
    udn_hex = hex_lower(udn)
    name_hex = hex_lower(DEVICE_NAME)
    print(f"  UDN hex: {udn_hex}")
    print(f"  Name hex: {name_hex}")

    print("Step 2: accctrl req_acc_g (grant probe)")
    http(f"{CAMERA}/cam.cgi?mode=accctrl&type=req_acc_g")

    print(f"Step 3: accctrl req_acc_e (poll up to "
          f"{int(ACCCTRL_POLL_INTERVAL * ACCCTRL_MAX_ATTEMPTS)}s)")
    session_id = None
    for attempt in range(1, ACCCTRL_MAX_ATTEMPTS + 1):
        body = http(
            f"{CAMERA}/cam.cgi?mode=accctrl&type=req_acc_e"
            f"&value={udn_hex}&value2={name_hex}"
        )
        if body is None:
            return 1
        if first_field_is_ok(body):
            session_id = body.rsplit(",", 1)[-1].strip()
            print(f"  session established on attempt {attempt}")
            print(f"  session_id: {session_id}")
            break
        time.sleep(ACCCTRL_POLL_INTERVAL)
    if not session_id:
        print("FATAL: req_acc_e never returned an ok response. "
              "Is another device controlling the camera?")
        return 1

    auth = {"X-SESSION_ID": session_id}

    print("Step 4: setsetting device_name (affirm)")
    http(
        f"{CAMERA}/cam.cgi?mode=setsetting&type=device_name"
        f"&value={quote(DEVICE_NAME)}",
        headers=auth,
    )

    print("Step 5: getstate (sanity check)")
    http(f"{CAMERA}/cam.cgi?mode=getstate", headers=auth)

    print("Step 6: camcmd=recmode")
    http(f"{CAMERA}/cam.cgi?mode=camcmd&value=recmode", headers=auth)

    print(f"Step 7: open UDP listener on port {UDP_PORT}")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 22)
    sock.bind(("0.0.0.0", UDP_PORT))
    sock.settimeout(CAPTURE_TIMEOUT)

    print(f"Step 8: startstream value={UDP_PORT}")
    http(
        f"{CAMERA}/cam.cgi?mode=startstream&value={UDP_PORT}",
        headers=auth,
    )

    print(f"Step 9: capture {N_FRAMES} datagrams (timeout {CAPTURE_TIMEOUT}s)")
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

    print("Step 10: stopstream + polite goodbye")
    http(f"{CAMERA}/cam.cgi?mode=stopstream", headers=auth)
    http(f"{CAMERA}/cam.cgi?mode=camcmd&value=playmode", headers=auth)

    print()
    print(f"=== Done. Captured {len(captured)} datagram(s) ===")
    for f in captured:
        print(f"  {f}")
    return 0 if captured else 2


if __name__ == "__main__":
    default_out = "test/fixtures/lumix"
    out = sys.argv[1] if len(sys.argv) > 1 else default_out
    sys.exit(main(out))
