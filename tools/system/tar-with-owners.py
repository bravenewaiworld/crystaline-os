"""Write a tar of a directory to stdout, taking each path's owner and mode from a reference tar
where the path appears there, and making the rest root's. build-system.sh unpacks Buildroot's
root filesystem tar as a normal user (which loses owners) and adds our files; this restores
Buildroot's owners (e.g. D-Bus's setuid helper is group messagebus) for sqfstar, so no root rights
are needed.

Each PORT_BINDER (a path in DIR) gets the right to listen on network ports below 1024 (setcap's
cap_net_bind_service=ep, as an xattr in the tar, which sqfstar keeps), so it can run as a normal
user.

Usage: tar-with-owners.py REFERENCE_TAR DIR [PORT_BINDER ...] > out.tar
"""
import os, struct, sys, tarfile

ref_path, top, *port_binders = sys.argv[1:]
with tarfile.open(ref_path) as ref:
    owners = {os.path.normpath(m.name): m for m in ref.getmembers()}
    assert not any(m.isdev() for m in owners.values()), 'device nodes in the reference tar'

# The kernel's file capability format (struct vfs_cap_data, revision 2): the revision (0x02000000)
# with flag 1, "effective" (granted when the program starts), then {permitted, inheritable} for
# capabilities 0-31, then for 32-63.
CAP_NET_BIND_SERVICE = 10
port_binder_cap = struct.pack('<5I', 0x02000000 | 1, 1 << CAP_NET_BIND_SERVICE, 0, 0, 0)
port_binders = {os.path.normpath(p) for p in port_binders}
assert all(os.path.isfile(os.path.join(top, p)) for p in port_binders), f'not all in {top}: {port_binders}'

# PAX: the tar format that carries xattrs.
with tarfile.open(fileobj=sys.stdout.buffer, mode='w|', format=tarfile.PAX_FORMAT) as out:
    for d, dirs, files in os.walk(top):
        dirs.sort()
        for name in sorted(dirs + files):
            path = os.path.join(d, name)
            arc = os.path.normpath(os.path.relpath(path, top))
            info = out.gettarinfo(path, arcname=arc)
            known = owners.get(arc)
            if known:
                info.uid, info.gid, info.uname, info.gname, info.mode = known.uid, known.gid, known.uname, known.gname, known.mode
            else:
                info.uid, info.gid, info.uname, info.gname = 0, 0, 'root', 'root'
            if arc in port_binders:
                # tarfile takes text and writes it as UTF-8: the same bytes, as all are below 0x80.
                info.pax_headers['SCHILY.xattr.security.capability'] = port_binder_cap.decode('ascii')
            if info.isfile():
                with open(path, 'rb') as f:
                    out.addfile(info, f)
            else:
                out.addfile(info)
