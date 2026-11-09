`default_nettype none
`timescale 1ns/1ps

// ============================================================================
// tb_baseline : baseline full-system simulation. The CPU is the only AXI
// master and does all the data movement between the shared BRAM and the IP
// register file (no DMA, no arbiter) over CHANNELS independent 4x4 matmuls.
// A and B are preloaded in the BRAM; the CPU copies them into the IP, triggers
// the accelerator, and copies C back to the BRAM. Verifies C against a golden
// model and measures the computation-phase latency.
// ============================================================================
module tb_baseline;

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
    logic [9:0]  dbg_ip_raddr = 0;
    logic [31:0] dbg_ip_rdata;

    top_baseline #(.INIT_FILE("prog_baseline.hex")) dut (
        .clk(clk), .resetn(resetn), .trap(trap),
        .dbg_raddr(dbg_raddr), .dbg_rdata(dbg_rdata),
        .dbg_ip_raddr(dbg_ip_raddr), .dbg_ip_rdata(dbg_ip_rdata)
    );

    integer k;
    int errs = 0;
    integer t0 = 0, t1 = 0;

    // Combinational BRAM read.
    task automatic read_bram(input int unsigned word_idx, output logic [31:0] data);
        dbg_raddr = word_idx[11:0];
        #1;
        data = dbg_rdata;
    endtask

    // Watchdog.
    initial begin
        #20000000;
        $display("TB_BASELINE TIMEOUT");
        $finish;
    end

    initial begin
        // Reset (active-low, held for several cycles).
        repeat (10) @(posedge clk);
        resetn = 1;
        @(posedge clk);
        t0 = cycle_cnt;   // reset-release moment (the CPU starts moving data)

        // Wait until the CPU has written the LAST C element back into the BRAM
        // (C[CHANNELS-1][N-1][N-1] == CHANNELS*N*N). Polling the first element
        // would finish too early, while the CPU is still copying the rest.
        begin
            logic [31:0] last;
            while (1) begin
                read_bram((ADDR_C >> 2) + (CHANNELS-1)*(C_BYTES/4) + (N*N-1), last);
                if (last === CHANNELS*N*N) break;
                @(posedge clk);
                if (cycle_cnt - t0 > 2000000) begin
                    $display("TB_BASELINE FAIL: C never written back (CPU stuck?)");
                    $finish;
                end
            end
            t1 = cycle_cnt;
        end
        $display("TB_BASELINE: result ready, computation latency (reset release -> C in BRAM) = %0d cycles",
                 t1 - t0);

        // 1) The CPU must not have trapped.
        if (trap) begin
            $display("TB_BASELINE FAIL: CPU trapped");
            errs++;
        end

        // 2) Check the whole C matrix in the BRAM (all channels).
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
            $display("TB_BASELINE PASS: CPU moves data BRAM<->IP -> C == A*B (%0d channels)", CHANNELS);
        else
            $display("TB_BASELINE FAIL: %0d mismatches", errs);

        $finish;
    end

endmodule
`resetall
