`default_nettype none
// One active-low center-sole switch per foot; bit0=left, bit1=right.
module foot_switches #(
    parameter integer MAKE_TICKS = 3,
    parameter integer BREAK_TICKS = 8
)(
    input wire clk, rst,
    input wire sample,                 // one clock pulse at each 1 kHz boundary
    input wire [1:0] raw_n,           // open=1 (pull-up), closed=0
    input wire [63:0] now_us,
    output reg [1:0] switches,
    output wire [1:0] feet,
    output reg [15:0] left_ticks, right_ticks,
    output reg [1:0] switch_changed,
    output wire [1:0] foot_changed,
    output reg [127:0] switch_change_us,
    output reg [63:0] latest_change_us
);
    localparam integer MAX_TICKS = (MAKE_TICKS > BREAK_TICKS) ? MAKE_TICKS : BREAK_TICKS;
    localparam integer CW = (MAX_TICKS < 2) ? 1 : $clog2(MAX_TICKS + 1);
    localparam integer MAKE_I = MAKE_TICKS;
    localparam integer BREAK_I = BREAK_TICKS;
    localparam [CW-1:0] MAKE_NEED = MAKE_I[CW-1:0];
    localparam [CW-1:0] BREAK_NEED = BREAK_I[CW-1:0];
    (* ASYNC_REG = "TRUE" *) reg [1:0] sync_first, sync_second;
    reg [CW-1:0] candidate_ticks [0:1];
    wire [1:0] closed = ~sync_second;
    wire [1:0] next_switches;
    genvar g;
    generate for (g=0; g<2; g=g+1) begin : next_state
        wire mismatch = closed[g] != switches[g];
        wire [CW-1:0] needed = closed[g] ? MAKE_NEED : BREAK_NEED;
        wire commit_change = mismatch && (candidate_ticks[g] == needed - 1'b1);
        assign next_switches[g] = commit_change ? closed[g] : switches[g];
    end endgenerate
    // One switch per foot, so these two masks have the same bits.
    assign feet = switches;
    assign foot_changed = switch_changed;
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            sync_first <= 2'b11;
            sync_second <= 2'b11;
            switches <= 2'b00;
            switch_changed <= 2'b00;
            left_ticks <= 16'd0;
            right_ticks <= 16'd0;
            switch_change_us <= 128'd0;
            latest_change_us <= 64'd0;
            for (i=0; i<2; i=i+1) candidate_ticks[i] <= {CW{1'b0}};
        end else begin
            // Synchronize the unscheduled physical pins at every FPGA clock.
            sync_first <= raw_n;
            sync_second <= sync_first;
            switch_changed <= 2'b00;
            if (sample) begin
                // Each foot independently waits for consecutive opposite samples.
                for (i=0; i<2; i=i+1) begin
                    if (closed[i] == switches[i]) candidate_ticks[i] <= {CW{1'b0}};
                    else if (next_switches[i] != switches[i]) begin
                        switches[i] <= closed[i];
                        candidate_ticks[i] <= {CW{1'b0}};
                        switch_changed[i] <= 1'b1;
                        switch_change_us[i*64 +: 64] <= now_us;
                        latest_change_us <= now_us;
                    end else candidate_ticks[i] <= candidate_ticks[i] + 1'b1;
                end
                if (next_switches[0] != switches[0]) left_ticks <= 16'd0;
                else if (left_ticks != 16'hffff) left_ticks <= left_ticks + 1'b1;
                if (next_switches[1] != switches[1]) right_ticks <= 16'd0;
                else if (right_ticks != 16'hffff) right_ticks <= right_ticks + 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
