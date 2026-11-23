"""Cross-target framing and aggregation fixtures."""

def boundary_rejections():
    for boundary in (512, 8192):
        # A valid frame ends one byte before the boundary. Its successor's
        # length straddles the boundary, and offsets include the valid prefix.
        prefix = (boundary - 3).to_bytes(2, "big") + b"\x07" + bytes(boundary - 4)
        for suffix, offset in [(b"\x00", boundary), (b"\x00\x00", boundary - 1),
                               (b"\x00\x01", boundary + 1), (b"\x00\x01\x40", boundary + 1),
                               (b"\x00\x03\x01a", boundary + 3)]:
            yield prefix + suffix, offset

def all_keys():
    # Visit every slot twice in reverse order, including both empty and
    # nonempty payloads. The canonical output must return keys in ascending order.
    stream = bytearray()
    for key in reversed(range(64)):
        stream.extend((0, 1, key))
        stream.extend((0, 3, key, key, 255))
    expected = "".join(f"{key} 2 2 {key + 255}\n" for key in range(64))
    return bytes(stream), expected.encode("ascii")
