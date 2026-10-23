# libfaketime

An image that carries the preload libraries needed to fake time, at a fixed
path, `/usr/local/lib/faketime/`, and nothing else. It is a carrier for build
artifacts, not an application image: copy the libraries into the container that
needs them.

## Use it

Copy the library straight out of this image in a multi-stage build:

```dockerfile
COPY --from=arsiachou/libfaketime:v0.9.13-glibc2.31 /usr/local/lib/faketime/ /usr/local/lib/faketime/
```

Then preload it for the process that needs a fake clock:

```sh
LIB=/usr/local/lib/faketime/libfaketime.so.1

LD_PRELOAD=$LIB FAKETIME='+1d' date                   # one day ahead
LD_PRELOAD=$LIB FAKETIME='2020-01-01 00:00:00' date   # frozen clock
LD_PRELOAD=$LIB FAKETIME='@2020-01-01 00:00:00' date  # anchored, keeps advancing
```

Or copy the files onto the host first:

```sh
cid=$(docker create arsiachou/libfaketime:v0.9.13-glibc2.31)
docker cp "$cid:/usr/local/lib/faketime/." ./faketime
docker rm "$cid"
```

## Tags

Images are tagged `v<version>-glibc<A.B>-debian<major>[.<point>]`. The `glibc`
component is the ABI floor the library was compiled against; the `debian`
component only selects the carrier base system. Pick the lowest floor at or
below your target's glibc:

| tag (glibc2.31 shown) | meaning |
|---|---|
| `v0.9.13-glibc2.31-debian11.11` | exact point release, never moves |
| `v0.9.13-glibc2.31-debian11` | follows the Debian 11.x line |
| `v0.9.13-glibc2.31` | baseline only, follows the newest carrier |

New baselines are published as new `-glibc` tags and leave existing tags
untouched.

A tag only exists once its carrier passed verification. A missing `-debian<N>`
tag means that version was not usable there; the short tag is only published
when the newest carrier passed.

## License

GNU General Public License, version 2 — see
[`LICENSE`](https://github.com/arsiac/libfaketime-image/blob/master/LICENSE).

This repository and the images it produces redistribute libfaketime
(<https://github.com/wolfcw/libfaketime>) under the same license.
