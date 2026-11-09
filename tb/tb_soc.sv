`default_nettype none
`timescale 1ns/1ps

// ============================================================================
// tb_soc : interconnect test WITHOUT the CPU. A bus-functional model (BFM)
// emulates the CPU's AXI4-Lite traffic on m0. Verifies the full chain:
// arbiter + BRAM controller + DMA + systolic array, over CHANNELS independent
// 4x4 matmuls. Flow: m0 writes A/B for every channel, writes START -> the DMA
// reads A[k]/B[k], computes, writes C[k] back -> m0 polls STATUS -> reads C
// back -> compare against a golden model.
// ============================================================================
module tb_soc;

    import soc_pkg::*;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    // Cycle counter.
    int unsigned cycle_cnt = 0;
    always @(posedge clk) cycle_cnt++;

    // ---- m0 (CPU-side) signals ----
    logic [31:0] m0_awaddr = 0;
    logic        m0_awvalid = 0;
    logic        m0_awready;
    logic [31:0] m0_wdata = 0;
    logic [3:0]  m0_wstrb = 0;
    logic        m0_wvalid = 0;
    logic        m0_wready;
    logic        m0_bvalid;
    logic        m0_bready = 0;
    logic [1:0]  m0_bresp;
    logic [31:0] m0_araddr = 0;
    logic        m0_arvalid = 0;
    logic        m0_arready;
    logic        m0_rvalid;
    logic        m0_rready = 0;
    logic [31:0] m0_rdata;
    logic [1:0]  m0_rresp;

    logic dma_done;

    soc_top dut (
        .clk(clk), .rst_n(rst_n),
        .m0_awaddr(m0_awaddr), .m0_awvalid(m0_awvalid), .m0_awready(m0_awready),
        .m0_wdata(m0_wdata),   .m0_wstrb(m0_wstrb),     .m0_wvalid(m0_wvalid),
        .m0_wready(m0_wready),
        .m0_bvalid(m0_bvalid), .m0_bready(m0_bready),   .m0_bresp(m0_bresp),
        .m0_araddr(m0_araddr), .m0_arvalid(m0_arvalid), .m0_arready(m0_arready),
        .m0_rvalid(m0_rvalid), .m0_rready(m0_rready),   .m0_rdata(m0_rdata),
        .m0_rresp(m0_rresp),
        .dma_done(dma_done)
    );

    // ---- AXI4-Lite BFM tasks (drive on negedge to avoid racing the DUT) ----
    task automatic axi_write(input logic [31:0] addr, input logic [31:0] data);
        @(negedge clk);
        m0_awaddr  = addr;
        m0_wdata   = data;
        m0_wstrb   = 4'hF;
        m0_awvalid = 1;
        m0_wvalid  = 1;
        m0_bready  = 1;
        while (!(m0_awready && m0_wready)) @(posedge clk);
        @(negedge clk);
        m0_awvalid = 0;
        m0_wvalid  = 0;
        while (!m0_bvalid) @(posedge clk);
        @(negedge clk);
        m0_bready  = 0;
    endtask

    task automatic axi_read(input logic [31:0] addr, output logic [31:0] data);
        @(negedge clk);
        m0_araddr  = addr;
        m0_arvalid = 1;
        m0_rready  = 1;
        while (!m0_arready) @(posedge clk);
        @(negedge clk);
        m0_arvalid = 0;
        while (!m0_rvalid) @(posedge clk);
        data = m0_rdata;
        @(negedge clk);
        m0_rready  = 0;
    endtask

    // ---- Reference data ----
    // A[k][i][j] = k*16 + i*4 + j + 1, B = identity, so C[k] = A[k].
    function automatic [31:0] a_word(input int k, i);
        logic [31:0] w;
        begin
            w = '0;
            for (int j = 0; j < N; j++)
                w = w | ((k*N*N + i*N + j + 1) << (8*j));
            a_word = w;
        end
    endfunction

    logic [31:0] B_words [0:3] = '{32'h00000001, 32'h00000100, 32'h00010000, 32'h01000000};

    integer k;
    integer t0 = 0;

    // Watchdog.
    initial begin
        #2000000;
        $display("TB_SOC TIMEOUT");
        $finish;
    end

    int errs = 0;

    initial begin
        // Reset.
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // 1. Write A and B for every channel.
        for (k = 0; k < CHANNELS; k++) begin
            for (int i = 0; i < N; i++)
                axi_write(ADDR_A + k*A_BYTES + 4*i, a_word(k, i));
            for (int i = 0; i < N; i++)
                axi_write(ADDR_B + k*A_BYTES + 4*i, B_words[i]);
        end
        $display("TB_SOC: A/B written (%0d channels)", CHANNELS);

        // 2. Write START, record the start cycle.
        @(posedge clk);
        t0 = cycle_cnt;
        axi_write(ADDR_START, 32'h1);

        // 3. Poll STATUS (also creates m0/m1 contention while the DMA runs).
        begin
            logic [31:0] status;
            int cnt = 0;
            do begin
                axi_read(ADDR_STATUS, status);
                cnt++;
                if (cnt > 100000) begin
                    $display("TB_SOC FAIL: status poll timeout");
                    $finish;
                end
            end while (status[0] != 1'b1);
        end
        $display("TB_SOC: DMA done, latency (START write -> done) = %0d cycles",
                 cycle_cnt - t0);

        // 4. Read C back for every channel and compare.
        for (k = 0; k < CHANNELS; k++)
            for (int i = 0; i < N; i++)
                for (int j = 0; j < N; j++) begin
                    logic [31:0] got, expv;
                    axi_read(ADDR_C + k*C_BYTES + 4*(i*N+j), got);
                    expv = k*N*N + i*N + j + 1;
                    if (got !== expv) begin
                        $display("FAIL C[%0d][%0d][%0d]: got %08x, exp %08x", k, i, j, got, expv);
                        errs++;
                    end
                end

        if (errs == 0)
            $display("TB_SOC PASS: C == A*B (%0d channels)", CHANNELS);
        else
            $display("TB_SOC FAIL: %0d mismatches", errs);

        $finish;
    end

endmodule
`resetall
