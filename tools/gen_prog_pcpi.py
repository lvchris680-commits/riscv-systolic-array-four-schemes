#!/usr/bin/env python3
"""
Generate the RISC-V (RV32I + custom-0) PCPI test program `prog_pcpi.hex`.

Scheme 3: the systolic array is a PCPI co-processor. A and B are PRELOADED in
the BRAM; the CPU loads them into the co-processor with custom LOAD
instructions, starts it with a custom START, and reads C back with custom READ
instructions, storing it into the BRAM.

Run from the project root:  python3 tools/gen_prog_pcpi.py
"""

# Register numbers.
x0 = 0
t0 = 5
t1 = 6
t2 = 7
t3 = 28
t4 = 29

N        = 4
CHANNELS = 4

ADDR_A = 0x2000
ADDR_B = ADDR_A + CHANNELS * 16
ADDR_C = ADDR_B + CHANNELS * 16


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


def custom(funct3, rs1, rs2, rd=0):
    """Custom-0 instruction (opcode 0001011)."""
    return (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x0B


# A[k][i][j] = k*16 + i*4 + j + 1, B = identity, so C[k] = A[k].
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

for k in range(CHANNELS):
    # Load A[k].
    prog.extend(li(t4, ADDR_A + k*16))
    for i in range(N):
        prog.append(lw(t0, t4, i*4))
        prog.append(addi(t1, x0, i))             # select A, row i
        prog.append(custom(0, t0, t1))           # LOAD
    # Load B[k].
    prog.extend(li(t4, ADDR_B + k*16))
    for i in range(N):
        prog.append(lw(t0, t4, i*4))
        prog.append(addi(t1, x0, N + i))         # select B, row i
        prog.append(custom(0, t0, t1))           # LOAD
    # Start.
    prog.append(custom(1, x0, x0))               # START
    # Read C[k] back into the BRAM.
    prog.extend(li(t3, ADDR_C + k*64))
    for j in range(N*N):
        prog.append(addi(t1, x0, j))             # C index
        prog.append(custom(2, t1, x0, t2))       # READ -> t2
        prog.append(sw(t2, t3, j*4))

# Infinite loop.
prog.append(jal(x0, 0))

# Build the hex image: program at word 0, A at 0x800 (0x2000), B at 0x810 (0x2040).
with open("prog_pcpi.hex", "w") as f:
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
