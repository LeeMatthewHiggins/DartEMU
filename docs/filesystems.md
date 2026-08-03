# Filesystems and shares

Two ways to give a guest files: a block device it owns, or a share the host
keeps.

- [Block devices](#block-devices)
- [Shares over 9P](#shares-over-9p)
- [The backend seam](#the-backend-seam)
- [Mounting](#mounting)
- [Backends](#backends)
- [Containment](#containment)
- [Which to use](#which-to-use)

## Block devices

A disk is a `BlockDevice`, and the guest treats it as a normal drive:

```dart
abstract class BlockDevice {
  int get sectorCount;
  void readSectors(int sectorNum, Uint8List buffer, int count);
  void writeSectors(int sectorNum, Uint8List buffer, int count);
  static const sectorSize = 512;
}
```

`MemoryBlockDevice.fromData(bytes)` holds the image in memory and works
everywhere, including the browser. Writes go to the copy, so the original
asset is never modified — which is what makes it safe to boot the same
bundled image repeatedly, and what `AgentSandbox` relies on for a fresh
guest each time.

`FileBlockDevice.open(path)` reads and writes a file on disk, and therefore
lives behind `package:dart_emu/dart_emu_io.dart`. Writes are real.

## Shares over 9P

A share is a directory the *host* owns and the guest mounts. Unlike a block
device it needs no filesystem image, changes are visible on both sides
immediately, and it can be backed by something that is not a disk at all.

```yaml
fs0:
  file: /home/me/project
  tag: work
  readonly: false
```

The transport is VirtIO-9P speaking 9P2000.u.

## The backend seam

Everything host-side is behind one interface:

```dart
abstract class NinePBackend {
  NinePStat? stat(String path);
  List<NinePStat> readdir(String path);
  Uint8List read(String path, int offset, int count);
  int write(String path, int offset, Uint8List data);
  NinePStat create(String parent, String name,
      {required bool isDir, required int permBits});
  void remove(String path);
  void setLength(String path, int length);
  void setMtime(String path, int mtimeSeconds);
}
```

Anything that can answer those can be a filesystem to a guest.

## Mounting

In the guest:

```sh
mkdir -p /mnt/work
mount -t 9p -o trans=virtio,version=9p2000.u,msize=65536 work /mnt/work
```

The mount tag is the `tag:` from the config, defaulting to `fs0`, `fs1` and
so on by index. `AgentSandbox` can do this for you — `sharedFolder`,
`sharedMountPoint` (default `/mnt/shared`) and `autoMountShared`.

## Backends

**Directory** — `createDirectoryNinePBackend(path, readOnly: false)`. A real
host directory, `dart:io`, read-write unless you say otherwise. This is what
a `fs0:` in a YAML config resolves to.

**Memory** — `MemoryNinePBackend`. An in-memory tree, seeded with
`addFile`/`addDirectory`. Works everywhere. It is what a share inside a
`.zip` bundle becomes: entries beneath the named directory are loaded in,
and writes last as long as the machine does and go with it — which is the
most an archive can honestly offer.

**Browser folder** — the File System Access picker, in
`package:dart_emu/dart_emu_web.dart`. The user chooses a real directory and
it is loaded into an in-memory tree, with a write-back sink so changes reach
the disk. Refreshing re-reads the host side without clobbering guest-only
files.

## Containment

The directory backend resolves every path and refuses anything that escapes
the share root, including through an intermediate symlink. A symlink that
resolves *inside* the root still works. This is enforced on read, write,
create and truncate, and the cases are covered in
`test/device/virtio/ninep/`.

`readOnly` is enforced by the server, not by the guest: the guest may hold a
writable file descriptor and still have its writes rejected, which is what
you want when the guest is untrusted.

## Which to use

Shares are much cheaper than moving bytes over the console. `AgentSandbox`
can exchange files as base64 through the serial line, which works
everywhere, but a serial console is a slow way to move a megabyte.

Practical guidance:

- **A file or two, or a browser with no folder access** — console transfer.
- **A working directory, or anything of size** — a share.
- **A whole root filesystem** — a block device.

One caution learned the hard way: a share is a *live* view of a real
directory, so a guest walking it walks all of it. Pointing a share at a home
directory or a large source tree means the guest can enumerate every file in
it, and a command like `du -a` will try to. Share the narrowest directory
that does the job.
