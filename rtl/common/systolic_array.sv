`default_nettype none
// ============================================================================
// systolic_array
// A self-contained N x N systolic array that reuses `pe` as its basic
// processing element. The skewed (time-staggered) input schedule required by a
// systolic matmul is encapsulated inside this module, so the caller only sees
// a simple "load full matrices + start pulse + done pulse" interface.
//
// Interface:
//   a, b    : N x N 8-bit unsigned matrices, latched on `start`
//   start   : 1-cycle pulse; latches a/b and begins computation
//   c       : N x N 32-bit results, stable after `done` (held until next start)
//   done    : 1-cycle pulse, indicates c is valid
//
// Timing (N=4): results are stable 3N-2 = 10 cycles after `start`;
// `done` is asserted on the 11th cycle.
// ============================================================================
module systolic_array #(
    parameter int unsigned N = 4
) (
    input  logic                     clk,
    input  logic                     arst_n,   // asynchronous active-low reset

    input  logic [N-1:0][N-1:0][7:0] a,
    input  logic [N-1:0][N-1:0][7:0] b,
    input  logic                     start,

    output logic [N-1:0][N-1:0][31:0] c,
    output logic                     done
);

    wire  arst = ~arst_n;                       // pe.sv uses an active-high reset

    // Latched input matrices.
    logic [N-1:0][N-1:0][7:0] A, B;

    // Compute state machine.
    localparam int unsigned DO_END  = 3*N - 3;  // 9  : last cycle doProcess is high
    localparam int unsigned CAPTURE = 3*N - 2;  // 10 : results stable, capture them
    logic busy;
    logic [5:0] cnt;

    // Per-row skewed input streams fed into the leftmost column / top row.
    logic [N-1:0][7:0] row_in;
    logic [N-1:0][7:0] col_in;

    // Interconnects between PEs.
    logic [N-1:0][N:0][7:0] rowIc;
    logic [N:0][N-1:0][7:0] colIc;

    // Raw PE outputs.
    logic [N-1:0][N-1:0][31:0] o_c;

    logic doProcess;
    assign doProcess = busy && (cnt <= DO_END[5:0]);

    // ---- Skewed input generation ----
    // Row i feeds A[i][t-i] at cycle t (when 0 <= t-i < N), else 0.
    // Column j feeds B[t-j][j] at cycle t (when 0 <= t-j < N), else 0.
    integer ii, jj;
    always_comb begin
        for (ii = 0; ii < N; ii = ii + 1) begin
            if (cnt >= ii && (cnt - ii) < N)
                row_in[ii] = A[ii][cnt - ii];
            else
                row_in[ii] = 8'h0;
        end
        for (jj = 0; jj < N; jj = jj + 1) begin
            if (cnt >= jj && (cnt - jj) < N)
                col_in[jj] = B[cnt - jj][jj];
            else
                col_in[jj] = 8'h0;
        end
    end

    // ---- Main state machine ----
    always_ff @(posedge clk or posedge arst) begin
        if (arst) begin
            busy <= 1'b0;
            cnt  <= '0;
            done <= 1'b0;
            c    <= '0;
            A    <= '0;
            B    <= '0;
        end else begin
            done <= 1'b0;                         // done is a single-cycle pulse
            if (start && !busy) begin
                A    <= a;
                B    <= b;
                busy <= 1'b1;
                cnt  <= '0;
            end else if (busy) begin
                if (cnt == CAPTURE[5:0]) begin
                    for (int i = 0; i < N; i++)
                        for (int j = 0; j < N; j++)
                            c[i][j] <= o_c[i][j];
                    done <= 1'b1;
                    busy <= 1'b0;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end
        end
    end

    // ---- Feed the leftmost column / top row into the interconnects ----
    always_comb begin
        for (int i = 0; i < N; i++) rowIc[i][0] = row_in[i];
        for (int j = 0; j < N; j++) colIc[0][j] = col_in[j];
    end

    // ---- N x N PE grid ----
    genvar gi, gj;
    generate
        for (gi = 0; gi < N; gi++) begin : gen_row
            for (gj = 0; gj < N; gj++) begin : gen_col
                pe u_pe (
                    .i_clk       (clk),
                    .i_arst      (arst),
                    .i_doProcess (doProcess),
                    .i_a         (rowIc[gi][gj]),
                    .i_b         (colIc[gi][gj]),
                    .o_a         (rowIc[gi][gj+1]),
                    .o_b         (colIc[gi+1][gj]),
                    .o_y         (o_c[gi][gj])
                );
            end
        end
    endgenerate

endmodule
`resetall
