# RISC-V CPU + Systolic-Array Matrix Multiply: Four Integration Schemes

A small SystemVerilog SoC that computes `CHANNELS` independent 4×4 matrix
multiplies (`C[k] = A[k] * B[k]`) using a **PicoRV32 RISC-V CPU** and a
**4×4 systolic-array accelerator**, integrated four different ways to compare
CPU/accelerator interaction styles:

| Scheme | Integration | CPU role | Accelerator role |
|---|---|---|---|
| 1 | Pure software | does everything | none |
| 2 | Memory-mapped (AXI4-Lite register slave) | moves data BRAM↔IP | computes |
| 3 | PCPI co-processor (custom instructions) | moves data BRAM↔regs | computes |
| 4 | DMA + shared BRAM + 2-master arbiter | triggers + polls | computes **and** moves data |

The highlight is a hand-written, single-outstanding, round-robin
**AXI4-Lite arbiter** (`rtl/scheme4_dma/axi_lite_arbiter_2m1s.sv`) that
multiplexes two masters onto one slave (Scheme 4).

---

## The four schemes

```
scheme1 (software)        CPU --load/store--> BRAM          (CPU computes C = A*B)
scheme2 (memory-mapped)   CPU --AXI--> IP registers         (CPU copies data, IP computes)
scheme3 (PCPI)            CPU --custom insn--> co-processor (CPU copies data, IP computes)
scheme4 (DMA)             CPU + DMA --arbiter--> BRAM       (DMA moves data, IP computes)
```

* **Scheme 1** — no accelerator. The CPU reads A/B byte-by-byte with `lbu`,
  multiplies with `mul` (hardware multiplier enabled) and accumulates with
  `add`. This is the software baseline.
* **Scheme 2** — the systolic array is an AXI4-Lite register slave
  (`systolic_ip_axi_lite`). The CPU copies A/B from the BRAM into the IP
  registers, triggers it, and copies C back. One master, address-decoded.
* **Scheme 3** — the systolic array is a PCPI co-processor
  (`pcpi_sys_array_wrapper`). The CPU loads A/B with custom `LOAD` instructions,
  starts it with `START`, and reads C with `READ`. No AXI on the accelerator path.
* **Scheme 4** — the systolic array has its own AXI master (`sys_array_dma`)
  and reads A/B / writes C autonomously through the arbiter. The CPU just writes
  `START` and polls `STATUS`.

---

## Directory layout

```
.
├── rtl/
│   ├── common/                   Shared RTL
│   │   ├── soc_pkg.sv                Address map / constants (package)
│   │   ├── systolic_array.sv         4x4 systolic array (skew schedule internal)
│   │   ├── pe.sv                     Processing element (8-bit MAC)
│   │   └── bram_ctrl_axi_lite.sv     BRAM + CSR AXI4-Lite slave
│   ├── scheme1_software/
│   │   └── top_software.sv           CPU-only (hardware mul)
│   ├── scheme2_mmio/
│   │   ├── systolic_ip_axi_lite.sv   IP as an AXI4-Lite register slave
│   │   ├── axi_lite_addr_decode.sv   1-master -> 2-slave address decoder
│   │   └── top_baseline.sv
│   ├── scheme3_pcpi/
│   │   ├── pcpi_sys_array_wrapper.sv PCPI co-processor wrapper
│   │   └── top_pcpi.sv
│   └── scheme4_dma/
│       ├── axi_lite_arbiter_2m1s.sv  2-master -> 1-slave arbiter (the hard part)
│       ├── sys_array_dma.sv          IP-side AXI master / DMA
│       ├── soc_top.sv
│       └── top_cpu.sv
├── third_party/
│   └── picorv32.v            PicoRV32 CPU (ISC license, see below)
├── tb/                       Testbenches (tb_sa / tb_software / tb_baseline / tb_pcpi / tb_soc / tb_cpu)
├── tools/                    RISC-V program generators (gen_prog*.py)
├── deprecated/               Old, unused sources (kept for reference)
├── Makefile
├── LICENSE                   MIT (applies to the code in this repo, except third_party/)
└── README.md
```

---

## Address map

The program lives at the bottom of the BRAM; the data region starts at
`0x2000`. Matrices scale with `CHANNELS`: channel `k` of A/B/C is placed at
`base + k * bytes_per_channel`.

| Address | Size | Purpose |
|---------|------|---------|
| `0x000` – `0x1FFF` | 8 KB  | CPU program (in BRAM) |
| `0x2000` | 16 B/ch | Matrix A[k] (4 × 32-bit, 8-bit elements) |
| `ADDR_B` | 16 B/ch | Matrix B[k] |
| `ADDR_C` | 64 B/ch | Matrix C[k] (16 × 32-bit) |
| `0x4000` | — | Baseline IP register base (Scheme 2) |
| `0xF000_0000` | 4 B | CSR `START` — any write triggers the DMA |
| `0xF000_0004` | 4 B | CSR `STATUS` — bit 0 = DMA done |

The BRAM is 4096 × 32-bit (16 KB). `N = 4` (array) and `CHANNELS = 4` (batch)
are parameters in `soc_pkg.sv`; changing `CHANNELS` scales the workload without
tiling.

---

## Requirements & running

* [Verilator](https://www.verilator.org/) **>= 5** (needs `--timing`).
* Python 3 (only for regenerating the `.hex` programs).
* `make`.

```bash
make all          # run all six testbenches
make tb_sa        # systolic-array standalone
make tb_software  # scheme 1
make tb_baseline  # scheme 2
make tb_pcpi      # scheme 3
make tb_soc       # scheme 4 interconnect (BFM) test
make tb_cpu       # scheme 4 full CPU-system test
make clean
```

> The repository path may contain spaces/non-ASCII characters; the `Makefile`
> therefore builds into `/tmp` via `-Mdir`.

### Expected output

```
TB_SA:  done asserted, array latency (start->done) = 12 cycles
TB_SA  PASS: C == A*B
TB_SOFTWARE:  computation latency (reset release -> C in BRAM) = 15710 cycles
TB_SOFTWARE  PASS: software matmul -> C == A*B (4 channels)
TB_BASELINE:  computation latency (reset release -> C in BRAM) = 2381 cycles
TB_BASELINE  PASS: CPU moves data BRAM<->IP -> C == A*B (4 channels)
TB_PCPI:  computation latency (reset release -> C in BRAM) = 1766 cycles
TB_PCPI  PASS: PCPI co-processor -> C == A*B (4 channels)
TB_SOC: DMA done, latency (START write -> done) = 505 cycles
TB_SOC PASS: C == A*B (4 channels)
TB_CPU: dma_done asserted, computation latency (reset release -> done) = 513 cycles
TB_CPU PASS: CPU configures data -> DMA moves it -> C == A*B (4 channels)
```

---

## The comparison

All four schemes compute the same `CHANNELS = 4` matrix multiplies. A and B are
**preloaded into the shared BRAM** and we measure the *computation phase* — from
reset release to the moment C is fully written back into the BRAM.

| Scheme | Computation (4 channels) | Speedup | What it offloads |
|---|---|---|---|
| 1 · software | **15710 cycles** | 1.0× | — |
| 2 · memory-mapped | **2381 cycles** | 6.6× | compute → array |
| 3 · PCPI | **1766 cycles** | 8.9× | compute → array (tighter interface) |
| 4 · DMA | **513 cycles** | 30.6× | compute **and** data movement |

**Scheme 1 → 2 (6.6×):** the systolic array does the multiply-accumulate in one
clock per PE instead of the CPU running ~1000 `lbu`/`mul`/`add` instructions.

**Scheme 2 → 3 (1.35×):** the PCPI custom instructions move data
register-to-register without an AXI round-trip per word, so the CPU↔accelerator
coupling is tighter than the memory-mapped register slave.

**Scheme 3 → 4 (3.4×):** the DMA removes the CPU from the data path entirely.
It reads A/B straight out of the BRAM and writes C straight back — 24 bus
transactions per channel instead of the 48 the CPU needs to copy data through
the accelerator registers (Scheme 2) or the register file (Scheme 3).

The takeaway: an accelerator only pays off if both the *compute* and the *data
movement* are offloaded. A fast systolic array behind a CPU-bound register
interface (Schemes 2 and 3) still leaves the CPU as the bottleneck.

---

## The arbiter (the interesting part, Scheme 4)

`rtl/scheme4_dma/axi_lite_arbiter_2m1s.sv` arbitrates two AXI4-Lite masters
onto one slave:

* Read (AR/R) and write (AW/W/B) paths are arbitrated **independently**.
* **Round-robin** fairness — a token flips after every grant.
* **Single outstanding** transaction: a write keeps the grant from AW through B,
  a read keeps it from AR through R, so the response always returns to the
  correct master.
* Every `ready` is gated by *"this master has the grant and we are in the right
  state"*, so a losing master sees `ready == 0` and must hold `valid`, exactly
  as the AXI handshake requires.

---

## Third-party code

* `third_party/picorv32.v` — [PicoRV32](https://github.com/YosysHQ/picorv32)
  by Claire Wolf, distributed under the **ISC license** (its header is kept
  intact). It is not covered by this repository's MIT license.
* `rtl/common/pe.sv` is a generic 8-bit multiply-accumulate processing element.

## License

The code in this repository (except `third_party/`) is MIT-licensed; see
[`LICENSE`](LICENSE).
