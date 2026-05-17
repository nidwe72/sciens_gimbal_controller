#!/usr/bin/env python3
"""Round 2 probe.

Findings from r1:
  - Legacy `accctrl?type=req_acc&value=<APP_UUID>&value2=Sciens`
    returns `ok_under_research_no_msg,S5D-FB94FA,remote,encrypted`
    on this firmware. The slot IS claimed (a subsequent attempt to
    take the slot with a different identity returns err_others_requesting).
  - All `req_acc_e` variants return err_param — the encrypted-session
    handshake from liblumix doesn't exist on S5D firmware 2.80.
  - getstate/recmode/etc. without further auth return err_reject.

So the slot exists but is in an "encrypted-required" limbo. This
script tries to find the missing auth step by probing:
  A. X-SESSION_ID header values derived from the legacy response.
  B. A few other common HTTP auth header conventions.
  C. accctrl variants with explicit "encryption=off"-style params.
  D. Reachability of the PTP/IP port (15740) for fallback planning.
"""
import socket
import sys
import urllib.request

CAMERA_IP = "192.168.54.1"
CAMERA = f"http://{CAMERA_IP}"
DEVICE_NAME = "Sciens"
APP_UUID = "4D454900-1C3C-C912-CE00-FEE1FACE0001"
TIMEOUT = 5.0


def http(url, headers=None, label=""):
    print(f"[{label}]")
    print(f"  GET {url}")
    if headers:
        print(f"  headers: {headers}")
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
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


def main():
    section("0. Re-claim the slot (legacy req_acc + APP_UUID)")
    body = http(
        f"{CAMERA}/cam.cgi?mode=accctrl&type=req_acc"
        f"&value={APP_UUID}&value2={DEVICE_NAME}",
        label="legacy req_acc",
    )
    if body is None:
        print("FATAL: camera unreachable. Re-verify WiFi.")
        return 1
    if not body.startswith("ok"):
        print(f"FATAL: req_acc didn't return ok-prefixed CSV: {body}")
        return 1
    fields = body.split(",")
    print(f"  response fields: {fields}")
    # Build a list of candidate session IDs from the response fields.
    candidate_sids = [
        ("response[last] (encrypted)", fields[-1]),
        ("response[1] (model)",        fields[1] if len(fields) > 1 else ""),
        ("response[2] (remote)",       fields[2] if len(fields) > 2 else ""),
        ("response[0] (status)",       fields[0]),
        ("APP_UUID",                   APP_UUID),
        ("APP_UUID lowercase",         APP_UUID.lower()),
        ("APP_UUID hex",               APP_UUID.encode().hex()),
        ("full response",              body),
    ]

    section("A. getstate with various X-SESSION_ID header values")
    for label, sid in candidate_sids:
        http(f"{CAMERA}/cam.cgi?mode=getstate",
             headers={"X-SESSION_ID": sid},
             label=f"X-SESSION_ID={label}")

    section("B. getstate with other common auth-style headers")
    for label, hdrs in [
        ("Cookie: SESSION=<resp>",       {"Cookie": f"SESSION={fields[-1]}"}),
        ("Authorization Bearer <resp>",  {"Authorization": f"Bearer {fields[-1]}"}),
        ("X-PANA-SESSION-ID",            {"X-PANA-SESSION-ID": APP_UUID}),
        ("X-Session",                    {"X-Session": fields[-1]}),
        ("X-CAM-SESSION",                {"X-CAM-SESSION": fields[-1]}),
    ]:
        http(f"{CAMERA}/cam.cgi?mode=getstate",
             headers=hdrs, label=label)

    section("C. speculative accctrl variants that might disable encryption")
    for q in [
        "mode=accctrl&type=req_acc_unenc&value=" + APP_UUID + "&value2=" + DEVICE_NAME,
        "mode=accctrl&type=req_acc&value=" + APP_UUID + "&value2=" + DEVICE_NAME + "&value3=clear",
        "mode=accctrl&type=req_acc&value=" + APP_UUID + "&value2=" + DEVICE_NAME + "&encryption=off",
        "mode=setsetting&type=communication_mode&value=plain",
        "mode=getsetting&type=communication_mode",
        "mode=getinfo&type=session",
        "mode=getinfo&type=auth",
        "mode=getinfo&type=allmode",
    ]:
        http(f"{CAMERA}/cam.cgi?{q}", label=q[:60])

    section("D. PTP/IP fallback reachability check (port 15740)")
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(3.0)
        s.connect((CAMERA_IP, 15740))
        s.close()
        print(f"  PTP port 15740 is OPEN — PTP/IP fallback path exists.")
    except Exception as e:
        print(f"  PTP port 15740 unreachable: {e}")

    section("Summary")
    print("Look for any A/B response that's NOT err_reject — that would")
    print("identify the magic header. Look at C for any setting that's")
    print("read back as something other than err_param. D tells us if PTP")
    print("over IP is even an option to fall back to.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
