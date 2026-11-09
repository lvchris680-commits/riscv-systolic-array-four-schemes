`default_nettype none
`timescale 1ns/1ps

// Systolic-array standalone test: verify C == A * B against a golden model.
module tb_sa;

    localparam int N = 4;

    logic clk = 0;
    logic arst_n = 0;
    logic [N-1:0][N-1:0][7:0] a, b;
    logic start = 0;
    logic [N-1:0][N-1:0][31:0] c;
    logic done;

    always #5 clk = ~clk;

    // Cycle counter.
    int unsigned cycle_cnt = 0;
    always @(posedge clk) cycle_cnt++;

    systolic_array #(.N(N)) dut (
        .clk(clk), .arst_n(arst_n),
        .a(a), .b(b), .start(start),
        .c(c), .done(done)
    );

    // Golden reference model.
    function automatic [31:0] gold(input int i, j);
        integer k;
        logic [31:0] acc;
        begin
            acc = '0;
            for (k = 0; k < N; k++)
                acc = acc + a[i][k] * b[k][j];
            gold = acc;
        end
    endfunction

    int errs = 0;
    integer lat = 0;

    // Watchdog.
    initial begin
        #100000;
        $display("TB_SA TIMEOUT (done never asserted)");
        $finish;
    end

    initial begin
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                a[i][j] = 8'(i*4 + j + 1);            // 1..16
                b[i][j] = 8'((i*3 + j*5) % 17 + 1);   // 1..16, scrambled
            end

        // Release reset and pulse start (drive on negedge to avoid NBA races).
        arst_n = 1;
        repeat (2) @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;

        // Measure array compute latency (start pulse -> done).
        lat = 0;
        while (!done) begin
            @(posedge clk);
            lat = lat + 1;
        end
        $display("TB_SA: done asserted, array latency (start->done) = %0d cycles", lat);

        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                if (c[i][j] !== gold(i, j)) begin
                    $display("FAIL [%0d][%0d]: got %0d, exp %0d", i, j, c[i][j], gold(i, j));
                    errs++;
                end
            end

        if (errs == 0)
            $display("TB_SA PASS: C == A*B");
        else
            $display("TB_SA FAIL: %0d mismatches", errs);

        $finish;
    end

endmodule
`resetall
