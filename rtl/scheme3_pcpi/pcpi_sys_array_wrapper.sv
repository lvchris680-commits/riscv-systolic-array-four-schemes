`default_nettype none
// ============================================================================
// pcpi_sys_array_wrapper : Scheme 3 -- PCPI co-processor.
// Exposes the 4x4 systolic array to PicoRV32 through the Pico Co-Processor
// Interface (PCPI). The CPU issues custom-0 instructions to load A/B rows,
// start the array, and read C elements back -- the compute is offloaded to the
// array, while the CPU still moves the data (BRAM -> registers -> PCPI).
//
// Custom instructions (opcode 0001011, custom-0):
//   func3 = 000  LOAD   rs1 = 32-bit data, rs2[2]=A/B, rs2[1:0]=row
//   func3 = 001  START  begin the systolic-array matmul (stalls until done)
//   func3 = 010  READ   rs1[3:0] = C index, result returned in rd
// ============================================================================
module pcpi_sys_array_wrapper (
    input  wire        clk,
    input  wire        resetn,

    // ---- PCPI interface ----
    input  wire        pcpi_valid,
    input  wire [31:0] pcpi_insn,
    input  wire [31:0] pcpi_rs1,
    input  wire [31:0] pcpi_rs2,
    output reg         pcpi_wr,
    output reg  [31:0] pcpi_rd,
    output reg         pcpi_wait,
    output reg         pcpi_ready
);

    // Instruction decode.
    wire [2:0] func3     = pcpi_insn[14:12];
    wire       is_custom = (pcpi_insn[6:0] == 7'b0001011); // custom-0

    // Internal staging (one channel at a time).
    reg [31:0] reg_A [0:3];
    reg [31:0] reg_B [0:3];
    reg [31:0] reg_C [0:15];

    localparam [1:0] IDLE = 2'd0, COMPUTE = 2'd1;

    reg [1:0] state;

    // Systolic-array wiring.
    logic [3:0][3:0][7:0]  sa_a;
    logic [3:0][3:0][7:0]  sa_b;
    logic                  sa_start;
    logic [3:0][3:0][31:0] sa_c;
    logic                  sa_done;

    genvar i, j;
    generate
        for (i = 0; i < 4; i++) begin : gen_unpack
            for (j = 0; j < 4; j++) begin : gen_col
                assign sa_a[i][j] = reg_A[i][(j*8) +: 8];
                assign sa_b[i][j] = reg_B[i][(j*8) +: 8];
            end
        end
    endgenerate

    systolic_array #(.N(4)) u_sa (
        .clk    (clk),
        .arst_n (resetn),
        .a      (sa_a),
        .b      (sa_b),
        .start  (sa_start),
        .c      (sa_c),
        .done   (sa_done)
    );

    integer k;

    always @(posedge clk) begin
        if (!resetn) begin
            state      <= IDLE;
            pcpi_wait  <= 1'b0;
            pcpi_ready <= 1'b0;
            pcpi_wr    <= 1'b0;
            pcpi_rd    <= 32'b0;
            sa_start   <= 1'b0;
        end else begin
            // Defaults (pulses).
            pcpi_ready <= 1'b0;
            pcpi_wr    <= 1'b0;
            sa_start   <= 1'b0;

            case (state)
                IDLE: begin
                    if (pcpi_valid && is_custom) begin
                        case (func3)
                            3'b000: begin
                                // LOAD: rs2[2] selects A(0)/B(1), rs2[1:0] the row.
                                if (pcpi_rs2[2] == 1'b0)
                                    reg_A[pcpi_rs2[1:0]] <= pcpi_rs1;
                                else
                                    reg_B[pcpi_rs2[1:0]] <= pcpi_rs1;
                                pcpi_ready <= 1'b1;
                            end
                            3'b001: begin
                                // START: pulse the array, stall the CPU, wait done.
                                sa_start   <= 1'b1;
                                pcpi_wait  <= 1'b1;
                                state      <= COMPUTE;
                            end
                            3'b010: begin
                                // READ: rs1[3:0] = C index.
                                pcpi_rd    <= reg_C[pcpi_rs1[3:0]];
                                pcpi_wr    <= 1'b1;
                                pcpi_ready <= 1'b1;
                            end
                            default: begin
                                pcpi_ready <= 1'b1;   // unknown: no-op
                            end
                        endcase
                    end
                end

                COMPUTE: begin
                    if (sa_done) begin
                        for (k = 0; k < 16; k = k + 1)
                            reg_C[k] <= sa_c[k/4][k%4];
                        pcpi_wait  <= 1'b0;
                        pcpi_ready <= 1'b1;
                        state      <= IDLE;
                    end
                end
            endcase
        end
    end

endmodule
