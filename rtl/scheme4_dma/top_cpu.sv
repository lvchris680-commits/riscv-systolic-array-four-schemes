`default_nettype none
// ============================================================================
// top_cpu : complete CPU + IP system.
//   picorv32_axi (CPU, m0) --\                                    /-- bram_ctrl
//                             == axi_lite_arbiter_2m1s == BRAM ==
//   sys_array_dma (IP, m1) --/                                    \-- CSRs
// ============================================================================
module top_cpu #(
    parameter string INIT_FILE = ""    // hex file preloaded into the CPU program BRAM
) (
    input  logic clk,
    input  logic resetn,               // active-low reset
    output logic trap,
    output logic dma_done,
    // Debug read port (testbench inspects the BRAM).
    input  logic [BRAM_AW-1:0] dbg_raddr,
    output logic [31:0]        dbg_rdata
);

    import soc_pkg::*;

    // ---- CPU (m0) <-> SoC ----
    logic [31:0] m0_awaddr, m0_wdata, m0_araddr;
    logic [3:0]  m0_wstrb;
    logic        m0_awvalid, m0_awready;
    logic        m0_wvalid, m0_wready;
    logic        m0_bvalid, m0_bready;
    logic [1:0]  m0_bresp;
    logic        m0_arvalid, m0_arready;
    logic        m0_rvalid, m0_rready;
    logic [31:0] m0_rdata;
    logic [1:0]  m0_rresp;

    // CPU-side outputs that are unused here.
    logic [2:0]  cpu_awprot, cpu_arprot;
    logic        cpu_pcpi_valid;
    logic [31:0] cpu_pcpi_insn, cpu_pcpi_rs1, cpu_pcpi_rs2;
    logic [31:0] cpu_eoi;

    picorv32_axi u_cpu (
        .clk   (clk),
        .resetn(resetn),
        .trap  (trap),
        // AXI4-Lite master
        .mem_axi_awvalid(m0_awvalid), .mem_axi_awready(m0_awready),
        .mem_axi_awaddr (m0_awaddr),  .mem_axi_awprot (cpu_awprot),
        .mem_axi_wvalid (m0_wvalid),  .mem_axi_wready (m0_wready),
        .mem_axi_wdata  (m0_wdata),   .mem_axi_wstrb  (m0_wstrb),
        .mem_axi_bvalid (m0_bvalid),  .mem_axi_bready (m0_bready),
        .mem_axi_arvalid(m0_arvalid), .mem_axi_arready(m0_arready),
        .mem_axi_araddr (m0_araddr),  .mem_axi_arprot (cpu_arprot),
        .mem_axi_rvalid (m0_rvalid),  .mem_axi_rready (m0_rready),
        .mem_axi_rdata  (m0_rdata),
        // PCPI (unused)
        .pcpi_valid(cpu_pcpi_valid), .pcpi_insn(cpu_pcpi_insn),
        .pcpi_rs1  (cpu_pcpi_rs1),   .pcpi_rs2 (cpu_pcpi_rs2),
        .pcpi_wr   (1'b0), .pcpi_rd(32'b0), .pcpi_wait(1'b0), .pcpi_ready(1'b0),
        // IRQ (unused; the CPU polls STATUS)
        .irq(32'b0),
        .eoi(cpu_eoi)
    );

    soc_top #(.INIT_FILE(INIT_FILE)) u_soc (
        .clk      (clk),
        .rst_n    (resetn),
        .m0_awaddr(m0_awaddr),  .m0_awvalid(m0_awvalid), .m0_awready(m0_awready),
        .m0_wdata (m0_wdata),   .m0_wstrb(m0_wstrb),     .m0_wvalid(m0_wvalid),
        .m0_wready(m0_wready),
        .m0_bvalid(m0_bvalid),  .m0_bready(m0_bready),   .m0_bresp(m0_bresp),
        .m0_araddr(m0_araddr),  .m0_arvalid(m0_arvalid), .m0_arready(m0_arready),
        .m0_rvalid(m0_rvalid),  .m0_rready(m0_rready),   .m0_rdata(m0_rdata),
        .m0_rresp (m0_rresp),
        .dma_done (dma_done),
        .dbg_raddr(dbg_raddr),
        .dbg_rdata(dbg_rdata)
    );

endmodule
`resetall
