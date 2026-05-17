#!/usr/bin/env python3
"""Diagnostic: probe the Lumix accctrl handshake with multiple
parameter encodings, to figure out what the hardened-firmware S5D
actually expects.

Run AFTER joining the workstation to the camera's WiFi AP.

Each probe is a single GET — no polling loops. The script prints
the camera's response for each variant so we can see which (if
any) is accepted with a non-err response.

Reads the UPnP descriptor first and prints it in full, so we can
spot Panasonic-specific fields (xmlns:pana="...") we might need.
"""
import sys
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET

CAMERA_IP = "192.168.54.1"
CAMERA = f"http://{CAMERA_IP}"
UPNP_PORT = 60606
UPNP_DESCRIPTOR_PATH = "/Lumix/Server0/ddd"
DEVICE_NAME = "Sciens"
APP_UUID = "4D454900-1C3C-C912-CE00-FEE1FACE0001"
TIMEOUT = 5.0


def hex_lower(s: str) -> str:
    return s.encode("utf-8").hex()


def http(url, headers=None, label=""):
    print(f"[{label}]")
    print(f"  GET {url}")
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


def section(title):
    print()
    print("=" * 70)
    print(title)
    print("=" * 70)


def fetch_descriptor():
    section("0. UPnP descriptor (full body)")
    body = http(
        f"http://{CAMERA_IP}:{UPNP_PORT}{UPNP_DESCRIPTOR_PATH}",
        label="GET descriptor",
    )
    if not body:
        return None
    print()
    print("  --- full descriptor ---")
    for line in body.replace("><", ">\n<").splitlines():
        print(f"  {line}")
    print("  --- end descriptor ---")
    return body


def extract_udn(desc_xml):
    # ElementTree treats leaf elements (no subelements) as falsy in an
    # `or` chain, so we can't rely on `find(...) or find(...)`. Use
    # explicit `is not None` checks, plus a regex fallback for any XML
    # quirks we haven't anticipated.
    import re
    try:
        root = ET.fromstring(desc_xml)
        ns = {"u": "urn:schemas-upnp-org:device-1-0"}
        elt = root.find(".//u:UDN", ns)
        if elt is None:
            elt = root.find(".//UDN")
        if elt is not None and elt.text:
            raw = elt.text.strip()
            return raw[5:] if raw.lower().startswith("uuid:") else raw
    except ET.ParseError as e:
        print(f"  descriptor parse error: {e}; falling back to regex")
    m = re.search(r"<UDN>([^<]+)</UDN>", desc_xml)
    if not m:
        return None
    raw = m.group(1).strip()
    return raw[5:] if raw.lower().startswith("uuid:") else raw


def udn_variants(udn):
    """Return [(label, encoded_value)] candidates for the UDN field."""
    s = udn  # e.g. "4D454930-0100-1000-8000-FE84A7FB94FA"
    lo = s.lower()
    no_dash = s.replace("-", "")
    no_dash_lo = lo.replace("-", "")
    # Raw 16-byte UUID interpretation (parse as UUID, get bytes)
    uuid_bytes_hex = None
    try:
        import uuid as _u
        uuid_bytes_hex = _u.UUID(s).bytes.hex()  # 32 chars, lowercase
    except Exception:
        pass
    variants = [
        ("hex(string-as-is)",           hex_lower(s)),
        ("hex(string-lowercased)",      hex_lower(lo)),
        ("hex(string-no-hyphens)",      hex_lower(no_dash)),
        ("hex(string-lc-no-hyphens)",   hex_lower(no_dash_lo)),
        ("raw string",                   s),
        ("raw lowercase",                lo),
        ("raw no-hyphens",               no_dash),
        ("raw lc no-hyphens",            no_dash_lo),
    ]
    if uuid_bytes_hex is not None:
        variants.append(("uuid.bytes hex (16-byte form)", uuid_bytes_hex))
        variants.append(("uuid.bytes hex uppercase", uuid_bytes_hex.upper()))
    return variants


def probe_accctrl():
    desc = fetch_descriptor()
    if not desc:
        print("\nFATAL: cannot reach camera. Re-verify the workstation is on the LUMIX WiFi AP.")
        return 1
    udn = extract_udn(desc)
    if not udn:
        print("\nFATAL: could not find <UDN> in the descriptor.")
        return 1
    print(f"\nExtracted UDN (uuid: stripped): {udn}")

    section("1. baseline: legacy req_acc (no encryption)")
    # This is the pre-PR-3 form. Should respond with the
    # ok_under_research_no_msg,...,remote,encrypted signature.
    http(
        f"{CAMERA}/cam.cgi?mode=accctrl&type=req_acc"
        f"&value={APP_UUID}"
        f"&value2={urllib.parse.quote(DEVICE_NAME)}",
        label="req_acc (legacy)",
    )

    section("2. req_acc_g variants")
    # liblumix sends this with NO params. S5D might want params.
    http(f"{CAMERA}/cam.cgi?mode=accctrl&type=req_acc_g", label="req_acc_g (no params, liblumix-style)")
    http(
        f"{CAMERA}/cam.cgi?mode=accctrl&type=req_acc_g"
        f"&value={hex_lower(udn)}",
        label="req_acc_g + value=hex(udn)",
    )
    http(
        f"{CAMERA}/cam.cgi?mode=accctrl&type=req_acc_g"
        f"&value={hex_lower(udn)}"
        f"&value2={hex_lower(DEVICE_NAME)}",
        label="req_acc_g + value+value2",
    )

    section("3. req_acc_e variants — try each value encoding")
    variants = udn_variants(udn)
    name_hex = hex_lower(DEVICE_NAME)
    for label, encoded_value in variants:
        http(
            f"{CAMERA}/cam.cgi?mode=accctrl&type=req_acc_e"
            f"&value={urllib.parse.quote(encoded_value, safe='')}"
            f"&value2={name_hex}",
            label=f"req_acc_e value={label}",
        )

    section("4. req_acc_e with NAME variants (UDN fixed = hex string lowercase)")
    udn_enc = hex_lower(udn.lower())
    for nlabel, nval in [
        ("hex(Sciens)",              hex_lower("Sciens")),
        ("hex(sciens)",              hex_lower("sciens")),
        ("raw Sciens",               "Sciens"),
        ("urlencoded Sciens",        urllib.parse.quote("Sciens")),
    ]:
        http(
            f"{CAMERA}/cam.cgi?mode=accctrl&type=req_acc_e"
            f"&value={udn_enc}"
            f"&value2={urllib.parse.quote(nval, safe='')}",
            label=f"req_acc_e name={nlabel}",
        )

    section("5. other accctrl type values worth a poke")
    # Speculative names that have appeared in various Lumix docs.
    for t in ["req_acc_n", "req_acc_b", "req_acc", "release"]:
        http(
            f"{CAMERA}/cam.cgi?mode=accctrl&type={t}"
            f"&value={hex_lower(udn)}"
            f"&value2={name_hex}",
            label=f"accctrl type={t}",
        )

    section("6. summary hint")
    print("Look back through the output for any line whose response is NOT")
    print("err_param / err_reject / err_critical. A response starting with")
    print("'ok' (CSV form) or a <result>ok</result> XML body is what we want.")
    print("Report the line(s) that succeeded so we can build the real script")
    print("around that variant.")
    return 0


if __name__ == "__main__":
    sys.exit(probe_accctrl())
