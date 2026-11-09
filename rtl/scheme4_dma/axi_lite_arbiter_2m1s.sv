`default_nettype none
// ============================================================================
// axi_lite_arbiter_2m1s
// Arbitrates two AXI4-Lite masters onto one AXI4-Lite slave.
//
// Key points:
//   - The read path (AR/R) and write path (AW/W/B) are arbitrated independently.
//   - Round-robin fairness (tokens w_rr / r_rr flip after every grant).
//   - Single outstanding transaction: a write (AW+W+B) or read (AR+R) keeps the
//     grant until it completes, so AW/W/B always belong to the same master and
//     R always returns to the master that issued the read.
//   - Every ready signal is gated by "this master has the grant AND we are in
//     the right state", so a losing master sees ready==0 and must keep valid
//     asserted, as required by the AXI handshake.
// ============================================================================
module axi_lite_arbiter_2m1s #(
    parameter int unsigned ADDR_W = 32,
    parameter int unsigned DATA_W = 32
) (
    input  logic clk,
    input  logic rst_n,                 // active-low reset

    // ---------- Master 0 (CPU) ----------
    // AW
    input  logic [ADDR_W-1:0]   m0_awaddr,
    input  logic                m0_awvalid,
    output logic                m0_awready,
    // W
    input  logic [DATA_W-1:0]   m0_wdata,
    input  logic [DATA_W/8-1:0] m0_wstrb,
    input  logic                m0_wvalid,
    output logic                m0_wready,
    // B
    output logic                m0_bvalid,
    input  logic                m0_bready,
    output logic [1:0]          m0_bresp,
    // AR
    input  logic [ADDR_W-1:0]   m0_araddr,
    input  logic                m0_arvalid,
    output logic                m0_arready,
    // R
    output logic                m0_rvalid,
    input  logic                m0_rready,
    output logic [DATA_W-1:0]   m0_rdata,
    output logic [1:0]          m0_rresp,

    // ---------- Master 1 (DMA) ----------
    input  logic [ADDR_W-1:0]   m1_awaddr,
    input  logic                m1_awvalid,
    output logic                m1_awready,
    input  logic [DATA_W-1:0]   m1_wdata,
    input  logic [DATA_W/8-1:0] m1_wstrb,
    input  logic                m1_wvalid,
    output logic                m1_wready,
    output logic                m1_bvalid,
    input  logic                m1_bready,
    output logic [1:0]          m1_bresp,
    input  logic [ADDR_W-1:0]   m1_araddr,
    input  logic                m1_arvalid,
    output logic                m1_arready,
    output logic                m1_rvalid,
    input  logic                m1_rready,
    output logic [DATA_W-1:0]   m1_rdata,
    output logic [1:0]          m1_rresp,

    // ---------- Slave (BRAM controller) ----------
    output logic [ADDR_W-1:0]   s_awaddr,
    output logic                s_awvalid,
    input  logic                s_awready,
    output logic [DATA_W-1:0]   s_wdata,
    output logic [DATA_W/8-1:0] s_wstrb,
    output logic                s_wvalid,
    input  logic                s_wready,
    input  logic                s_bvalid,
    output logic                s_bready,
    input  logic [1:0]          s_bresp,
    output logic [ADDR_W-1:0]   s_araddr,
    output logic                s_arvalid,
    input  logic                s_arready,
    input  logic                s_rvalid,
    output logic                s_rready,
    input  logic [DATA_W-1:0]   s_rdata,
    input  logic [1:0]          s_rresp
);

    // ================= Write-channel arbitration =================
    localparam [1:0] W_IDLE = 2'd0, W_GRANT = 2'd1, W_RESP = 2'd2;

    logic [1:0] w_state, w_state_next;
    logic       w_owner, w_owner_next;   // master currently owning the write path
    logic       w_rr,    w_rr_next;      // token (0 prefers m0, 1 prefers m1)
    logic       aw_done, w_done;         // whether AW / W handshakes completed

    wire w0_req = m0_awvalid | m0_wvalid;
    wire w1_req = m1_awvalid | m1_wvalid;
    wire grant_w0 = w0_req & (~w1_req | ~w_rr);   // token decides when both request
    wire grant_w1 = w1_req & (~w0_req |  w_rr);

    wire aw_handshake = s_awvalid & s_awready;
    wire w_handshake  = s_wvalid  & s_wready;

    always_comb begin
        w_state_next = w_state;
        w_owner_next = w_owner;
        w_rr_next    = w_rr;
        case (w_state)
            W_IDLE: begin
                if (grant_w0)      begin w_owner_next = 1'b0; w_rr_next = 1'b1; w_state_next = W_GRANT; end
                else if (grant_w1) begin w_owner_next = 1'b1; w_rr_next = 1'b0; w_state_next = W_GRANT; end
            end
            W_GRANT: if (aw_done & w_done) w_state_next = W_RESP;
            W_RESP:  if (s_bvalid & s_bready) w_state_next = W_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_state <= W_IDLE;
            w_owner <= 1'b0;
            w_rr    <= 1'b0;
            aw_done <= 1'b0;
            w_done  <= 1'b0;
        end else begin
            w_state <= w_state_next;
            w_owner <= w_owner_next;
            w_rr    <= w_rr_next;
            case (w_state_next)
                W_GRANT: begin
                    aw_done <= aw_done | aw_handshake;
                    w_done  <= w_done  | w_handshake;
                end
                default: begin
                    aw_done <= 1'b0;
                    w_done  <= 1'b0;
                end
            endcase
        end
    end

    // Write-channel muxing.
    assign s_awaddr   = w_owner ? m1_awaddr  : m0_awaddr;
    assign s_awvalid  = (w_state == W_GRANT) && (w_owner ? m1_awvalid : m0_awvalid);
    assign m0_awready = (w_state == W_GRANT) && (w_owner == 1'b0) && s_awready;
    assign m1_awready = (w_state == W_GRANT) && (w_owner == 1'b1) && s_awready;

    assign s_wdata    = w_owner ? m1_wdata   : m0_wdata;
    assign s_wstrb    = w_owner ? m1_wstrb   : m0_wstrb;
    assign s_wvalid   = (w_state == W_GRANT) && (w_owner ? m1_wvalid : m0_wvalid);
    assign m0_wready  = (w_state == W_GRANT) && (w_owner == 1'b0) && s_wready;
    assign m1_wready  = (w_state == W_GRANT) && (w_owner == 1'b1) && s_wready;

    assign s_bready   = (w_state == W_RESP) && (w_owner ? m1_bready : m0_bready);
    assign m0_bvalid  = (w_state == W_RESP) && (w_owner == 1'b0) && s_bvalid;
    assign m1_bvalid  = (w_state == W_RESP) && (w_owner == 1'b1) && s_bvalid;
    assign m0_bresp   = s_bresp;
    assign m1_bresp   = s_bresp;

    // ================= Read-channel arbitration =================
    localparam R_IDLE = 1'b0, R_GRANT = 1'b1;

    logic r_state, r_state_next;
    logic r_owner, r_owner_next;
    logic r_rr,    r_rr_next;

    wire r0_req = m0_arvalid;
    wire r1_req = m1_arvalid;
    wire grant_r0 = r0_req & (~r1_req | ~r_rr);
    wire grant_r1 = r1_req & (~r0_req |  r_rr);

    always_comb begin
        r_state_next = r_state;
        r_owner_next = r_owner;
        r_rr_next    = r_rr;
        case (r_state)
            R_IDLE: begin
                if (grant_r0)      begin r_owner_next = 1'b0; r_rr_next = 1'b1; r_state_next = R_GRANT; end
                else if (grant_r1) begin r_owner_next = 1'b1; r_rr_next = 1'b0; r_state_next = R_GRANT; end
            end
            R_GRANT: if (s_rvalid & s_rready) r_state_next = R_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_state <= R_IDLE;
            r_owner <= 1'b0;
            r_rr    <= 1'b0;
        end else begin
            r_state <= r_state_next;
            r_owner <= r_owner_next;
            r_rr    <= r_rr_next;
        end
    end

    assign s_araddr   = r_owner ? m1_araddr  : m0_araddr;
    assign s_arvalid  = (r_state == R_GRANT) && (r_owner ? m1_arvalid : m0_arvalid);
    assign m0_arready = (r_state == R_GRANT) && (r_owner == 1'b0) && s_arready;
    assign m1_arready = (r_state == R_GRANT) && (r_owner == 1'b1) && s_arready;

    assign s_rready   = (r_state == R_GRANT) && (r_owner ? m1_rready : m0_rready);
    assign m0_rvalid  = (r_state == R_GRANT) && (r_owner == 1'b0) && s_rvalid;
    assign m1_rvalid  = (r_state == R_GRANT) && (r_owner == 1'b1) && s_rvalid;
    assign m0_rdata   = s_rdata;
    assign m1_rdata   = s_rdata;
    assign m0_rresp   = s_rresp;
    assign m1_rresp   = s_rresp;

endmodule
`resetall
