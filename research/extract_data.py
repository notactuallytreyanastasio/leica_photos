#!/usr/bin/env python3
"""extract_data.py — pull data payloads of specific txids from the pcap streams.

M10 data-in flow (learned from the capture): StartData(total) -> Data(10)
packet(s), whole payload in one packet when small -> Response(7). No EndData.

Usage: python3 extract_data.py <pcap> txid=outfile ...
"""
import struct
import sys

from parse_pcap import read_pcap, reassemble, decode_packets


def main():
    pcap = sys.argv[1]
    want = {int(a): b for a, b in (p.split("=") for p in sys.argv[2:])}
    pkts = read_pcap(pcap)
    streams = reassemble(pkts)
    for key, blob in streams.items():
        src, sport, dst, dport = key
        if src != "192.168.1.2":
            continue  # camera -> client streams only
        collecting = None
        buf = bytearray()
        for ptype, payload in decode_packets(blob):
            if ptype == 9:  # StartData
                txid = struct.unpack("<I", payload[:4])[0]
                if txid in want:
                    collecting = txid
                    buf = bytearray()
            elif ptype == 10 and collecting is not None:
                buf += payload[4:]
            elif ptype == 7:  # Response ends the transaction
                if collecting is not None:
                    code = struct.unpack("<H", payload[:2])[0]
                    with open(want[collecting], "wb") as f:
                        f.write(bytes(buf))
                    print(f"txid {collecting}: {len(buf)} bytes "
                          f"(resp {code:#06x}) -> {want[collecting]}")
                    collecting = None


if __name__ == "__main__":
    main()
