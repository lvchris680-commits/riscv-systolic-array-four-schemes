`default_nettype none
// ============================================================================
// sys_array_dma
// DMA controller for the systolic-array IP, with its own AXI4-Lite master.
//
// It processes CHANNELS independent 4x4 matrix multiplies C[k] = A[k] * B[k]:
// on `start`, loop over the channels, reading A[k] and B[k] from the shared
// BRAM, feeding the systolic array, and writing C[k] back. The CPU only
// configures the data, issues a start, and polls the done flag; data movement
// never occupies the CPU pipeline.
// ============================================================================
module sys_array_dma #(
    parameter int unsigned N = 4
) (
    input  logic clk,
    input  logic rst_n,

    input  logic start,           // start pulse from the CSR
    output logic done,            // level-high done flag (cleared on next start)

    // ---- To the systolic array ----
    output logic [N-1:0][N-1:0][7:0]  sa_a,
    output logic [N-1:0][N-1:0][7:0]  sa_b,
    output logic                      sa_start,
    input  logic [N-1:0][N-1:0][31:0] sa_c,
    input  logic                      sa_done,

    // ---- AXI4-Lite master ----
    output logic [31:0] m_awaddr,
    output logic        m_awvalid,
    input  logic        m_awready,
    output logic [31:0] m_wdata,
    output logic [3:0]  m_wstrb,
    output logic        m_wvalid,
    input  logic        m_wready,
    input  logic        m_bvalid,
    output logic        m_bready,
    input  logic [1:0]  m_bresp,
    output logic [31:0] m_araddr,
    output logic        m_arvalid,
    input  logic        m_arready,
    input  logic        m_rvalid,
    output logic        m_rready,
    input  logic [31:0] m_rdata,
    input  logic [1:0]  m_rresp
);

    import soc_pkg::*;

    typedef enum logic [3:0] {
        S_IDLE,
        S_RDA_AR, S_RDA_R,     // read A[chan]
        S_RDB_AR, S_RDB_R,     // read B[chan]
        S_FEED, S_WAIT,        // feed the array, wait for the result
        S_WRC_AW, S_WRC_B,     // write C[chan]
        S_DONE
    } state_t;

    state_t state, state_next;
    logic [5:0]  idx,  idx_next;       // element/word index within a channel
    logic [7:0]  chan, chan_next;      // channel index

    logic [N-1:0][N-1:0][7:0]  A, B;
    logic [31:0]                C [0:N*N-1];

    // ---- Outputs to the systolic array (A/B remain valid once fetched) ----
    assign sa_a = A;
    assign sa_b = B;

    // ---- AXI outputs (combinational) ----
    wire rd_b = (state == S_RDB_AR);
    assign m_arvalid = (state == S_RDA_AR) || (state == S_RDB_AR);
    assign m_araddr  = rd_b ? (ADDR_B + chan*A_BYTES + idx*4)
                            : (ADDR_A + chan*A_BYTES + idx*4);
    assign m_rready  = (state == S_RDA_R) || (state == S_RDB_R);

    assign m_awvalid = (state == S_WRC_AW);
    assign m_awaddr  = ADDR_C + chan*C_BYTES + idx*4;
    assign m_wvalid  = (state == S_WRC_AW);
    assign m_wdata   = C[idx];
    assign m_wstrb   = 4'hF;
    assign m_bready  = (state == S_WRC_B);

    // ---- State machine (combinational) ----
    always_comb begin
        state_next = state;
        idx_next   = idx;
        chan_next  = chan;
        sa_start   = 1'b0;
        case (state)
            S_IDLE:   if (start) begin state_next = S_RDA_AR; idx_next = '0; chan_next = '0; end
            S_RDA_AR: if (m_arvalid && m_arready) state_next = S_RDA_R;
            S_RDA_R:  if (m_rvalid && m_rready) begin
                          if (idx == N-1) begin state_next = S_RDB_AR; idx_next = '0; end
                          else             begin state_next = S_RDA_AR; idx_next = idx + 1'b1; end
                      end
            S_RDB_AR: if (m_arvalid && m_arready) state_next = S_RDB_R;
            S_RDB_R:  if (m_rvalid && m_rready) begin
                          if (idx == N-1) state_next = S_FEED;
                          else             begin state_next = S_RDB_AR; idx_next = idx + 1'b1; end
                      end
            S_FEED:   begin sa_start = 1'b1; state_next = S_WAIT; end
            S_WAIT:   if (sa_done) begin state_next = S_WRC_AW; idx_next = '0; end
            S_WRC_AW: if (m_awvalid && m_awready && m_wvalid && m_wready) state_next = S_WRC_B;
            S_WRC_B:  if (m_bvalid && m_bready) begin
                          if (idx == N*N-1) begin
                              if (chan == CHANNELS-1) begin state_next = S_DONE; end
                              else begin state_next = S_RDA_AR; idx_next = '0; chan_next = chan + 1'b1; end
                          end
                          else begin state_next = S_WRC_AW; idx_next = idx + 1'b1; end
                      end
            S_DONE:   state_next = S_IDLE;
        endcase
    end

    // ---- Sequential logic ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            idx   <= '0;
            chan  <= '0;
            done  <= 1'b0;
            A     <= '0;
            B     <= '0;
            C     <= '{default: '0};
        end else begin
            state <= state_next;
            idx   <= idx_next;
            chan  <= chan_next;

            // done stays high until the next start.
            if (state == S_DONE)                done <= 1'b1;
            else if (state == S_IDLE && start)  done <= 1'b0;

            // Latch A / B reads.
            if (state == S_RDA_R && m_rvalid && m_rready)
                A[idx] <= m_rdata;
            if (state == S_RDB_R && m_rvalid && m_rready)
                B[idx] <= m_rdata;

            // Latch the systolic-array result.
            if (state == S_WAIT && sa_done) begin
                for (int i = 0; i < N; i++)
                    for (int j = 0; j < N; j++)
                        C[i*N+j] <= sa_c[i][j];
            end
        end
    end

endmodule
`resetall
