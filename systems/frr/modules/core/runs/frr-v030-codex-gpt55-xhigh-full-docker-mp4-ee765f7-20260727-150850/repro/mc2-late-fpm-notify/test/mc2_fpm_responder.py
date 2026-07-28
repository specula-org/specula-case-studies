#!/usr/bin/env python3
import argparse
import ipaddress
import os
import socket
import struct
import time

AF_INET = 2
FPM_MSG_TYPE_NETLINK = 1
NLM_F_REQUEST = 1
RTM_NEWROUTE = 24
RTA_DST = 1
RTA_TABLE = 15
RTPROT_BGP = 186
RTM_F_OFFLOAD = 0x4000
NLMSG_HDRLEN = 16
RTMSG_LEN = 12


def align4(value):
    return (value + 3) & ~3


def recv_exact(sock, size):
    chunks = []
    remaining = size
    while remaining:
        data = sock.recv(remaining)
        if not data:
            return None
        chunks.append(data)
        remaining -= len(data)
    return b"".join(chunks)


class Responder:
    def __init__(self, args):
        self.target = ipaddress.ip_network(args.prefix)
        self.log_path = args.log
        self.ready_path = args.ready
        self.first_seen_path = args.first_seen
        self.second_seen_path = args.second_seen
        self.send_path = args.send
        self.sent_path = args.sent
        self.first_frame = None
        self.target_frames = 0

    def log(self, message):
        with open(self.log_path, "a", encoding="ascii") as f:
            f.write(message + "\n")
            f.flush()

    def marker(self, path, text):
        with open(path, "w", encoding="ascii") as f:
            f.write(text + "\n")

    def parse_target_infos(self, frame):
        payload = frame[4:]
        infos = []
        offset = 0

        while offset + NLMSG_HDRLEN <= len(payload):
            try:
                nlmsg_len, nlmsg_type, nlmsg_flags, nlmsg_seq, _ = struct.unpack_from(
                    "=IHHII", payload, offset
                )
            except struct.error:
                break

            if nlmsg_len < NLMSG_HDRLEN + RTMSG_LEN:
                break
            end = offset + nlmsg_len
            if end > len(payload):
                break

            if nlmsg_type == RTM_NEWROUTE:
                rtm_offset = offset + NLMSG_HDRLEN
                try:
                    (
                        family,
                        dst_len,
                        _src_len,
                        _tos,
                        table,
                        proto,
                        _scope,
                        route_type,
                        rtm_flags,
                    ) = struct.unpack_from("=BBBBBBBBI", payload, rtm_offset)
                except struct.error:
                    break

                dst = None
                table_attr = None
                attr_offset = offset + align4(NLMSG_HDRLEN + RTMSG_LEN)
                while attr_offset + 4 <= end:
                    try:
                        rta_len, rta_type = struct.unpack_from("=HH", payload, attr_offset)
                    except struct.error:
                        break
                    if rta_len < 4 or attr_offset + rta_len > end:
                        break
                    data = payload[attr_offset + 4 : attr_offset + rta_len]
                    if rta_type == RTA_DST and family == AF_INET and len(data) >= 4:
                        dst = str(ipaddress.IPv4Address(data[:4]))
                    elif rta_type == RTA_TABLE and len(data) >= 4:
                        table_attr = struct.unpack_from("=I", data, 0)[0]
                    attr_offset += align4(rta_len)

                if (
                    family == AF_INET
                    and proto == RTPROT_BGP
                    and dst == str(self.target.network_address)
                    and dst_len == self.target.prefixlen
                ):
                    infos.append(
                        {
                            "rtm_flags_off": 4 + rtm_offset + 8,
                            "nlmsg_flags": nlmsg_flags,
                            "nlmsg_seq": nlmsg_seq,
                            "route_type": route_type,
                            "table": table_attr if table_attr is not None else table,
                            "rtm_flags": rtm_flags,
                        }
                    )

            offset += align4(nlmsg_len)

        return infos

    def offload_frame(self, frame, infos):
        out = bytearray(frame)
        for info in infos:
            off = info["rtm_flags_off"]
            flags = struct.unpack_from("=I", out, off)[0]
            struct.pack_into("=I", out, off, flags | RTM_F_OFFLOAD)
        return bytes(out)

    def wait_for_send_marker(self):
        for _ in range(300):
            if os.path.exists(self.send_path):
                return True
            time.sleep(0.1)
        return False

    def run(self):
        for path in (
            self.ready_path,
            self.first_seen_path,
            self.second_seen_path,
            self.send_path,
            self.sent_path,
            self.log_path,
        ):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass

        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as srv:
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind(("127.0.0.1", 2620))
            srv.listen(1)
            self.marker(self.ready_path, "ready")
            self.log("MC2_FPM ready")

            conn, addr = srv.accept()
            with conn:
                self.log(f"MC2_FPM accepted addr={addr}")
                while True:
                    hdr = recv_exact(conn, 4)
                    if hdr is None:
                        self.log("MC2_FPM connection_closed")
                        return
                    version, msg_type, msg_len = struct.unpack("!BBH", hdr)
                    if msg_len < 4:
                        self.log(f"MC2_FPM bad_len len={msg_len}")
                        return
                    payload = recv_exact(conn, msg_len - 4)
                    if payload is None:
                        self.log("MC2_FPM payload_closed")
                        return

                    frame = hdr + payload
                    if version != 1 or msg_type != FPM_MSG_TYPE_NETLINK:
                        continue

                    infos = self.parse_target_infos(frame)
                    if not infos:
                        continue

                    self.target_frames += 1
                    info = infos[0]
                    self.log(
                        "MC2_FPM target_route "
                        f"count={self.target_frames} prefix={self.target} "
                        f"nlmsg_flags=0x{info['nlmsg_flags']:x} "
                        f"rtm_flags=0x{info['rtm_flags']:x} "
                        f"seq={info['nlmsg_seq']} table={info['table']}"
                    )

                    if not (info["nlmsg_flags"] & NLM_F_REQUEST):
                        self.log("MC2_FPM target_route_missing_request_flag")

                    if self.target_frames == 1:
                        self.first_frame = self.offload_frame(frame, infos)
                        self.marker(self.first_seen_path, "first_seen")
                        self.log("MC2_FPM stored_first_without_reply=true")
                    elif self.target_frames == 2:
                        self.marker(self.second_seen_path, "second_seen")
                        self.log("MC2_FPM stored_second_without_reply=true")
                        if not self.wait_for_send_marker():
                            self.log("MC2_FPM send_marker_timeout=true")
                            return
                        conn.sendall(self.first_frame)
                        self.marker(self.sent_path, "sent_stale_first")
                        self.log("MC2_FPM sent_stale_first=true")
                        self.log("MC2_FPM sent_current_second=false")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--ready", required=True)
    parser.add_argument("--first-seen", required=True)
    parser.add_argument("--second-seen", required=True)
    parser.add_argument("--send", required=True)
    parser.add_argument("--sent", required=True)
    args = parser.parse_args()
    Responder(args).run()


if __name__ == "__main__":
    main()
