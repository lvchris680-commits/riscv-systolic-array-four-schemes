#!/usr/bin/env python3
"""
Generate the RISC-V (RV32I, uncompressed) ACCELERATED test program `prog.hex`.

Matrices A and B are PRELOADED into the shared BRAM (see the @address sections
below), so the "computation phase" starts with data already in memory. The CPU
program only: writes START -> polls STATUS until done -> reads C[0][0][0] back
to a scratch location -> loops. The DMA reads A/B from the BRAM and writes C
back to the BRAM autonomously.

Run from the project root:  python3 tools/gen_prog.py
"""

# Register numbers.
x0 = 0
t0 = 5
t1 = 6
t2 = 7

N        = 4
CHANNELS = 4

ADDR_A      = 0x2000
ADDR_B      = ADDR_A + CHANNELS * 16
ADDR_C      = ADDR_B + CHANNELS * 16
ADDR_START  = 0xF000_0000
ADDR_STATUS = 0xF000_0004
SCRATCH     = 0x700


def lui(rd, imm):
    return ((imm & 0xFFFFF) << 12) | (rd << 7) | 0x37


def addi(rd, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x13


def sw(rs2, rs1, imm):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (2 << 12) | ((imm & 0x1F) << 7) | 0x23


def lw(rd, rs1, imm):
    imm &= 0xFFF
    return (imm << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x03


def beq(rs1, rs2, byte_offset):
    imm = byte_offset & 0x1FFF
    instr = ((imm >> 12) & 1) << 31
    instr |= ((imm >> 5) & 0x3F) << 25
    instr |= (rs2 << 20) | (rs1 << 15)
    instr |= ((imm >> 1) & 0xF) << 8
    instr |= ((imm >> 11) & 1) << 7
    instr |= 0x63
    return instr


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


# A[k][i][j] = k*16 + i*4 + j + 1  (each channel has distinct values 1..64).
# B = identity for every channel, so C[k] = A[k].
def a_words(k):
    ws = []
    for i in range(N):
        w = 0
        for j in range(N):
            w |= (k*N*N + i*N + j + 1) << (8*j)
        ws.append(w)
    return ws

B_words = [0x00000001, 0x00000100, 0x00010000, 0x01000000]

prog = []

# ---- START ----
prog.extend(li(t0, ADDR_START))
prog.append(addi(t1, x0, 1))
prog.append(sw(t1, t0, 0))

# ---- Poll STATUS ----
poll_pc = len(prog) * 4
prog.extend(li(t0, ADDR_STATUS))               # poll label
prog.append(lw(t2, t0, 0))
prog.append(beq(t2, x0, poll_pc - (len(prog) * 4)))

# ---- Read C[0][0][0] and store it at SCRATCH ----
prog.extend(li(t0, ADDR_C))
prog.append(lw(t1, t0, 0))
prog.extend(li(t0, SCRATCH))
prog.append(sw(t1, t0, 0))

# ---- Infinite loop ----
prog.append(jal(x0, 0))

# Build the hex image: program at word 0, A at word 0x100 (0x400), B at 0x110 (0x440).
with open("prog.hex", "w") as f:
    f.write("@000\n")
    for w in prog:
        f.write("%08x\n" % w)
    f.write("@800\n")
    for k in range(CHANNELS):
        for w in a_words(k):
            f.write("%08x\n" % w)
    f.write("@810\n")
    for k in range(CHANNELS):
        for w in B_words:
            f.write("%08x\n" % w)

print("instructions:", len(prog), "bytes:", len(prog) * 4)
