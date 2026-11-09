`default_nettype none
// ============================================================================
// bram_ctrl_axi_lite
// AXI4-Lite slave that decodes addresses into reads/writes of a shared BRAM,
// plus two control/status registers (CSRs).
//
//   - Data region: BRAM_WORDS x 32-bit single-port BRAM with byte-enable
//     writes and registered reads.
//   - ADDR_START:  any write generates a 1-cycle start pulse for the DMA.
//   - ADDR_STATUS: read returns {31'b0, dma_done}.
//
// Read : rdata is returned one cycle after the AR handshake (registered read,
//        modelling block-RAM latency).
// Write: the write commits once both AW and W have completed their handshakes,
//        after which B is returned.
// ============================================================================
module bram_ctrl_axi_lite #(
    parameter string INIT_FILE = ""   // optional hex file loaded via $readmemh
) (
    input  logic clk,
    input  logic rst_n,                // active-low reset

    // Done flag from the DMA (exposed through the STATUS register).
    input  logic dma_done,

    // Start pulse to the DMA.
    output logic start_pulse,

    // Debug read port (used by the testbench to inspect BRAM contents).
    input  logic [BRAM_AW-1:0] dbg_raddr,
    output logic [31:0]        dbg_rdata,

    // ---- AXI4-Lite slave ----
    input  logic [31:0] s_awaddr,
    input  logic        s_awvalid,
    output logic        s_awready,
    input  logic [31:0] s_wdata,
    input  logic [3:0]  s_wstrb,
    input  logic        s_wvalid,
    output logic        s_wready,
    output logic        s_bvalid,
    input  logic        s_bready,
    output logic [1:0]  s_bresp,
    input  logic [31:0] s_araddr,
    input  logic        s_arvalid,
    output logic        s_arready,
    output logic        s_rvalid,
    input  logic        s_rready,
    output logic [31:0] s_rdata,
    output logic [1:0]  s_rresp
);

    import soc_pkg::*;

    // ---------------- BRAM ----------------
    logic [31:0] bram [0:BRAM_WORDS-1];

    // Debug read port: combinational read.
    assign dbg_rdata = bram[dbg_raddr];

    // Simulation preload (skipped in synthesis when INIT_FILE is empty).
    initial begin
        for (int i = 0; i < BRAM_WORDS; i++) bram[i] = 32'h0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, bram);
    end

    // Address decode.
    wire [BRAM_AW-1:0] word_idx = s_araddr[BRAM_AW+1:2];   // BRAM word index (read side)
    wire               is_bram   = (s_araddr[BRAM_AW+1:2] < BRAM_WORDS);
    wire               is_start  = (s_araddr == ADDR_START);
    wire               is_status = (s_araddr == ADDR_STATUS);

    // ---------------- Read channel ----------------
    logic        rvalid;
    logic [31:0] rdata;

    // Combinational read data (latched on the AR handshake cycle).
    wire [31:0] rd_mux;
    assign rd_mux = is_status ? {31'b0, dma_done} : bram[word_idx];

    assign s_arready = !rvalid;            // single outstanding read

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rvalid <= 1'b0;
            rdata  <= 32'h0;
        end else begin
            if (s_arvalid && s_arready) begin
                rvalid <= 1'b1;
                rdata  <= rd_mux;
            end else if (rvalid && s_rready) begin
                rvalid <= 1'b0;
            end
        end
    end

    assign s_rvalid = rvalid;
    assign s_rdata  = rdata;
    assign s_rresp  = 2'b00;

    // ---------------- Write channel ----------------
    logic        aw_done, w_done;
    logic [31:0] awaddr_r;
    logic [31:0] wdata_r;
    logic [3:0]  wstrb_r;
    logic        bvalid;

    assign s_awready = !aw_done;
    assign s_wready  = !w_done;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_done    <= 1'b0;
            w_done     <= 1'b0;
            awaddr_r   <= 32'h0;
            wdata_r    <= 32'h0;
            wstrb_r    <= 4'h0;
            bvalid     <= 1'b0;
            start_pulse <= 1'b0;
        end else begin
            start_pulse <= 1'b0;                     // single-cycle pulse by default

            if (s_bvalid && s_bready)
                bvalid <= 1'b0;

            if (s_awvalid && s_awready) begin
                aw_done  <= 1'b1;
                awaddr_r <= s_awaddr;
            end
            if (s_wvalid && s_wready) begin
                w_done  <= 1'b1;
                wdata_r <= s_wdata;
                wstrb_r <= s_wstrb;
            end

            // Both address and data are ready -> commit the write.
            if (aw_done && w_done && !bvalid) begin
                if (awaddr_r == ADDR_START) begin
                    start_pulse <= 1'b1;             // trigger the DMA
                end else if (awaddr_r[BRAM_AW+1:2] < BRAM_WORDS) begin
                    for (int b = 0; b < 4; b++)
                        if (wstrb_r[b])
                            bram[awaddr_r[BRAM_AW+1:2]][8*b +: 8] <= wdata_r[8*b +: 8];
                end
                bvalid  <= 1'b1;
                aw_done <= 1'b0;
                w_done  <= 1'b0;
            end
        end
    end

    assign s_bvalid = bvalid;
    assign s_bresp  = 2'b00;

endmodule
`resetall
