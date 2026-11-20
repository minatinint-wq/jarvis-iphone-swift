"""Pack the seven iPhone presets from an original GeneralUser GS 2.0.3 SF2.

Usage: python scripts/pack-instruments.py GeneralUser-GS.sf2 JarvisInstruments.sf2
All velocity layers, note zones, modulators and linked samples of the selected
presets are retained. This works with the uncompressed 16-bit GeneralUser bank.
"""
import argparse
from pathlib import Path
from struct import Struct, pack, unpack_from

FORMATS = {
    b"phdr": "<20sHHHIII", b"pbag": "<HH", b"pmod": "<HHhHH", b"pgen": "<HH",
    b"inst": "<20sH", b"ibag": "<HH", b"imod": "<HHhHH", b"igen": "<HH",
    b"shdr": "<20sIIIIIBbHH",
}
PRESETS = {(0, i) for i in (0, 24, 33, 46, 48, 73)} | {(128, 0)}


def chunks(raw):
    pos = 0
    while pos + 8 <= len(raw):
        kind, size = unpack_from("<4sI", raw, pos)
        if pos + 8 + size > len(raw):
            raise ValueError("Incomplete RIFF chunk")
        yield kind, raw[pos + 8:pos + 8 + size]
        pos += 8 + size + (size % 2)


def chunk(kind, data):
    return pack("<4sI", kind, len(data)) + data + bytes(len(data) % 2)


def subset(source):
    kind, riff = next(chunks(source))
    if kind != b"RIFF" or riff[:4] != b"sfbk":
        raise ValueError("Expected a SoundFont 2 RIFF bank")
    lists = {data[:4]: data[4:] for kind, data in chunks(riff[4:]) if kind == b"LIST"}
    wave = dict(chunks(lists[b"sdta"]))
    if set(wave) != {b"smpl"}:
        raise ValueError("Expected 16-bit PCM in smpl")
    hydra = {key: list(Struct(FORMATS[key]).iter_unpack(val))
             for key, val in chunks(lists[b"pdta"]) if key in FORMATS}
    out = {key: [] for key in FORMATS}
    samples = bytearray()
    preset_ids = [i for i, row in enumerate(hydra[b"phdr"][:-1]) if (row[2], row[1]) in PRESETS]
    if len(preset_ids) != len(PRESETS):
        raise ValueError("Missing instrument preset")

    def bags(header, idx):
        rows = hydra[header]
        col = 3 if header == b"phdr" else 1
        return range(rows[idx][col], rows[idx + 1][col])

    def zone(prefix, bag):
        current, following = hydra[prefix + b"bag"][bag:bag + 2]
        return (hydra[prefix + b"gen"][current[0]:following[0]],
                hydra[prefix + b"mod"][current[1]:following[1]])

    def linked(header, ids, op, prefix):
        return {value for i in ids for b in bags(header, i)
                for generator, value in zone(prefix, b)[0] if generator == op}

    inst_ids = sorted(linked(b"phdr", preset_ids, 41, b"p"))
    sample_ids = linked(b"inst", inst_ids, 53, b"i")
    for idx in tuple(sample_ids):
        row = hydra[b"shdr"][idx]
        if row[9] in (2, 4, 8):
            sample_ids.add(row[8])
    sample_map = {idx: j for j, idx in enumerate(sorted(sample_ids))}
    inst_map = {idx: j for j, idx in enumerate(inst_ids)}

    for idx in sample_map:
        name, start, end, loop0, loop1, rate, pitch, tune, link, typ = hydra[b"shdr"][idx]
        base = len(samples) // 2
        samples.extend(wave[b"smpl"][2 * start:2 * end])
        samples.extend(bytes(46 * 2))
        offset = base - start
        out[b"shdr"].append((name, base, end + offset, loop0 + offset, loop1 + offset, rate,
                             pitch, tune, sample_map[link] if typ in (2, 4, 8) else 0, typ))
    out[b"shdr"].append(hydra[b"shdr"][-1])

    def copy_headers(key, indices, prefix, op, remap, index_column):
        bag_key, gen_key, mod_key = (prefix + suffix for suffix in [b"bag", b"gen", b"mod"])
        def header(row):
            edit = list(row)
            edit[index_column] = len(out[bag_key])
            out[key].append(tuple(edit))
        for idx in indices:
            header(hydra[key][idx])
            for bag in bags(key, idx):
                gens, mods = zone(prefix, bag)
                out[bag_key].append((len(out[gen_key]), len(out[mod_key])))
                out[gen_key].extend((code, remap[v] if code == op else v) for code, v in gens)
                out[mod_key].extend(mods)
        header(hydra[key][-1])
        out[bag_key].append((len(out[gen_key]), len(out[mod_key])))
        out[gen_key].append((0, 0))
        out[mod_key].append((0, 0, 0, 0, 0))

    copy_headers(b"phdr", preset_ids, b"p", 41, inst_map, 3)
    copy_headers(b"inst", inst_ids, b"i", 53, sample_map, 1)
    tables = b"".join(chunk(key, b"".join(Struct(fmt).pack(*row) for row in out[key]))
                      for key, fmt in FORMATS.items())
    return chunk(b"RIFF", b"sfbk" + chunk(b"LIST", b"INFO" + lists[b"INFO"])
                 + chunk(b"LIST", b"sdta" + chunk(b"smpl", bytes(samples))) + chunk(b"LIST", b"pdta" + tables))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_bytes(subset(args.source.read_bytes()))
