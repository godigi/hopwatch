#!/usr/bin/env python3
"""Native sudo-free Wi-Fi radio telemetry via Apple's CoreWLAN framework.

Queries the default Wi-Fi interface for RSSI, noise, channel, Tx rate, and
PHY mode without requiring root or sudo privileges.

Outputs seven fields separated by ASCII Unit Separator (0x1f):
  rssi <US> noise <US> channel <US> tx_rate <US> phy <US> ssid <US> bssid

The separator is deliberately not a tab. Callers split the line with
`IFS=<sep> read -r ...`, and a tab is IFS whitespace, so consecutive tabs
collapse into one: an empty SSID shifted the BSSID into the SSID slot and
"phy" into the tx-rate slot. A non-whitespace separator keeps empty fields
where they are. Values are scrubbed of the separator, newlines and tabs so a
hostile SSID cannot forge a field either.
"""

from __future__ import annotations

import ctypes
import sys


def get_wifi_telemetry() -> dict[str, str | int] | None:
    try:
        objc = ctypes.cdll.LoadLibrary("/usr/lib/libobjc.A.dylib")
    except Exception:
        return None

    objc.objc_getClass.restype = ctypes.c_void_p
    objc.objc_getClass.argtypes = [ctypes.c_char_p]
    objc.sel_registerName.restype = ctypes.c_void_p
    objc.sel_registerName.argtypes = [ctypes.c_char_p]
    objc.objc_msgSend.restype = ctypes.c_void_p
    objc.objc_msgSend.argtypes = [ctypes.c_void_p, ctypes.c_void_p]

    try:
        ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreWLAN.framework/CoreWLAN")
    except Exception:
        return None

    cls = objc.objc_getClass(b"CWWiFiClient")
    if not cls:
        return None

    shared = objc.objc_msgSend(cls, objc.sel_registerName(b"sharedWiFiClient"))
    if not shared:
        return None

    iface = objc.objc_msgSend(shared, objc.sel_registerName(b"interface"))
    if not iface:
        return None

    msg_long = ctypes.cast(
        objc.objc_msgSend,
        ctypes.CFUNCTYPE(ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p),
    )
    msg_double = ctypes.cast(
        objc.objc_msgSend,
        ctypes.CFUNCTYPE(ctypes.c_double, ctypes.c_void_p, ctypes.c_void_p),
    )
    msg_str = ctypes.cast(
        objc.objc_msgSend,
        ctypes.CFUNCTYPE(ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p),
    )
    utf8_sel = objc.sel_registerName(b"UTF8String")

    rssi = msg_long(iface, objc.sel_registerName(b"rssiValue"))
    # 0 indicates unassociated or telemetry unavailable in CoreWLAN
    if rssi == 0:
        return None

    noise = msg_long(iface, objc.sel_registerName(b"noiseMeasurement"))

    tx_raw = msg_double(iface, objc.sel_registerName(b"transmitRate"))
    tx = int(round(tx_raw)) if tx_raw > 0 else ""

    chan_obj = objc.objc_msgSend(iface, objc.sel_registerName(b"wlanChannel"))
    chan = ""
    if chan_obj:
        num = msg_long(chan_obj, objc.sel_registerName(b"channelNumber"))
        band = msg_long(chan_obj, objc.sel_registerName(b"channelBand"))
        band_str = {1: "2.4GHz", 2: "5GHz", 3: "6GHz"}.get(band, "")
        if band_str:
            chan = f"{num} ({band_str})"
        else:
            chan = str(num)

    phy_mode = msg_long(iface, objc.sel_registerName(b"activePHYMode"))
    phy_map = {
        1: "802.11a",
        2: "802.11b",
        3: "802.11g",
        4: "802.11n",
        5: "802.11ac",
        6: "802.11ax",
        7: "802.11be",
    }
    phy = phy_map.get(phy_mode, "")

    ssid_obj = objc.objc_msgSend(iface, objc.sel_registerName(b"ssid"))
    raw_ssid = msg_str(ssid_obj, utf8_sel) if ssid_obj else None
    ssid = raw_ssid.decode("utf-8", "replace") if raw_ssid else ""

    bssid_obj = objc.objc_msgSend(iface, objc.sel_registerName(b"bssid"))
    raw_bssid = msg_str(bssid_obj, utf8_sel) if bssid_obj else None
    bssid = raw_bssid.decode("utf-8", "replace") if raw_bssid else ""

    return {
        "rssi": rssi,
        "noise": noise,
        "chan": chan,
        "tx": tx,
        "phy": phy,
        "ssid": ssid,
        "bssid": bssid,
    }


FIELD_SEP = "\x1f"


def _clean(value: object) -> str:
    """Stringify a field, replacing anything that could forge a field or line."""
    text = str(value)
    for bad in (FIELD_SEP, "\t", "\r", "\n"):
        text = text.replace(bad, " ")
    return text


def format_line(t: dict[str, str | int]) -> str:
    keys = ("rssi", "noise", "chan", "tx", "phy", "ssid", "bssid")
    return FIELD_SEP.join(_clean(t[k]) for k in keys)


def main() -> int:
    try:
        t = get_wifi_telemetry()
        if t:
            print(format_line(t))
    except Exception:
        # Never crash or exit non-zero; callers treat empty output as unavailable
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
