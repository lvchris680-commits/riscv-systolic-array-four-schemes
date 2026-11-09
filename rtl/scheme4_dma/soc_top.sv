`default_nettype none
// ============================================================================
// soc_top
// Connects the CPU (master 0) and the systolic-array DMA (master 1) to the
// shared BRAM through the arbiter. Only the CPU-side AXI master port (m0) is
// exposed here; the DMA is internal.
// ============================================================================
module soc_top #(
    parameter string INIT_FILE = ""    // hex file preloaded into BRAM in simulation
) (
    input  logic clk,
    input  logic rst_n,                 // active-low reset

    // ---------- Master 0 (CPU) AXI4-Lite ----------
    // AW
    input  logic [31:0] m0_awaddr,
    input  logic        m0_awvalid,
    output logic        m0_awready,
    // W
    input  logic [31:0] m0_wdata,
    input  logic [3:0]  m0_wstrb,
    input  logic        m0_wvalid,
    output logic        m0_wready,
    // B
    output logic        m0_bvalid,
    input  logic        m0_bready,
    output logic [1:0]  m0_bresp,
    // AR
    input  logic [31:0] m0_araddr,
    input  logic        m0_arvalid,
    output logic        m0_arready,
    // R
    output logic        m0_rvalid,
    input  logic        m0_rready,
    output logic [31:0] m0_rdata,
    output logic [1:0]  m0_rresp,

    // ---------- Observation signals (simulation / debug) ----------
    output logic              dma_done,
    input  logic [BRAM_AW-1:0] dbg_raddr,
    output logic [31:0]       dbg_rdata
);

    import soc_pkg::*;

    // DMA (m1) AXI master signals.
    logic [31:0] m1_awaddr;
    logic        m1_awvalid;
    logic        m1_awready;
    logic [31:0] m1_wdata;
    logic [3:0]  m1_wstrb;
    logic        m1_wvalid;
    logic        m1_wready;
    logic        m1_bvalid;
    logic        m1_bready;
    logic [1:0]  m1_bresp;
    logic [31:0] m1_araddr;
    logic        m1_arvalid;
    logic        m1_arready;
    logic        m1_rvalid;
    logic        m1_rready;
    logic [31:0] m1_rdata;
    logic [1:0]  m1_rresp;

    // Arbiter slave side (to the BRAM controller).
    logic [31:0] s_awaddr;
    logic        s_awvalid;
    logic        s_awready;
    logic [31:0] s_wdata;
    logic [3:0]  s_wstrb;
    logic        s_wvalid;
    logic        s_wready;
    logic        s_bvalid;
    logic        s_bready;
    logic [1:0]  s_bresp;
    logic [31:0] s_araddr;
    logic        s_arvalid;
    logic        s_arready;
    logic        s_rvalid;
    logic        s_rready;
    logic [31:0] s_rdata;
    logic [1:0]  s_rresp;

    // CSR -> DMA.
    logic start_pulse;

    // DMA <-> systolic array.
    logic [N-1:0][N-1:0][7:0]  sa_a;
    logic [N-1:0][N-1:0][7:0]  sa_b;
    logic                      sa_start;
    logic [N-1:0][N-1:0][31:0] sa_c;
    logic                      sa_done;

    // ---- Arbiter ----
    axi_lite_arbiter_2m1s u_arbiter (
        .clk      (clk),
        .rst_n    (rst_n),
        // m0
        .m0_awaddr (m0_awaddr),  .m0_awvalid(m0_awvalid), .m0_awready(m0_awready),
        .m0_wdata  (m0_wdata),   .m0_wstrb(m0_wstrb),     .m0_wvalid(m0_wvalid),
        .m0_wready (m0_wready),
        .m0_bvalid (m0_bvalid),  .m0_bready(m0_bready),   .m0_bresp(m0_bresp),
        .m0_araddr (m0_araddr),  .m0_arvalid(m0_arvalid), .m0_arready(m0_arready),
        .m0_rvalid (m0_rvalid),  .m0_rready(m0_rready),   .m0_rdata(m0_rdata),
        .m0_rresp  (m0_rresp),
        // m1
        .m1_awaddr (m1_awaddr),  .m1_awvalid(m1_awvalid), .m1_awready(m1_awready),
        .m1_wdata  (m1_wdata),   .m1_wstrb(m1_wstrb),     .m1_wvalid(m1_wvalid),
        .m1_wready (m1_wready),
        .m1_bvalid (m1_bvalid),  .m1_bready(m1_bready),   .m1_bresp(m1_bresp),
        .m1_araddr (m1_araddr),  .m1_arvalid(m1_arvalid), .m1_arready(m1_arready),
        .m1_rvalid (m1_rvalid),  .m1_rready(m1_rready),   .m1_rdata(m1_rdata),
        .m1_rresp  (m1_rresp),
        // s
        .s_awaddr  (s_awaddr),   .s_awvalid(s_awvalid),   .s_awready(s_awready),
        .s_wdata   (s_wdata),    .s_wstrb(s_wstrb),       .s_wvalid(s_wvalid),
        .s_wready  (s_wready),
        .s_bvalid  (s_bvalid),   .s_bready(s_bready),     .s_bresp(s_bresp),
        .s_araddr  (s_araddr),   .s_arvalid(s_arvalid),   .s_arready(s_arready),
        .s_rvalid  (s_rvalid),   .s_rready(s_rready),     .s_rdata(s_rdata),
        .s_rresp   (s_rresp)
    );

    // ---- BRAM controller (AXI slave + CSRs) ----
    bram_ctrl_axi_lite #(.INIT_FILE(INIT_FILE)) u_bram (
        .clk         (clk),
        .rst_n       (rst_n),
        .dma_done    (dma_done),
        .start_pulse (start_pulse),
        .dbg_raddr   (dbg_raddr),
        .dbg_rdata   (dbg_rdata),
        .s_awaddr    (s_awaddr),  .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata     (s_wdata),   .s_wstrb(s_wstrb),     .s_wvalid(s_wvalid),
        .s_wready    (s_wready),
        .s_bvalid    (s_bvalid),  .s_bready(s_bready),   .s_bresp(s_bresp),
        .s_araddr    (s_araddr),  .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rvalid    (s_rvalid),  .s_rready(s_rready),   .s_rdata(s_rdata),
        .s_rresp     (s_rresp)
    );

    // ---- DMA (master 1) ----
    sys_array_dma #(.N(N)) u_dma (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (start_pulse),
        .done      (dma_done),
        .sa_a      (sa_a),
        .sa_b      (sa_b),
        .sa_start  (sa_start),
        .sa_c      (sa_c),
        .sa_done   (sa_done),
        .m_awaddr  (m1_awaddr),  .m_awvalid(m1_awvalid), .m_awready(m1_awready),
        .m_wdata   (m1_wdata),   .m_wstrb(m1_wstrb),     .m_wvalid(m1_wvalid),
        .m_wready  (m1_wready),
        .m_bvalid  (m1_bvalid),  .m_bready(m1_bready),   .m_bresp(m1_bresp),
        .m_araddr  (m1_araddr),  .m_arvalid(m1_arvalid), .m_arready(m1_arready),
        .m_rvalid  (m1_rvalid),  .m_rready(m1_rready),   .m_rdata(m1_rdata),
        .m_rresp   (m1_rresp)
    );

    // ---- Systolic array ----
    systolic_array #(.N(N)) u_sa (
        .clk     (clk),
        .arst_n  (rst_n),
        .a       (sa_a),
        .b       (sa_b),
        .start   (sa_start),
        .c       (sa_c),
        .done    (sa_done)
    );

endmodule
`resetall
