#!/usr/bin/env python3
"""
DMX binary-2 / PCF reader-writer used to build particles/lvs_gred_tracers.pcf
from Gredwitch's gred_particles.pcf.

    python3 pcf_tool.py list  <file.pcf>
    python3 pcf_tool.py dump  <file.pcf> <definition name>
    python3 pcf_tool.py build <gred_particles.pcf> <out.pcf>

What `build` does, per gred_tracers_<color>_<caliber> definition:
  * deep-copies the definition and everything it references (operators,
    child definitions), renaming every copied definition with an "lvs_"
    prefix so nothing collides with gred's own names,
  * removes the "move particles between 2 control points" initializer
    (fixed speed toward CP1, lifetime = distance / speed),
  * adds "Velocity Random" reading 1 x the CP0 forward vector -- the caller
    passes forward = direction * speed unnormalised, so the particle leaves
    at exactly the LVS round's velocity,
  * adds "Lifetime Random" 5 s (LVS's bullet lifetime cap),
  * emits two variants: "<name>" with Movement Basic gravity (0,0,-1200)
    (LVS ballistic flight is Src + Dir*V*t + g*t^2 with g = -600, i.e. an
    acceleration of 2g) and "<name>_flat" with no gravity for
    non-ballistic rounds.
Everything else -- renderer, trail, colours, sheet sequences, children -- is
gred's, byte for byte.
"""
import os
import struct
import sys

HEADER = b"<!-- dmx encoding binary 2 format pcf 1 -->\n\0"

T_ELEMENT, T_INT, T_FLOAT, T_BOOL, T_STRING, T_BINARY, T_OBJECTID, T_COLOR = range(1, 9)
T_VEC2, T_VEC3, T_VEC4, T_QANGLE, T_QUAT, T_MATRIX = range(9, 15)
ARRAY_OFFSET = 14


class Element:
    def __init__(self, etype, name, guid):
        self.type = etype
        self.name = name
        self.guid = guid
        self.attrs = []   # list of [name, type, value]; element values are Element refs (or None)

    def get(self, name):
        for a in self.attrs:
            if a[0] == name:
                return a[2]
        return None

    def set(self, name, value):
        for a in self.attrs:
            if a[0] == name:
                a[2] = value
                return
        raise KeyError(name)

    def __repr__(self):
        return "[%s] %s" % (self.type, self.name)


class Reader:
    def __init__(self, data):
        self.d = data
        self.p = data.index(b"\n") + 2
        n = self.i16()
        self.strings = [self.cstr() for _ in range(n)]
        nel = self.i32()
        self.elements = []
        for _ in range(nel):
            t = self.strings[self.i16()]
            name = self.cstr()
            guid = self.d[self.p:self.p + 16]
            self.p += 16
            self.elements.append(Element(t, name, guid))
        for e in self.elements:
            na = self.i32()
            for _ in range(na):
                an = self.strings[self.i16()]
                t = self.d[self.p]
                self.p += 1
                if t > ARRAY_OFFSET:
                    cnt = self.i32()
                    val = [self.value(t - ARRAY_OFFSET) for _ in range(cnt)]
                else:
                    val = self.value(t)
                e.attrs.append([an, t, val])

    def i16(self):
        v = struct.unpack_from("<h", self.d, self.p)[0]
        self.p += 2
        return v

    def i32(self):
        v = struct.unpack_from("<i", self.d, self.p)[0]
        self.p += 4
        return v

    def cstr(self):
        e = self.d.index(b"\0", self.p)
        s = self.d[self.p:e].decode("latin1")
        self.p = e + 1
        return s

    def raw(self, fmt):
        v = struct.unpack_from("<" + fmt, self.d, self.p)
        self.p += struct.calcsize("<" + fmt)
        return v if len(v) > 1 else v[0]

    def value(self, t):
        if t == T_ELEMENT:
            idx = self.i32()
            return self.elements[idx] if idx >= 0 else None
        if t == T_INT:
            return self.i32()
        if t == T_FLOAT:
            return self.raw("f")
        if t == T_BOOL:
            return self.raw("B")
        if t == T_STRING:
            return self.cstr()
        if t == T_BINARY:
            n = self.i32()
            b = self.d[self.p:self.p + n]
            self.p += n
            return b
        if t == T_OBJECTID:
            b = self.d[self.p:self.p + 16]
            self.p += 16
            return b
        if t == T_COLOR:
            return self.raw("4B")
        if t in (T_VEC2,):
            return self.raw("2f")
        if t in (T_VEC3, T_QANGLE):
            return self.raw("3f")
        if t in (T_VEC4, T_QUAT):
            return self.raw("4f")
        if t == T_MATRIX:
            return self.raw("16f")
        raise ValueError("unknown attribute type %d" % t)


class Writer:
    def __init__(self, elements):
        self.elements = elements
        self.index = {id(e): i for i, e in enumerate(elements)}
        self.strings = []
        self.sidx = {}
        for e in elements:
            self.intern(e.type)
            for a in e.attrs:
                self.intern(a[0])

    def intern(self, s):
        if s not in self.sidx:
            self.sidx[s] = len(self.strings)
            self.strings.append(s)
        return self.sidx[s]

    def cstr(self, s):
        return s.encode("latin1") + b"\0"

    def value(self, t, v):
        if t == T_ELEMENT:
            return struct.pack("<i", self.index[id(v)] if v is not None else -1)
        if t == T_INT:
            return struct.pack("<i", v)
        if t == T_FLOAT:
            return struct.pack("<f", v)
        if t == T_BOOL:
            return struct.pack("<B", v)
        if t == T_STRING:
            return self.cstr(v)
        if t == T_BINARY:
            return struct.pack("<i", len(v)) + v
        if t == T_OBJECTID:
            return v
        if t == T_COLOR:
            return struct.pack("<4B", *v)
        if t == T_VEC2:
            return struct.pack("<2f", *v)
        if t in (T_VEC3, T_QANGLE):
            return struct.pack("<3f", *v)
        if t in (T_VEC4, T_QUAT):
            return struct.pack("<4f", *v)
        if t == T_MATRIX:
            return struct.pack("<16f", *v)
        raise ValueError("unknown attribute type %d" % t)

    def build(self):
        out = [HEADER, struct.pack("<h", len(self.strings))]
        for s in self.strings:
            out.append(self.cstr(s))
        out.append(struct.pack("<i", len(self.elements)))
        for e in self.elements:
            out.append(struct.pack("<h", self.sidx[e.type]))
            out.append(self.cstr(e.name))
            out.append(e.guid)
        for e in self.elements:
            out.append(struct.pack("<i", len(e.attrs)))
            for an, t, v in e.attrs:
                out.append(struct.pack("<hB", self.sidx[an], t))
                if t > ARRAY_OFFSET:
                    out.append(struct.pack("<i", len(v)))
                    for item in v:
                        out.append(self.value(t - ARRAY_OFFSET, item))
                else:
                    out.append(self.value(t, v))
        return b"".join(out)


def definitions(reader):
    return [e for e in reader.elements if e.type == "DmeParticleSystemDefinition"]


def dump(e, indent=0, seen=None):
    seen = seen or set()
    print(" " * indent + repr(e))
    for an, t, v in e.attrs:
        if t == T_ELEMENT + ARRAY_OFFSET:
            print(" " * indent + "  %s:" % an)
            for c in v:
                if c is not None and id(c) not in seen:
                    seen.add(id(c))
                    dump(c, indent + 4, seen)
        elif t == T_ELEMENT:
            print(" " * indent + "  %s -> %r" % (an, v))
        elif an != "functionName":
            print(" " * indent + "  %s = %r" % (an, v))


# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------
def deep_copy(e, memo):
    if id(e) in memo:
        return memo[id(e)]
    c = Element(e.type, e.name, os.urandom(16))
    memo[id(e)] = c
    for an, t, v in e.attrs:
        if t == T_ELEMENT:
            c.attrs.append([an, t, deep_copy(v, memo) if v is not None else None])
        elif t == T_ELEMENT + ARRAY_OFFSET:
            c.attrs.append([an, t, [deep_copy(x, memo) if x is not None else None for x in v]])
        elif isinstance(v, list):
            c.attrs.append([an, t, list(v)])
        else:
            c.attrs.append([an, t, v])
    return c


def reachable(e, acc):
    if id(e) in acc:
        return
    acc[id(e)] = e
    for an, t, v in e.attrs:
        if t == T_ELEMENT and v is not None:
            reachable(v, acc)
        elif t == T_ELEMENT + ARRAY_OFFSET:
            for x in v:
                if x is not None:
                    reachable(x, acc)


def find_operator(defs, function_name):
    """First operator element named `function_name` anywhere in the given definitions."""
    for d in defs:
        for key in ("initializers", "operators", "emitters", "renderers"):
            for op in d.get(key) or []:
                if op is not None and op.name == function_name:
                    return op
    return None


def make_operator(template, values):
    op = deep_copy(template, {})
    for k, v in values.items():
        op.set(k, v)
    return op


def build(src_path, out_path):
    reader = Reader(open(src_path, "rb").read())
    defs = definitions(reader)
    tracers = [d for d in defs if d.name.startswith("gred_tracers_")]
    if not tracers:
        raise SystemExit("no gred_tracers_* definitions in " + src_path)

    lifetime_tpl = find_operator(defs, "Lifetime Random")
    velocity_tpl = find_operator(defs, "Velocity Random")
    if lifetime_tpl is None or velocity_tpl is None:
        raise SystemExit("template operators not found")

    # Child definitions (smoke rope, glows) are shared by every tracer: copy
    # each exactly once so the output has no duplicate definition names.
    shared = {}
    tracer_ids = {id(d) for d in tracers}
    for d in tracers:
        acc = {}
        reachable(d, acc)
        for e in acc.values():
            if e.type == "DmeParticleSystemDefinition" and id(e) not in tracer_ids and id(e) not in shared:
                copy = deep_copy(e, shared)
                copy.name = "lvs_" + e.name
    for copy in list(shared.values()):
        if copy.type == "DmeParticleSystemDefinition" and not copy.name.startswith("lvs_"):
            copy.name = "lvs_" + copy.name

    new_defs = []
    for d in tracers:
        for suffix, gravity in (("", (0.0, 0.0, -1200.0)), ("_flat", (0.0, 0.0, 0.0))):
            memo = dict(shared)
            c = deep_copy(d, memo)
            c.name = "lvs_" + d.name + suffix

            inits = [op for op in c.get("initializers") if op.name != "move particles between 2 control points"]
            if len(inits) == len(c.get("initializers")):
                raise SystemExit("%s has no move-between-points initializer" % d.name)
            inits.append(make_operator(velocity_tpl, {
                "control_point_number": 0,
                "random_speed_min": 0.0,
                "random_speed_max": 0.0,
                "speed_in_local_coordinate_system_min": (1.0, 0.0, 0.0),
                "speed_in_local_coordinate_system_max": (1.0, 0.0, 0.0),
            }))
            inits.append(make_operator(lifetime_tpl, {
                "lifetime_min": 5.0,
                "lifetime_max": 5.0,
                "lifetime_random_exponent": 1.0,
            }))
            c.set("initializers", inits)

            moved = False
            for op in c.get("operators"):
                if op.name == "Movement Basic":
                    op.set("gravity", gravity)
                    moved = True
            if not moved:
                raise SystemExit("%s has no Movement Basic operator" % d.name)

            new_defs.append(c)

    # root element listing the definitions, then everything reachable
    root = Element("DmElement", "particleSystemDefinitions", os.urandom(16))
    root.attrs.append(["particleSystemDefinitions", T_ELEMENT + ARRAY_OFFSET, new_defs])
    acc = {}
    reachable(root, acc)
    elements = [root] + [e for e in acc.values() if e is not root]

    data = Writer(elements).build()
    open(out_path, "wb").write(data)

    # verify round trip
    check = Reader(data)
    names = sorted(e.name for e in definitions(check))
    print("wrote %s: %d elements, %d definitions" % (out_path, len(check.elements), len(names)))
    for n in names:
        print("  " + n)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return
    cmd, path = sys.argv[1], sys.argv[2]
    if cmd == "list":
        for d in definitions(Reader(open(path, "rb").read())):
            print(d.name)
    elif cmd == "dump":
        r = Reader(open(path, "rb").read())
        for d in definitions(r):
            if d.name == sys.argv[3]:
                dump(d)
    elif cmd == "build":
        build(path, sys.argv[3])
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
