`default_nettype none
`timescale 1ns/1ps

// ============================================================================
// tb_cpu : full-system simulation of the accelerated design. The real
// picorv32_axi fetches and runs a program from the shared BRAM that writes
// CHANNELS channels of A/B, starts the DMA, polls STATUS, and reads C[0][0][0]
// back to SCRATCH. The testbench checks the whole C matrix (all channels)
// against a golden model via the BRAM debug read port.
// ============================================================================
module tb_cpu;

    import soc_pkg::*;

    logic clk = 0;
    logic resetn = 0;
    always #5 clk = ~clk;

    // Cycle counter.
    int unsigned cycle_cnt = 0;
    always @(posedge clk) cycle_cnt++;

    logic trap;
    logic dma_done;
    logic [BRAM_AW-1:0] dbg_raddr = 0;
    logic [31:0]        dbg_rdata;

    top_cpu #(.INIT_FILE("prog.hex")) dut (
        .clk(clk), .resetn(resetn),
        .trap(trap), .dma_done(dma_done),
        .dbg_raddr(dbg_raddr), .dbg_rdata(dbg_rdata)
    );

    integer k;
    int errs = 0;
    integer t0 = 0, t1 = 0;

    // Combinational BRAM read (dbg_raddr -> dbg_rdata).
    task automatic read_bram(input int unsigned word_idx, output logic [31:0] data);
        dbg_raddr = word_idx[BRAM_AW-1:0];
        #1;
        data = dbg_rdata;
    endtask

    // Watchdog.
    initial begin
        #20000000;
        $display("TB_CPU TIMEOUT");
        $finish;
    end

    initial begin
        // Reset (active-low, held for several cycles).
        repeat (10) @(posedge clk);
        resetn = 1;
        @(posedge clk);
        t0 = cycle_cnt;   // reset-release moment (the CPU starts fetching here)

        // Wait for the DMA to finish (the CPU polls STATUS; the DMA sets done).
        while (!dma_done) @(posedge clk);
        t1 = cycle_cnt;
        $display("TB_CPU: dma_done asserted, computation latency (reset release -> done) = %0d cycles",
                 t1 - t0);

        // Give the CPU a few more cycles to read C[0][0][0] back to SCRATCH.
        repeat (200) @(posedge clk);

        // 1) The CPU must not have trapped.
        if (trap) begin
            $display("TB_CPU FAIL: CPU trapped");
            errs++;
        end

        // 2) Check the whole C matrix (all channels).
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

        // 3) Check the value the CPU itself read back (stored at SCRATCH).
        begin
            logic [31:0] cpu_readback;
            read_bram(32'h700 >> 2, cpu_readback);
            if (cpu_readback !== 32'h1) begin
                $display("FAIL CPU readback: got %08x, exp 00000001", cpu_readback);
                errs++;
            end
        end

        if (errs == 0)
            $display("TB_CPU PASS: CPU configures data -> DMA moves it -> C == A*B (%0d channels)",
                     CHANNELS);
        else
            $display("TB_CPU FAIL: %0d mismatches", errs);

        $finish;
    end

endmodule
`resetall
