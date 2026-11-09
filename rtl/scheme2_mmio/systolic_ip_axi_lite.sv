`default_nettype none
// ============================================================================
// systolic_ip_axi_lite
// Baseline accelerator IP: the 4x4 systolic array exposed as a plain AXI4-Lite
// slave with a Vivado-style register file. There is no DMA and no shared BRAM
// here -- the CPU (the only AXI master) drives the accelerator register by
// register through load/store instructions.
//
// It processes CHANNELS independent 4x4 matmuls C[k] = A[k] * B[k]. On a CTRL
// write the internal controller loops over the channels, feeding the 4x4 array
// one channel at a time.
//
// Register map (word index = (addr - IP_BASE)/4):
//   A[ch][i]  at ch*N      + i            (0 .. CHANNELS*N-1)
//   B[ch][i]  at CHANNELS*N + ch*N + i
//   CTRL       at 2*CHANNELS*N           (bit0=1 -> start)  write
//   STATUS     at 2*CHANNELS*N + 1       (bit0=done)        read
//   C[ch][j]  at 2*CHANNELS*N + 2 + ch*N*N + j
// ============================================================================
module systolic_ip_axi_lite #(
    parameter int unsigned N = 4
) (
    input  logic clk,
    input  logic rst_n,                 // active-low reset

    // Debug read port (testbench inspects the IP register file).
    input  logic [9:0]  dbg_raddr,
    output logic [31:0] dbg_rdata,

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

    // Register indices.
    localparam int unsigned REG_A_BASE = 0;
    localparam int unsigned REG_B_BASE = CHANNELS*N;
    localparam int unsigned REG_CTRL   = 2*CHANNELS*N;
    localparam int unsigned REG_STATUS = 2*CHANNELS*N + 1;
    localparam int unsigned REG_C_BASE = 2*CHANNELS*N + 2;
    localparam int unsigned REG_CNT    = 2*CHANNELS*N + 2 + CHANNELS*N*N;

    // Register file.
    logic [31:0] slv_reg [0:REG_CNT-1];

    // ---- Systolic-array wiring + channel controller ----
    logic [N-1:0][N-1:0][7:0]  sa_a;
    logic [N-1:0][N-1:0][7:0]  sa_b;
    logic                      sa_start;
    logic [N-1:0][N-1:0][31:0] sa_c;
    logic                      sa_done;

    logic        done_flag;             // level flag, set when all channels done
    logic        ctrl_start;            // pulse: a CTRL write was committed

    localparam [1:0] CS_IDLE = 2'd0, CS_FEED = 2'd1, CS_WAIT = 2'd2, CS_DONE = 2'd3;
    logic [1:0] cs;
    logic [9:0] chan;

    // Feed the current channel into the systolic array.
    always_comb begin
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                sa_a[i][j] = slv_reg[REG_A_BASE + chan*N + i][8*j +: 8];
                sa_b[i][j] = slv_reg[REG_B_BASE + chan*N + i][8*j +: 8];
            end
    end

    systolic_array #(.N(N)) u_sa (
        .clk     (clk),
        .arst_n  (rst_n),
        .a       (sa_a),
        .b       (sa_b),
        .start   (sa_start),
        .c       (sa_c),
        .done    (sa_done)
    );

    // Channel controller: on CTRL, loop over the channels.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cs        <= CS_IDLE;
            chan      <= '0;
            sa_start  <= 1'b0;
            done_flag <= 1'b0;
        end else begin
            sa_start <= 1'b0;
            case (cs)
                CS_IDLE: begin
                    if (ctrl_start) begin
                        chan      <= '0;
                        done_flag <= 1'b0;
                        cs        <= CS_FEED;
                    end
                end
                CS_FEED: begin
                    sa_start <= 1'b1;
                    cs       <= CS_WAIT;
                end
                CS_WAIT: begin
                    if (sa_done) begin
                        for (int i = 0; i < N; i++)
                            for (int j = 0; j < N; j++)
                                slv_reg[REG_C_BASE + chan*N*N + i*N + j] <= sa_c[i][j];
                        if (chan == CHANNELS-1) begin
                            done_flag <= 1'b1;
                            cs        <= CS_DONE;
                        end else begin
                            chan <= chan + 1'b1;
                            cs   <= CS_FEED;
                        end
                    end
                end
                CS_DONE: cs <= CS_IDLE;
            endcase
        end
    end

    // Debug read port: combinational read of the register file.
    assign dbg_rdata = (dbg_raddr == REG_STATUS[9:0]) ? {31'b0, done_flag}
                                                       : slv_reg[dbg_raddr];

    // ---------------- Read channel ----------------
    logic        rvalid;
    logic [31:0] rdata;

    wire [9:0] ar_reg = (s_araddr - IP_BASE) >> 2;

    wire [31:0] rd_mux =
        (ar_reg == REG_STATUS[9:0]) ? {31'b0, done_flag} : slv_reg[ar_reg];

    assign s_arready = !rvalid;  // single outstanding read

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
            ctrl_start <= 1'b0;
        end else begin
            ctrl_start <= 1'b0;                      // single-cycle pulse by default

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

            if (aw_done && w_done && !bvalid) begin
                if (((awaddr_r - IP_BASE) >> 2) == REG_CTRL[9:0]) begin
                    ctrl_start <= 1'b1;              // trigger the channel loop
                end else begin
                    for (int b = 0; b < 4; b++)
                        if (wstrb_r[b])
                            slv_reg[(awaddr_r - IP_BASE) >> 2][8*b +: 8] <= wdata_r[8*b +: 8];
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
