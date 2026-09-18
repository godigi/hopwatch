#!/usr/bin/env python3
"""Native sudo-free Wi-Fi radio telemetry via Apple's CoreWLAN framework.

Queries the default Wi-Fi interface for RSSI, noise, channel, Tx rate, and
PHY mode without requiring root or sudo privileges.

Outputs seven tab-separated fields:
  rssi \t noise \t channel \t tx_rate \t phy \t ssid \t bssid
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
    chan = (
        msg_long(chan_obj, objc.sel_registerName(b"channelNumber"))
        if chan_obj
        else ""
    )

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
    ssid = (
        msg_str(ssid_obj, utf8_sel).decode("utf-8", "replace")
        if ssid_obj
        else ""
    )

    bssid_obj = objc.objc_msgSend(iface, objc.sel_registerName(b"bssid"))
    bssid = (
        msg_str(bssid_obj, utf8_sel).decode("utf-8", "replace")
        if bssid_obj
        else ""
    )

    return {
        "rssi": rssi,
        "noise": noise,
        "chan": chan,
        "tx": tx,
        "phy": phy,
        "ssid": ssid,
        "bssid": bssid,
    }


def main() -> int:
    try:
        t = get_wifi_telemetry()
        if t:
            print(
                f"{t['rssi']}\t{t['noise']}\t{t['chan']}\t{t['tx']}\t{t['phy']}\t{t['ssid']}\t{t['bssid']}"
            )
    except Exception:
        # Never crash or exit non-zero; callers treat empty output as unavailable
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
