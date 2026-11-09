`default_nettype none
// ============================================================================
// axi_lite_addr_decode
// Routes a single AXI4-Lite master to two AXI4-Lite slaves by address.
// Used in the baseline where the CPU is the only master and addresses
// below BOUNDARY go to slave 0 (program BRAM) and the rest to slave 1 (IP).
//
// This is simpler than the arbiter: there is no round-robin, only address
// decoding. The single-outstanding CPU asserts AW+W together and holds the
// address stable, so W is routed by the current AW address; the B/R responses
// are muxed back using a selection latched at the address handshake.
// ============================================================================
module axi_lite_addr_decode #(
    parameter logic [31:0] BOUNDARY = 32'h0000_1000
) (
    input  logic clk,
    input  logic rst_n,                 // active-low reset

    // ---- Master (CPU) ----
    input  logic [31:0] m_awaddr,
    input  logic        m_awvalid,
    output logic        m_awready,
    input  logic [31:0] m_wdata,
    input  logic [3:0]  m_wstrb,
    input  logic        m_wvalid,
    output logic        m_wready,
    output logic        m_bvalid,
    input  logic        m_bready,
    output logic [1:0]  m_bresp,
    input  logic [31:0] m_araddr,
    input  logic        m_arvalid,
    output logic        m_arready,
    output logic        m_rvalid,
    input  logic        m_rready,
    output logic [31:0] m_rdata,
    output logic [1:0]  m_rresp,

    // ---- Slave 0 (program BRAM) ----
    output logic [31:0] s0_awaddr,
    output logic        s0_awvalid,
    input  logic        s0_awready,
    output logic [31:0] s0_wdata,
    output logic [3:0]  s0_wstrb,
    output logic        s0_wvalid,
    input  logic        s0_wready,
    input  logic        s0_bvalid,
    output logic        s0_bready,
    input  logic [1:0]  s0_bresp,
    output logic [31:0] s0_araddr,
    output logic        s0_arvalid,
    input  logic        s0_arready,
    input  logic        s0_rvalid,
    output logic        s0_rready,
    input  logic [31:0] s0_rdata,
    input  logic [1:0]  s0_rresp,

    // ---- Slave 1 (IP) ----
    output logic [31:0] s1_awaddr,
    output logic        s1_awvalid,
    input  logic        s1_awready,
    output logic [31:0] s1_wdata,
    output logic [3:0]  s1_wstrb,
    output logic        s1_wvalid,
    input  logic        s1_wready,
    input  logic        s1_bvalid,
    output logic        s1_bready,
    input  logic [1:0]  s1_bresp,
    output logic [31:0] s1_araddr,
    output logic        s1_arvalid,
    input  logic        s1_arready,
    input  logic        s1_rvalid,
    output logic        s1_rready,
    input  logic [31:0] s1_rdata,
    input  logic [1:0]  s1_rresp
);

    wire sel_s1_aw = (m_awaddr >= BOUNDARY);
    wire sel_s1_ar = (m_araddr >= BOUNDARY);

    // Selection latched at the address handshake, used to route B/R back.
    reg wr_sel, rd_sel;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_sel <= 1'b0;
            rd_sel <= 1'b0;
        end else begin
            if (m_awvalid && m_awready) wr_sel <= sel_s1_aw;
            if (m_arvalid && m_arready) rd_sel <= sel_s1_ar;
        end
    end

    // ---- Write address channel ----
    assign s0_awaddr  = m_awaddr;
    assign s1_awaddr  = m_awaddr;
    assign s0_awvalid = m_awvalid && !sel_s1_aw;
    assign s1_awvalid = m_awvalid &&  sel_s1_aw;
    assign m_awready  = sel_s1_aw ? s1_awready : s0_awready;

    // ---- Write data channel (routed by current AW address) ----
    assign s0_wdata  = m_wdata;
    assign s1_wdata  = m_wdata;
    assign s0_wstrb  = m_wstrb;
    assign s1_wstrb  = m_wstrb;
    assign s0_wvalid = m_wvalid && !sel_s1_aw;
    assign s1_wvalid = m_wvalid &&  sel_s1_aw;
    assign m_wready  = sel_s1_aw ? s1_wready : s0_wready;

    // ---- Write response channel (routed by wr_sel) ----
    assign m_bvalid  = wr_sel ? s1_bvalid : s0_bvalid;
    assign m_bresp   = wr_sel ? s1_bresp  : s0_bresp;
    assign s0_bready = m_bready && !wr_sel;
    assign s1_bready = m_bready &&  wr_sel;

    // ---- Read address channel ----
    assign s0_araddr  = m_araddr;
    assign s1_araddr  = m_araddr;
    assign s0_arvalid = m_arvalid && !sel_s1_ar;
    assign s1_arvalid = m_arvalid &&  sel_s1_ar;
    assign m_arready  = sel_s1_ar ? s1_arready : s0_arready;

    // ---- Read data channel (routed by rd_sel) ----
    assign m_rvalid  = rd_sel ? s1_rvalid : s0_rvalid;
    assign m_rdata   = rd_sel ? s1_rdata  : s0_rdata;
    assign m_rresp   = rd_sel ? s1_rresp  : s0_rresp;
    assign s0_rready = m_rready && !rd_sel;
    assign s1_rready = m_rready &&  rd_sel;

endmodule
`resetall
