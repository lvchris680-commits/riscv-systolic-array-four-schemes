`default_nettype none
// ============================================================================
// top_software : Scheme 1 -- pure software.
// The CPU is the only master and performs the whole matrix multiply in
// software (using its hardware multiplier). A and B are preloaded in the BRAM;
// the CPU reads them, computes C = A*B with load/store + mul/add instructions,
// and writes C back. There is no accelerator.
// ============================================================================
module top_software #(
    parameter string INIT_FILE = ""    // hex file preloaded into the program BRAM
) (
    input  logic clk,
    input  logic resetn,               // active-low reset
    output logic trap,
    // Debug read port (testbench inspects the BRAM).
    input  logic [11:0] dbg_raddr,
    output logic [31:0] dbg_rdata
);

    // CPU AXI4-Lite master -> BRAM slave.
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

    // Unused CPU outputs.
    logic [2:0]  cpu_awprot, cpu_arprot;
    logic        cpu_pcpi_valid;
    logic [31:0] cpu_pcpi_insn, cpu_pcpi_rs1, cpu_pcpi_rs2;
    logic [31:0] cpu_eoi;

    logic unused_start_pulse;

    picorv32_axi #(
        .ENABLE_MUL(1)                   // hardware multiply for the software matmul
    ) u_cpu (
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

    bram_ctrl_axi_lite #(.INIT_FILE(INIT_FILE)) u_bram (
        .clk         (clk),
        .rst_n       (resetn),
        .dma_done    (1'b0),              // no DMA
        .start_pulse (unused_start_pulse),
        .dbg_raddr   (dbg_raddr),
        .dbg_rdata   (dbg_rdata),
        .s_awaddr    (m_awaddr),  .s_awvalid(m_awvalid), .s_awready(m_awready),
        .s_wdata     (m_wdata),   .s_wstrb(m_wstrb),     .s_wvalid(m_wvalid),
        .s_wready    (m_wready),
        .s_bvalid    (m_bvalid),  .s_bready(m_bready),   .s_bresp(m_bresp),
        .s_araddr    (m_araddr),  .s_arvalid(m_arvalid), .s_arready(m_arready),
        .s_rvalid    (m_rvalid),  .s_rready(m_rready),   .s_rdata(m_rdata),
        .s_rresp     (m_rresp)
    );

endmodule
`resetall
