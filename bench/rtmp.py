"""Loopback RTMP ingest for bench/run.py that timestamps every media message as its last byte
arrives (CLOCK_UPTIME_RAW) and writes the stream to an FLV file. Latency is then measured at the
socket, so no receiver-side demux/decode buffering is included: the FLV is decoded afterwards only
to find which frame first shows each stimulus flip.

Implements the publish subset of RTMP that OBS (librtmp) and FFmpeg use: simple handshake,
chunk streams, AMF0 connect/releaseStream/FCPublish/createStream/publish, acknowledgements.
"""
import socket, struct, subprocess, threading
from pathlib import Path

import media


def amf_encode(value) -> bytes:
    if value is None: return b'\x05'
    if isinstance(value, bool): return b'\x01' + bytes([value])
    if isinstance(value, (int, float)): return b'\x00' + struct.pack('>d', value)
    if isinstance(value, str): return b'\x02' + struct.pack('>H', len(value.encode())) + value.encode()
    if isinstance(value, dict):
        body = b''.join(struct.pack('>H', len(k.encode())) + k.encode() + amf_encode(v) for k, v in value.items())
        return b'\x03' + body + b'\x00\x00\x09'
    raise TypeError(type(value))


def amf_decode(data: bytes, i: int = 0):
    """Returns (value, next index) for the AMF0 subset used in publish commands."""
    kind = data[i]; i += 1
    if kind == 0x00: return struct.unpack_from('>d', data, i)[0], i + 8
    if kind == 0x01: return bool(data[i]), i + 1
    if kind == 0x02:
        n = struct.unpack_from('>H', data, i)[0]; return data[i + 2:i + 2 + n].decode(errors='replace'), i + 2 + n
    if kind in (0x05, 0x06): return None, i
    if kind in (0x03, 0x08):
        if kind == 0x08: i += 4
        result = {}
        while data[i:i + 3] != b'\x00\x00\x09':
            n = struct.unpack_from('>H', data, i)[0]; key = data[i + 2:i + 2 + n].decode(errors='replace')
            result[key], i = amf_decode(data, i + 2 + n)
        return result, i + 3
    if kind == 0x0A:
        count = struct.unpack_from('>I', data, i)[0]; i += 4; items = []
        for _ in range(count):
            item, i = amf_decode(data, i); items.append(item)
        return items, i
    raise ValueError(f'unsupported AMF0 type {kind}')


class Receiver:
    def __init__(self, directory: Path, port: int = media.RTMP_PORT):
        self.url = f'rtmp://127.0.0.1:{port}/live'
        self.copy = directory / 'received.flv'
        self.video: list[dict] = []   # arrival_ns, pts_ms, bytes, key — one per coded frame
        self.audio: list[tuple[int, int]] = []
        self.error: str | None = None
        self.server = socket.create_server(('127.0.0.1', port), reuse_port=False)
        self.server.settimeout(1)
        self.stopping = False
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    # -- connection ---------------------------------------------------------------------------
    def _serve(self) -> None:
        try:
            while not self.stopping:
                try: connection, _ = self.server.accept()
                except TimeoutError: continue
                connection.settimeout(None)
                with connection, open(self.copy, 'wb') as flv:
                    connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    flv.write(b'FLV\x01\x05\x00\x00\x00\x09\x00\x00\x00\x00')
                    self._session(connection, flv)
                return  # one publisher per trial
        except Exception as error:  # surfaced in latency()
            self.error = repr(error)
        finally:
            self.server.close()

    def _session(self, s: socket.socket, flv) -> None:
        buffer = bytearray()
        arrival = 0

        def need(n: int) -> bytes:
            nonlocal arrival
            while len(buffer) < n:
                chunk = s.recv(1 << 16)
                if not chunk: raise EOFError
                arrival = media.now_ns()
                buffer.extend(chunk)
                self._received += len(chunk)
                if self._window and self._received - self._acked >= self._window:
                    self._acked = self._received
                    self._send(s, 2, 3, 0, struct.pack('>I', self._received & 0xFFFFFFFF))
            data = bytes(buffer[:n]); del buffer[:n]; return data

        self._received = self._acked = self._window = 0
        self._out_chunk = 128
        # Simple handshake: C0+C1 → S0+S1+S2 (S2 echoes C1) → C2.
        c1 = need(1537)[1:]
        s.sendall(b'\x03' + bytes(8) + bytes(1528) + c1)
        need(1536)
        in_chunk = 128
        streams: dict[int, dict] = {}
        try:
            while True:
                first = need(1)[0]
                fmt, csid = first >> 6, first & 0x3F
                if csid == 0: csid = 64 + need(1)[0]
                elif csid == 1: low, high = need(2); csid = 64 + low + high * 256
                st = streams.setdefault(csid, {'ts': 0, 'delta': 0, 'length': 0, 'type': 0, 'sid': 0, 'body': bytearray(), 'ext': False})
                if fmt <= 2:
                    header = need(11 if fmt == 0 else 7 if fmt == 1 else 3)
                    ts = int.from_bytes(header[0:3], 'big')
                    if fmt <= 1:
                        st['length'] = int.from_bytes(header[3:6], 'big'); st['type'] = header[6]
                    if fmt == 0: st['sid'] = struct.unpack('<I', header[7:11])[0]
                    st['ext'] = ts == 0xFFFFFF
                    if st['ext']: ts = struct.unpack('>I', need(4))[0]
                    if fmt == 0: st['ts'], st['delta'] = ts, 0
                    else: st['delta'] = ts; st['ts'] += ts
                else:
                    if st['ext']: need(4)
                    if not st['body']: st['ts'] += st['delta']  # fmt 3 starting a new message
                take = min(in_chunk, st['length'] - len(st['body']))
                st['body'] += need(take)
                if len(st['body']) < st['length']: continue
                body, st['body'] = bytes(st['body']), bytearray()
                kind, ts = st['type'], st['ts']
                if kind == 1: in_chunk = struct.unpack('>I', body[:4])[0] & 0x7FFFFFFF
                elif kind == 5: self._window = struct.unpack('>I', body[:4])[0]
                elif kind == 20: self._command(s, body)
                elif kind in (8, 9):
                    flv.write(bytes([kind]) + len(body).to_bytes(3, 'big') + (ts & 0xFFFFFF).to_bytes(3, 'big')
                              + bytes([(ts >> 24) & 0xFF]) + b'\x00\x00\x00' + body + struct.pack('>I', 11 + len(body)))
                    if kind == 9 and len(body) > 5 and body[0] & 0x0F == 7 and body[1] == 1:
                        cts = int.from_bytes(body[2:5], 'big', signed=True)
                        self.video.append({'arrival_ns': arrival, 'pts_ms': ts + cts, 'bytes': len(body), 'key': body[0] >> 4 == 1})
                    elif kind == 8 and len(body) > 2 and body[1] == 1:
                        self.audio.append((arrival, ts))
        except EOFError:
            pass

    def _send(self, s: socket.socket, csid: int, kind: int, sid: int, body: bytes) -> None:
        out = bytes([csid]) + bytes(3) + len(body).to_bytes(3, 'big') + bytes([kind]) + struct.pack('<I', sid)
        for i in range(0, len(body), self._out_chunk):
            if i: out += bytes([0xC0 | csid])
            out += body[i:i + self._out_chunk]
        s.sendall(out)

    def _command(self, s: socket.socket, body: bytes) -> None:
        name, i = amf_decode(body)
        txn, i = amf_decode(body, i)
        if name == 'connect':
            self._send(s, 2, 5, 0, struct.pack('>I', 2_500_000))
            self._send(s, 2, 6, 0, struct.pack('>IB', 2_500_000, 2))
            self._send(s, 2, 1, 0, struct.pack('>I', 4096)); self._out_chunk = 4096
            self._send(s, 3, 20, 0, amf_encode('_result') + amf_encode(txn)
                       + amf_encode({'fmsVer': 'FMS/3,0,1,123', 'capabilities': 31.0})
                       + amf_encode({'level': 'status', 'code': 'NetConnection.Connect.Success',
                                     'description': 'Connection succeeded.', 'objectEncoding': 0.0}))
        elif name == 'createStream':
            self._send(s, 3, 20, 0, amf_encode('_result') + amf_encode(txn) + amf_encode(None) + amf_encode(1.0))
        elif name == 'publish':
            self._send(s, 5, 20, 1, amf_encode('onStatus') + amf_encode(0.0) + amf_encode(None)
                       + amf_encode({'level': 'status', 'code': 'NetStream.Publish.Start', 'description': 'Publishing.'}))
        elif name in ('releaseStream', 'FCPublish') and txn:
            self._send(s, 3, 20, 0, amf_encode('_result') + amf_encode(txn) + amf_encode(None) + amf_encode(None))

    # -- results ------------------------------------------------------------------------------
    def close(self, timeout: float = 15) -> None:
        """The session ends when the publisher disconnects."""
        self.thread.join(timeout)
        self.stopping = True
        self.thread.join(5)

    def latency(self, stimulus: Path, start_requested: int | None) -> dict:
        """Stimulus flip (display-link target time) → arrival of the first coded frame showing it."""
        if self.error: return {'error': self.error}
        if len(self.video) < 30: return {'error': f'only {len(self.video)} frames received'}
        info = media.facts(self.copy)
        frames = media.decode_gray(self.copy)
        ordered = sorted(self.video, key=lambda v: v['pts_ms'])
        if len(frames) != len(ordered):
            return {'error': f'decoded {len(frames)} frames but received {len(ordered)}'}
        header, events = media.stimulus_log(stimulus)
        means, threshold = media.levels(frames, media.mask(header, info['video']['width'], info['video']['height']))
        if threshold is None: return {'error': 'stimulus square not visible in received stream'}
        latencies, missed = [], 0
        first, last = ordered[0]['arrival_ns'] + 1_000_000_000, ordered[-1]['arrival_ns'] - 1_000_000_000
        for event in events:
            t = event['t_ns']
            if not first <= t <= last: continue
            light = event['level'] == 'light'
            # First frame in presentation order that shows the new level and arrived after the flip.
            hit = next((f for f, m in zip(ordered, means) if f['arrival_ns'] >= t and (m >= threshold) == light), None)
            if hit and hit['arrival_ns'] - t < 850_000_000: latencies.append((hit['arrival_ns'] - t) / 1e6)
            else: missed += 1
        return {'frames_received': len(ordered), 'flips_measured': len(latencies), 'flips_missed': missed,
                'glass_to_receiver_ms': media.summary(latencies),
                'first_frame_after_start_ms': round((ordered[0]['arrival_ns'] - start_requested) / 1e6, 1) if start_requested else None,
                'received': info, 'av_offset': media.av_offset(self.copy, stimulus)}


def calibrate(directory: Path, seconds: float = 8) -> dict:
    """Measurement floor: a synthetic FFmpeg publisher (x264 zerolatency, silent AAC) writes flat
    frames whose level flips at known host times; the receiver should see each flip within ~1 ms."""
    import json, time
    directory.mkdir(parents=True, exist_ok=True)
    width, height, fps = 640, 360, 30
    receiver = Receiver(directory)
    publisher = subprocess.Popen(
        [media.FFMPEG, '-v', 'error', '-f', 'rawvideo', '-pix_fmt', 'gray', '-s', f'{width}x{height}', '-r', str(fps), '-i', '-',
         '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo', '-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'zerolatency',
         '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', '-flush_packets', '1', '-f', 'flv', f'{receiver.url}/bench'],
        stdin=subprocess.PIPE)
    frames = {False: bytes([40]) * (width * height), True: bytes([210]) * (width * height)}
    events, light, start = [], False, time.monotonic()
    for n in range(int(seconds * fps)):
        while time.monotonic() < start + n / fps: time.sleep(0.001)
        if n and n % 27 == 0:
            light = not light
            events.append({'i': len(events), 'level': 'light' if light else 'dark', 't_ns': media.now_ns()})
        publisher.stdin.write(frames[light]); publisher.stdin.flush()
    publisher.stdin.close(); publisher.wait(10)
    receiver.close()
    log = directory / 'stimulus.jsonl'
    header = {'screen': {'w': width, 'h': height, 'scale': 1}, 'rect': [width // 2 - 60, height // 2 - 60, 120, 120]}
    log.write_text(''.join(json.dumps(x) + '\n' for x in [header, *events]))
    result = receiver.latency(log, None)
    return {'publisher': 'FFmpeg libx264 zerolatency 640x360 + AAC', 'glass_to_receiver_ms': result.get('glass_to_receiver_ms'),
            'error': result.get('error')}
