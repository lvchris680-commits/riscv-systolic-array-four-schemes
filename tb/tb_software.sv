`default_nettype none
`timescale 1ns/1ps

// ============================================================================
// tb_software : Scheme 1 full-system simulation. The CPU performs the whole
// matrix multiply in software (no accelerator). A and B are preloaded in the
// BRAM; the CPU reads them, computes C = A*B with lbu/mul/add, and writes C
// back. Verifies C against a golden model and measures the latency.
// ============================================================================
module tb_software;

    import soc_pkg::*;

    logic clk = 0;
    logic resetn = 0;
    always #5 clk = ~clk;

    // Cycle counter.
    int unsigned cycle_cnt = 0;
    always @(posedge clk) cycle_cnt++;

    logic trap;
    logic [11:0] dbg_raddr = 0;
    logic [31:0] dbg_rdata;

    top_software #(.INIT_FILE("prog_software.hex")) dut (
        .clk(clk), .resetn(resetn), .trap(trap),
        .dbg_raddr(dbg_raddr), .dbg_rdata(dbg_rdata)
    );

    integer k;
    int errs = 0;
    integer t0 = 0, t1 = 0;

    task automatic read_bram(input int unsigned word_idx, output logic [31:0] data);
        dbg_raddr = word_idx[11:0];
        #1;
        data = dbg_rdata;
    endtask

    initial begin
        #20000000;
        $display("TB_SOFTWARE TIMEOUT");
        $finish;
    end

    initial begin
        repeat (10) @(posedge clk);
        resetn = 1;
        @(posedge clk);
        t0 = cycle_cnt;

        // Wait for the last C element to be written back.
        begin
            logic [31:0] last;
            while (1) begin
                read_bram((ADDR_C >> 2) + (CHANNELS-1)*(C_BYTES/4) + (N*N-1), last);
                if (last === CHANNELS*N*N) break;
                @(posedge clk);
                if (cycle_cnt - t0 > 20000000) begin
                    $display("TB_SOFTWARE FAIL: C never written back (CPU stuck?)");
                    $finish;
                end
            end
            t1 = cycle_cnt;
        end
        $display("TB_SOFTWARE: result ready, computation latency (reset release -> C in BRAM) = %0d cycles",
                 t1 - t0);

        if (trap) begin
            $display("TB_SOFTWARE FAIL: CPU trapped");
            errs++;
        end

        for (k = 0; k < CHANNELS; k++)
            for (int i = 0; i < N; i++)
                for (int j = 0; j < N; j++) begin
                    logic [31:0] got;
                    read_bram((ADDR_C >> 2) + k*(C_BYTES/4) + i*N + j, got);
                    if (got !== k*N*N + i*N + j + 1) begin
                        $display("FAIL C[%0d][%0d][%0d]: got %08x, exp %08x",
                                 k, i, j, got, k*N*N + i*N + j + 1);
                        errs++;
                    end
                end

        if (errs == 0)
            $display("TB_SOFTWARE PASS: software matmul -> C == A*B (%0d channels)", CHANNELS);
        else
            $display("TB_SOFTWARE FAIL: %0d mismatches", errs);

        $finish;
    end

endmodule
`resetall
