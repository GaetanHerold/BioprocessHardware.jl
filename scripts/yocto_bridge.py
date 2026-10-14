#!/usr/bin/env python3
"""
Generic Yoctopuce 4-20mA Sensor Bridge
Reads current (mA) from Yoctopuce Yocto-4-20mA-Rx USB receiver
and atomically writes raw telemetry to a designated cache file.
"""

import os
import sys
import time
import json
import argparse
import signal

def parse_args():
    parser = argparse.ArgumentParser(description="Generic Yoctopuce 4-20mA Sensor Bridge")
    parser.add_argument("--output", "-o", default="plots/yocto_co2_live.json", help="Path to output cache JSON file")
    parser.add_argument("--serial", "-s", default="", help="Specific Yoctopuce serial number (optional)")
    parser.add_argument("--channel", "-c", type=int, default=1, help="Channel number (1 or 2)")
    parser.add_argument("--interval", "-i", type=float, default=1.0, help="Polling interval in seconds")
    return parser.parse_args()

def main():
    args = parse_args()
    cache_path = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(cache_path), exist_ok=True)

    keep_running = True
    def handle_signal(sig, frame):
        nonlocal keep_running
        keep_running = False
    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    try:
        from yoctopuce.yocto_api import YAPI, YRefParam
        from yoctopuce.yocto_genericsensor import YGenericSensor
    except ImportError:
        # If library not present, write offline status and exit with code 1
        print("[YOCTO] 'yoctopuce' python library is not installed.", file=sys.stderr)
        sys.exit(1)

    errmsg = YRefParam()
    if YAPI.RegisterHub("usb", errmsg) != YAPI.SUCCESS:
        print(f"[YOCTO] Fatal: Could not register Yoctopuce USB hub: {errmsg.value}", file=sys.stderr)
        sys.exit(1)

    print(f"[YOCTO] Bridge active. Streaming raw 4-20mA to {cache_path}")

    target_name = f"genericSensor{args.channel}"
    if args.serial:
        target_name = f"{args.serial}.{target_name}"

    tmp_path = cache_path + ".tmp"

    while keep_running:
        try:
            sensor = YGenericSensor.FindGenericSensor(target_name)
            if not (sensor and sensor.isOnline()):
                # Fallback scan
                s = YGenericSensor.FirstGenericSensor()
                while s:
                    if s.isOnline():
                        sensor = s
                        break
                    s = s.nextGenericSensor()

            if sensor and sensor.isOnline():
                raw_mA = sensor.get_currentValue()
                data = {
                    "timestamp": time.time(),
                    "raw_mA": raw_mA,
                    "unit": "mA",
                    "valid": True,
                    "friendly_name": sensor.get_friendlyName()
                }
            else:
                data = {
                    "timestamp": time.time(),
                    "raw_mA": float("nan"),
                    "unit": "mA",
                    "valid": False,
                    "friendly_name": ""
                }

            # Atomic write
            with open(tmp_path, "w") as f:
                json.dump(data, f)
            os.replace(tmp_path, cache_path)

        except Exception as e:
            print(f"[YOCTO] Warning: loop error: {e}", file=sys.stderr)

        time.sleep(args.interval)

    YAPI.FreeAPI()

if __name__ == "__main__":
    main()
