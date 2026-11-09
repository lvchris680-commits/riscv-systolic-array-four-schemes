`default_nettype none
// ============================================================================
// top_baseline : baseline system for comparison.
// The CPU is the ONLY AXI master. It fetches its program from a BRAM and drives
// the systolic-array IP (an AXI4-Lite slave) register by register. No DMA, no
// arbiter -- all data movement goes through CPU load/store instructions.
//
//   picorv32_axi (CPU) -- axi_lite_addr_decode --+-- bram_ctrl (program)
//                                                +-- systolic_ip_axi_lite (IP)
// ============================================================================
module top_baseline #(
    parameter string INIT_FILE = ""    // hex file preloaded into the program BRAM
) (
    input  logic clk,
    input  logic resetn,               // active-low reset
    output logic trap,
    // Debug read ports (testbench inspects the BRAM scratch + IP registers).
    input  logic [11:0] dbg_raddr,
    output logic [31:0] dbg_rdata,
    input  logic [9:0]  dbg_ip_raddr,
    output logic [31:0] dbg_ip_rdata
);

    // CPU -> address decoder.
    logic [31:0] m_awaddr, m_wdata, m_araddr;
    logic [3:0]  m_wstrb;
    logic        m_awvalid, m_awready;
    logic        m_wvalid, m_wready;
    logic        m_bvalid, m_bready;
    logic [1:0]  m_bresp;
    logic        m_arvalid, m_arready;
    logic        m_rvalid, m_rready;
    logic [31:0] m_rdata;
    logic [1:0]  m_rresp;

    // CPU-side outputs that are unused here.
    logic [2:0]  cpu_awprot, cpu_arprot;
    logic        cpu_pcpi_valid;
    logic [31:0] cpu_pcpi_insn, cpu_pcpi_rs1, cpu_pcpi_rs2;
    logic [31:0] cpu_eoi;

    // Decoder -> slave 0 (BRAM).
    logic [31:0] s0_awaddr, s0_wdata, s0_araddr;
    logic [3:0]  s0_wstrb;
    logic        s0_awvalid, s0_awready;
    logic        s0_wvalid, s0_wready;
    logic        s0_bvalid, s0_bready;
    logic [1:0]  s0_bresp;
    logic        s0_arvalid, s0_arready;
    logic        s0_rvalid, s0_rready;
    logic [31:0] s0_rdata;
    logic [1:0]  s0_rresp;

    // Decoder -> slave 1 (IP).
    logic [31:0] s1_awaddr, s1_wdata, s1_araddr;
    logic [3:0]  s1_wstrb;
    logic        s1_awvalid, s1_awready;
    logic        s1_wvalid, s1_wready;
    logic        s1_bvalid, s1_bready;
    logic [1:0]  s1_bresp;
    logic        s1_arvalid, s1_arready;
    logic        s1_rvalid, s1_rready;
    logic [31:0] s1_rdata;
    logic [1:0]  s1_rresp;

    logic unused_start_pulse;

    picorv32_axi u_cpu (
        .clk   (clk),
        .resetn(resetn),
        .trap  (trap),
        .mem_axi_awvalid(m_awvalid), .mem_axi_awready(m_awready),
        .mem_axi_awaddr (m_awaddr),  .mem_axi_awprot (cpu_awprot),
        .mem_axi_wvalid (m_wvalid),  .mem_axi_wready (m_wready),
        .mem_axi_wdata  (m_wdata),   .mem_axi_wstrb  (m_wstrb),
        .mem_axi_bvalid (m_bvalid),  .mem_axi_bready (m_bready),
        .mem_axi_arvalid(m_arvalid), .mem_axi_arready(m_arready),
        .mem_axi_araddr (m_araddr),  .mem_axi_arprot (cpu_arprot),
        .mem_axi_rvalid (m_rvalid),  .mem_axi_rready (m_rready),
        .mem_axi_rdata  (m_rdata),
        .pcpi_valid(cpu_pcpi_valid), .pcpi_insn(cpu_pcpi_insn),
        .pcpi_rs1  (cpu_pcpi_rs1),   .pcpi_rs2 (cpu_pcpi_rs2),
        .pcpi_wr   (1'b0), .pcpi_rd(32'b0), .pcpi_wait(1'b0), .pcpi_ready(1'b0),
        .irq(32'b0),
        .eoi(cpu_eoi)
    );

    axi_lite_addr_decode #(.BOUNDARY(32'h0000_4000)) u_decode (
        .clk(clk), .rst_n(resetn),
        // master
        .m_awaddr(m_awaddr), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata),   .m_wstrb(m_wstrb),     .m_wvalid(m_wvalid),
        .m_wready(m_wready),
        .m_bvalid(m_bvalid), .m_bready(m_bready),   .m_bresp(m_bresp),
        .m_araddr(m_araddr), .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rvalid(m_rvalid), .m_rready(m_rready),   .m_rdata(m_rdata),
        .m_rresp(m_rresp),
        // slave 0 (BRAM)
        .s0_awaddr(s0_awaddr), .s0_awvalid(s0_awvalid), .s0_awready(s0_awready),
        .s0_wdata(s0_wdata),   .s0_wstrb(s0_wstrb),     .s0_wvalid(s0_wvalid),
        .s0_wready(s0_wready),
        .s0_bvalid(s0_bvalid), .s0_bready(s0_bready),   .s0_bresp(s0_bresp),
        .s0_araddr(s0_araddr), .s0_arvalid(s0_arvalid), .s0_arready(s0_arready),
        .s0_rvalid(s0_rvalid), .s0_rready(s0_rready),   .s0_rdata(s0_rdata),
        .s0_rresp(s0_rresp),
        // slave 1 (IP)
        .s1_awaddr(s1_awaddr), .s1_awvalid(s1_awvalid), .s1_awready(s1_awready),
        .s1_wdata(s1_wdata),   .s1_wstrb(s1_wstrb),     .s1_wvalid(s1_wvalid),
        .s1_wready(s1_wready),
        .s1_bvalid(s1_bvalid), .s1_bready(s1_bready),   .s1_bresp(s1_bresp),
        .s1_araddr(s1_araddr), .s1_arvalid(s1_arvalid), .s1_arready(s1_arready),
        .s1_rvalid(s1_rvalid), .s1_rready(s1_rready),   .s1_rdata(s1_rdata),
        .s1_rresp(s1_rresp)
    );

    bram_ctrl_axi_lite #(.INIT_FILE(INIT_FILE)) u_bram (
        .clk         (clk),
        .rst_n       (resetn),
        .dma_done    (1'b0),                 // no DMA in the baseline
        .start_pulse (unused_start_pulse),
        .dbg_raddr   (dbg_raddr),
        .dbg_rdata   (dbg_rdata),
        .s_awaddr    (s0_awaddr), .s_awvalid(s0_awvalid), .s_awready(s0_awready),
        .s_wdata     (s0_wdata),  .s_wstrb(s0_wstrb),     .s_wvalid(s0_wvalid),
        .s_wready    (s0_wready),
        .s_bvalid    (s0_bvalid), .s_bready(s0_bready),   .s_bresp(s0_bresp),
        .s_araddr    (s0_araddr), .s_arvalid(s0_arvalid), .s_arready(s0_arready),
        .s_rvalid    (s0_rvalid), .s_rready(s0_rready),   .s_rdata(s0_rdata),
        .s_rresp     (s0_rresp)
    );

    systolic_ip_axi_lite #(.N(4)) u_ip (
        .clk      (clk),
        .rst_n    (resetn),
        .dbg_raddr(dbg_ip_raddr),
        .dbg_rdata(dbg_ip_rdata),
        .s_awaddr (s1_awaddr), .s_awvalid(s1_awvalid), .s_awready(s1_awready),
        .s_wdata  (s1_wdata),  .s_wstrb(s1_wstrb),     .s_wvalid(s1_wvalid),
        .s_wready (s1_wready),
        .s_bvalid (s1_bvalid), .s_bready(s1_bready),   .s_bresp(s1_bresp),
        .s_araddr (s1_araddr), .s_arvalid(s1_arvalid), .s_arready(s1_arready),
        .s_rvalid (s1_rvalid), .s_rready(s1_rready),   .s_rdata(s1_rdata),
        .s_rresp  (s1_rresp)
    );

endmodule
`resetall
