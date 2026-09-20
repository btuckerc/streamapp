#!/usr/bin/env python3
"""Loopback-only RTMP receiver; numbered files survive publisher reconnects."""
import argparse, signal, subprocess, time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--directory',required=True);a=p.parse_args()
d=Path(a.directory).resolve();d.mkdir(parents=True,exist_ok=True)
child=None;running=True

def stop(sig,frame):
    global running
    running=False
    if child and child.poll() is None:child.send_signal(signal.SIGINT)
signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
i=0
while running:
    while (d/f'received-{i:03d}.mkv').exists():i+=1
    child=subprocess.Popen(['ffmpeg','-hide_banner','-nostdin','-loglevel','info','-listen','1','-i','rtmp://127.0.0.1:19351/live/bench','-map','0','-c','copy',str(d/f'received-{i:03d}.mkv')])
    print('receiver waiting',i,flush=True)
    child.wait();i+=1
    if running:time.sleep(.2)
