#!/usr/bin/env python3
"""Finite macOS process-tree sampler. CPU converts Mach ticks to ns; 100%=one core."""
import argparse, ctypes, json, subprocess, time
from pathlib import Path
p=argparse.ArgumentParser(); p.add_argument('--output',required=True); p.add_argument('--seconds',type=float,default=25); p.add_argument('--pid',type=int,action='append',default=[]); p.add_argument('command',nargs=argparse.REMAINDER); a=p.parse_args()
lib=ctypes.CDLL('/usr/lib/libproc.dylib'); lib.proc_pid_rusage.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_void_p]
class Timebase(ctypes.Structure):
    _fields_=[('numer',ctypes.c_uint32),('denom',ctypes.c_uint32)]
tb=Timebase(); ctypes.CDLL('/usr/lib/libSystem.B.dylib').mach_timebase_info(ctypes.byref(tb))
tick_ns=tb.numer/tb.denom
def usage(pid):
    b=ctypes.create_string_buffer(1024)
    if lib.proc_pid_rusage(pid,2,b)!=0:return None
    def u(offset):return ctypes.c_uint64.from_buffer(b,offset).value
    return {'cpu_ns':u(16)*tick_ns+u(24)*tick_ns,'rss':u(64),'footprint':u(72)}
def originator(pid):
    b=ctypes.create_string_buffer(48)
    if lib.proc_pidoriginatorinfo(pid,3,b,48)>0:
        return ctypes.c_int32.from_buffer(b,16).value
    return 0
cmd=a.command[1:] if a.command[:1]==['--'] else a.command
proc=None; log=None
if cmd:
    log=open(str(Path(a.output).with_suffix('.log')),'wb'); proc=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT); a.pid.append(proc.pid)
start=time.monotonic(); previous={}; samples=[]
while time.monotonic()-start<a.seconds:
    now=time.monotonic(); rows=subprocess.check_output(['/bin/ps','-axo','pid=,ppid='],text=True).splitlines(); pairs=[tuple(map(int,x.split())) for x in rows if len(x.split())==2]
    chosen=set(a.pid)
    while True:
        children={pid for pid,ppid in pairs if ppid in chosen or originator(pid) in chosen}
        if children<=chosen:break
        chosen|=children
    records=[]
    for pid in sorted(chosen):
        v=usage(pid)
        if v is None:continue
        old=previous.get(pid)
        v['cpu_percent']=100*(v['cpu_ns']-old[1])/1e9/(now-old[0]) if old else None
        previous[pid]=(now,v['cpu_ns']); records.append({'pid':pid,'originator':originator(pid),**v})
    samples.append({'elapsed':now-start,'processes':records,'rss':sum(r['rss'] for r in records),'footprint':sum(r['footprint'] for r in records),'cpu_percent':sum(r['cpu_percent'] or 0 for r in records)})
    if proc and proc.poll() is not None:break
    time.sleep(1)
if proc and proc.poll() is None:proc.wait(timeout=15)
if log:log.close()
steady=[s for s in samples if s['elapsed']>=3 and s['processes']]
result={'command':cmd,'roots':a.pid,'elapsed':time.monotonic()-start,'exit':proc.returncode if proc else None,'cpu_units':'100 percent = one CPU core; process tree only; excludes GPU and shared WindowServer','samples':samples,'summary':{'samples':len(steady),'mean_cpu_percent':sum(s['cpu_percent'] for s in steady)/len(steady) if steady else None,'max_footprint_mib':max((s['footprint']/1048576 for s in steady),default=0),'max_rss_mib':max((s['rss']/1048576 for s in steady),default=0)}}
Path(a.output).write_text(json.dumps(result,indent=2)); print(json.dumps(result['summary']))
if proc and proc.returncode:raise SystemExit(proc.returncode)
