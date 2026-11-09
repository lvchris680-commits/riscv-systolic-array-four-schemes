`default_nettype none
// ============================================================================
// soc_pkg : global address map and constants shared by all modules.
// Every module imports this package to avoid address drift.
// ============================================================================
package soc_pkg;

    // Matrix dimension (N x N systolic array). The 4 x 4 array is fixed; the
    // "batch/channel" dimension CHANNELS scales the amount of work by running
    // CHANNELS independent 4x4 matmuls (C[k] = A[k] * B[k]).
    localparam int unsigned N        = 4;    // N x N PE grid
    localparam int unsigned CHANNELS = 4;    // number of independent 4x4 matmuls

    // Per-channel storage (bytes): A/B are 4x4 x 8-bit = 16 B, C is 4x4 x 32-bit = 64 B.
    localparam int unsigned A_BYTES = N*N;         // 16
    localparam int unsigned C_BYTES = N*N*4;       // 64

    // Address map (byte addresses). A/B/C live in the shared BRAM below the
    // IP_BASE boundary; both the accelerated DMA and the baseline CPU read A/B
    // from here and write C back here, so the comparison starts from the same
    // "data already in memory" state.
    localparam logic [31:0] ADDR_PROG   = 32'h0000_0000;   // CPU program region (in BRAM)
    localparam logic [31:0] ADDR_A      = 32'h0000_2000;   // A[ch] at +ch*16
    localparam logic [31:0] ADDR_B      = ADDR_A + CHANNELS*A_BYTES;
    localparam logic [31:0] ADDR_C      = ADDR_B + CHANNELS*A_BYTES;
    localparam logic [31:0] IP_BASE     = 32'h0000_4000;   // baseline IP register base
    localparam logic [31:0] ADDR_START  = 32'hF000_0000;   // CSR: any write triggers the DMA
    localparam logic [31:0] ADDR_STATUS = 32'hF000_0004;   // CSR: bit0 = DMA done flag

    // BRAM: 4096 x 32-bit = 16 KB, covering 0x0000 .. 0x3FFF.
    localparam int unsigned BRAM_WORDS = 4096;
    localparam int unsigned BRAM_AW    = 12;   // log2(BRAM_WORDS)

endpackage
`resetall
