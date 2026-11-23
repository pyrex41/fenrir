"""Read the standalone execution profile from a linked ARM64 image's named section."""
import re
import struct


def section_bytes(image, offset, size):
    if offset + size > len(image):
        raise ValueError("section extends beyond the native image")
    return image[offset:offset + size]


def macho_sections(image):
    # A thin little-endian mach_header_64 followed by its load commands.
    cpu, _, filetype, count, command_size = struct.unpack_from("<5I", image, 4)
    if cpu != 0x0100000C or filetype != 2:
        return
    offset = 32
    end = offset + command_size
    if end > len(image):
        raise ValueError("truncated Mach-O load commands")
    for _ in range(count):
        command, size = struct.unpack_from("<II", image, offset)
        if size < 8 or offset + size > end:
            raise ValueError("invalid Mach-O load command size")
        if command == 0x19:  # LC_SEGMENT_64
            if size < 72:
                raise ValueError("truncated Mach-O segment")
            entries, = struct.unpack_from("<I", image, offset + 64)
            if 72 + entries * 80 != size:
                raise ValueError("invalid Mach-O section table")
            if image[offset+8:offset+24].rstrip(b"\0") == b"__TEXT":
                for index in range(entries):
                    start = offset + 72 + index * 80
                    name, segment, _, length, file_offset = struct.unpack_from("<16s16sQQI", image, start)
                    if name.rstrip(b"\0") == b"__fenrir_profile" and segment.rstrip(b"\0") == b"__TEXT":
                        flags, = struct.unpack_from("<I", image, start + 64)
                        if flags & 0xff:  # S_REGULAR
                            raise ValueError("invalid Mach-O execution profile section type")
                        yield section_bytes(image, file_offset, length)
        offset += size
    if offset != end:
        raise ValueError("invalid Mach-O load command count")


def elf_sections(image):
    # ELF64 little-endian section headers; no dependency on host binutils.
    if image[4:7] != b"\x02\x01\x01":
        return
    filetype, machine = struct.unpack_from("<HH", image, 16)
    if machine != 183 or filetype not in (2, 3):  # AArch64 ET_EXEC / ET_DYN
        return
    table, = struct.unpack_from("<Q", image, 40)
    width, count, strings = struct.unpack_from("<HHH", image, 58)
    if not table:
        if count or strings:
            raise ValueError("missing ELF section table")
        return
    if width < 64:
        raise ValueError("invalid ELF section header size")
    if not count:
        count, = struct.unpack_from("<Q", image, table + 32)  # Extended numbering
    if strings == 0xffff:
        strings, = struct.unpack_from("<I", image, table + 40)
    if table + width * count > len(image) or strings >= count:
        raise ValueError("invalid ELF section table bounds")
    if not strings:
        return
    str_header = table + width * strings
    str_type, = struct.unpack_from("<I", image, str_header + 4)
    if str_type != 3:  # SHT_STRTAB
        raise ValueError("invalid ELF section name table")
    names = section_bytes(image, *struct.unpack_from("<QQ", image, str_header + 24))
    for index in range(count):
        header = table + width * index
        name, kind, flags = struct.unpack_from("<IIQ", image, header)
        if names.startswith(b".fenrir.profile\0", name):
            if kind != 1 or not flags & 2:  # SHT_PROGBITS, SHF_ALLOC
                raise ValueError("invalid ELF execution profile section type")
            yield section_bytes(image, *struct.unpack_from("<QQ", image, header + 24))


def image_profile(image_bytes, target):
    if image_bytes[:4] == b"\xcf\xfa\xed\xfe":
        image_target, sections = "macos-arm64", macho_sections(image_bytes)
    elif image_bytes[:4] == b"\x7fELF":
        image_target, sections = "solo5-arm64-spt", elf_sections(image_bytes)
    else:
        return None
    try:
        section = next(sections, None)
        if section is None:
            return None
        if next(sections, None) is not None:
            raise ValueError("ambiguous execution profile sections in image")
    except struct.error as exc:
        raise ValueError("truncated native image section metadata") from exc
    stamp = re.fullmatch(rb"\0FENRIR-EXEC-PROFILE\0([a-z0-9/-]+)\0([a-z0-9-]+)\0([0-9a-f]{64})\0", section)
    if stamp is None or stamp[2].decode() != image_target or target != image_target:
        raise ValueError("invalid execution profile or target mismatch in image")
    return {"id": stamp[1].decode(), "sha256": stamp[3].decode()}
