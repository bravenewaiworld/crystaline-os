"""Write a tar of a directory to stdout, taking each path's owner and mode from a reference tar
where the path appears there, and making the rest root's. build-system.sh unpacks Buildroot's
root filesystem tar as a normal user (which loses owners) and adds our files; this restores
Buildroot's owners (e.g. D-Bus's setuid helper is group messagebus) for sqfstar, so no root rights
are needed.

Usage: tar-with-owners.py REFERENCE_TAR DIR > out.tar
"""
import os, sys, tarfile

ref_path, top = sys.argv[1:3]
with tarfile.open(ref_path) as ref:
    owners = {os.path.normpath(m.name): m for m in ref.getmembers()}
    assert not any(m.isdev() for m in owners.values()), 'device nodes in the reference tar'

with tarfile.open(fileobj=sys.stdout.buffer, mode='w|', format=tarfile.GNU_FORMAT) as out:
    for d, dirs, files in os.walk(top):
        dirs.sort()
        for name in sorted(dirs + files):
            path = os.path.join(d, name)
            arc = os.path.normpath(os.path.relpath(path, top))
            info = out.gettarinfo(path, arcname=arc)
            known = owners.get(arc)
            info.uid, info.gid, info.uname, info.gname = (
                (known.uid, known.gid, known.uname, known.gname) if known else (0, 0, 'root', 'root'))
            if known:
                info.mode = known.mode
            if info.isfile():
                with open(path, 'rb') as f:
                    out.addfile(info, f)
            else:
                out.addfile(info)
