#!/usr/bin/env python3
"""
Generate the RISC-V (RV32I + M) SOFTWARE test program `prog_software.hex`.

Scheme 1: the CPU performs the whole matrix multiply in software. A and B are
PRELOADED in the BRAM; the CPU reads them byte-by-byte with lbu, multiplies with
mul and accumulates with add, then writes C back with sw. No accelerator.

Run from the project root:  python3 tools/gen_prog_software.py
"""

# Register numbers.
x0 = 0
t0 = 5
t1 = 6
t2 = 7
t3 = 28
t4 = 29
t5 = 30

N        = 4
CHANNELS = 4

ADDR_A = 0x2000
ADDR_B = ADDR_A + CHANNELS * 16
ADDR_C = ADDR_B + CHANNELS * 16


def lui(rd, imm):
    return ((imm & 0xFFFFF) << 12) | (rd << 7) | 0x37


def addi(rd, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x13


def add(rd, rs1, rs2):
    return (rs2 << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x33


def mul(rd, rs1, rs2):
    return (1 << 25) | (rs2 << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x33


def sw(rs2, rs1, imm):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (2 << 12) | ((imm & 0x1F) << 7) | 0x23


def lw(rd, rs1, imm):
    imm &= 0xFFF
    return (imm << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x03


def lbu(rd, rs1, imm):
    imm &= 0xFFF
    return (imm << 20) | (rs1 << 15) | (4 << 12) | (rd << 7) | 0x03


def jal(rd, byte_offset):
    imm = byte_offset & 0xFFFFF
    instr = ((imm >> 20) & 1) << 31
    instr |= ((imm >> 1) & 0x3FF) << 21
    instr |= ((imm >> 11) & 1) << 20
    instr |= ((imm >> 12) & 0xFF) << 12
    instr |= (rd << 7)
    instr |= 0x6F
    return instr


def li(rd, imm32):
    """Load a 32-bit constant into rd (handles addi sign-extension)."""
    imm32 &= 0xFFFFFFFF
    lo = imm32 & 0xFFF
    if lo >= 0x800:
        lo = lo - 0x1000
        hi = ((imm32 >> 12) + 1) & 0xFFFFF
    else:
        hi = (imm32 >> 12) & 0xFFFFF
    instrs = [lui(rd, hi)]
    if (lo & 0xFFF) != 0:
        instrs.append(addi(rd, rd, lo & 0xFFF))
    return instrs


# A[k][i][j] = k*16 + i*4 + j + 1, B = identity, so C[k] = A[k].
def a_bytes(k):
    return [[k*N*N + i*N + j + 1 for j in range(N)] for i in range(N)]

B_bytes = [[1 if i == j else 0 for j in range(N)] for i in range(N)]

prog = []

for k in range(CHANNELS):
    A = a_bytes(k)
    prog.extend(li(t0, ADDR_A + k*16))     # A[k] base
    prog.extend(li(t1, ADDR_B + k*16))     # B[k] base
    prog.extend(li(t5, ADDR_C + k*64))     # C[k] destination base
    for i in range(N):
        for j in range(N):
            prog.append(add(t4, x0, x0))   # acc = 0
            for m in range(N):
                prog.append(lbu(t2, t0, i*4 + m))     # a = A[k][i][m]
                prog.append(lbu(t3, t1, m*4 + j))     # b = B[k][m][j]
                prog.append(mul(t2, t2, t3))          # a*b
                prog.append(add(t4, t4, t2))          # acc += a*b
            prog.append(sw(t4, t5, (i*4 + j) * 4))    # C[k][i][j] = acc

# Infinite loop.
prog.append(jal(x0, 0))

# Build the hex image: program at word 0, A at 0x800 (0x2000), B at 0x810 (0x2040).
with open("prog_software.hex", "w") as f:
    f.write("@000\n")
    for w in prog:
        f.write("%08x\n" % w)
    f.write("@800\n")
    for k in range(CHANNELS):
        for i in range(N):
            w = 0
            for j in range(N):
                w |= (k*N*N + i*N + j + 1) << (8*j)
            f.write("%08x\n" % w)
    f.write("@810\n")
    for k in range(CHANNELS):
        for i in range(N):
            w = 0
            for j in range(N):
                w |= (1 if i == j else 0) << (8*j)
            f.write("%08x\n" % w)

print("instructions:", len(prog), "bytes:", len(prog) * 4)
