# libfaketime

An image that carries the preload libraries needed to fake time, at a fixed
path, `/usr/local/lib/faketime/`, and nothing else.

## What it is

Not an application image. It is a carrier for build artifacts: the preload
libraries, on a pinned glibc baseline. Copy them out of this image into the
container that needs them.

## What it is for

To fake time per process through `LD_PRELOAD`, without touching the host,
database or middleware clocks.

## Use it

Copy the library straight out of this image in a multi-stage build:

```dockerfile
COPY --from=arsiachou/libfaketime:v0.9.13-glibc2.31 /usr/local/lib/faketime/ /usr/local/lib/faketime/
```

Then preload it for the process that needs a fake clock:

```sh
# one day ahead
LD_PRELOAD=/usr/local/lib/faketime/libfaketime.so.1 FAKETIME='+1d' date

# frozen clock
LD_PRELOAD=/usr/local/lib/faketime/libfaketime.so.1 FAKETIME='2020-01-01 00:00:00' date

# anchored: starts there and keeps advancing
LD_PRELOAD=/usr/local/lib/faketime/libfaketime.so.1 FAKETIME='@2020-01-01 00:00:00' date
```

Or copy the files onto the host first:

```sh
cid=$(docker create arsiachou/libfaketime:v0.9.13-glibc2.31)
docker cp "$cid:/usr/local/lib/faketime/." ./faketime
docker rm "$cid"
```

## Tags

The library is compiled once, on Debian 11 / glibc 2.31, and that same file is
copied into every carrier image, because glibc compatibility only runs one way.
The carrier decides which base system you pull; it does not change the library.

| tag | meaning |
|---|---|
| `v0.9.13-glibc2.31-debian11.11` | exact point release the image was built against |
| `v0.9.13-glibc2.31-debian11` | follows the 11.x line |
| `v0.9.13-glibc2.31` | follows the newest carrier (currently Debian 13) |

The exact tag never moves: it names the point release and stays put forever. The
other two are pointers, rewritten whenever upstream ships a new point release,
which is the whole reason to pull them.

`glibc2.31` is the ABI floor: the library loads on 2.31 and newer, which covers
Debian 11 through 13. The same file is also published as a tarball on each
release.

## License

GNU General Public License, version 2 — see
[`LICENSE`](https://github.com/arsiac/libfaketime-image/blob/master/LICENSE).

This repository and the images it produces redistribute libfaketime
(<https://github.com/wolfcw/libfaketime>) under the same license.
